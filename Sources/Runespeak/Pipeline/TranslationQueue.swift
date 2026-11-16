import Foundation
import RunespeakCore

/// Batches chat lines waiting for translation: a short debounce gathers bursts into one request,
/// at most two requests run at once, and no line is ever sent twice unless a request failed in a
/// way worth retrying. An answer that says a line over again is final too: the line stays in the
/// original and is not asked about a second time (see `finish`).
@MainActor
final class TranslationQueue {
    struct Outcome {
        var id: UUID
        var state: TranslationState
        var note: String?
        var engine: String?
        /// The translator answered with the line itself (see `TranslationEcho`). That is no
        /// translation: `state` is `.original`, and `engine` only says who was asked.
        var unchanged = false
    }

    /// Waits, in seconds. Only the self-test shortens them.
    struct Timing {
        var debounce: TimeInterval = 0.25
        /// While a request is out, newer lines wait this long for its answer before a second
        /// request is opened for them: chat that trickles in with every capture then shares
        /// requests (each carries the whole system prompt) instead of getting one per capture.
        var holdWhileBusy: TimeInterval = 1.5
        /// Pause after a rate limit; doubles up to `rateLimitMaxPause`. Rate limits are counted
        /// per minute, so anything much shorter only burns more of the quota.
        var rateLimitPause: TimeInterval = 15
        var rateLimitMaxPause: TimeInterval = 60
        var networkPause: TimeInterval = 3
        var blockTime: TimeInterval = 60
    }

    static let maxBatch = 12
    static let maxInFlight = 2
    static let maxPending = 80
    /// Rate-limit pauses one line sits through before it is given up.
    static let maxRateLimitRounds = 6

    var timing = Timing()
    /// The translator to use for the next request (swapped when the provider or its key changes).
    var translator: () -> Translating
    /// Request context for a batch about to be sent.
    var context: ([ChatMessage]) -> TranslationRequestContext
    var deliver: ([Outcome]) -> Void
    /// Reported once per failed request, for the status notice.
    var onError: ((TranslationError) -> Void)?
    /// Text shown on a failed line; the app names the provider in it.
    var describe: (TranslationError) -> String = { $0.userMessage }

    private var pending: [ChatMessage] = []
    /// When `pending` last stopped being empty.
    private var pendingSince: Date?
    private var attempts: [UUID: Int] = [:]
    private var rateLimitRounds: [UUID: Int] = [:]
    /// Lines of a request that failed as a whole because of what was in it (a refusal, an
    /// unusable or late answer): the largest request they may be part of next time. Halving
    /// finds the one line at fault; the others get translated.
    private var sizeLimit: [UUID: Int] = [:]
    /// Context lines that went out with a refused request: any of them may have been the cause.
    private var suspectContext: Set<UUID> = []
    private var known: Set<UUID> = []
    private var knownOrder: [UUID] = []
    private var inFlight = 0
    private var epoch = 0
    /// Bumped by `clearErrors()`. A request sent before the bump failed under a provider, key
    /// or model that is no longer in use: its error must not block the new one.
    private var setup = 0
    private var wakeAt: Date?
    private var wakeGeneration = 0
    private var pausedUntil = Date.distantPast
    private var backoff: TimeInterval = 0
    /// After an error that retrying cannot cure (bad key, no credit, quota), new lines fail at
    /// once for a while instead of sending a doomed request per batch.
    private var blocked: (error: TranslationError, until: Date)?

    init(translator: @escaping () -> Translating,
         context: @escaping ([ChatMessage]) -> TranslationRequestContext,
         deliver: @escaping ([Outcome]) -> Void) {
        self.translator = translator
        self.context = context
        self.deliver = deliver
    }

    var isIdle: Bool { pending.isEmpty && inFlight == 0 }

    func enqueue(_ message: ChatMessage) {
        guard known.insert(message.id).inserted else { return }
        knownOrder.append(message.id)
        if knownOrder.count > 4000 {
            for id in knownOrder.prefix(2000) { known.remove(id) }
            knownOrder.removeFirst(2000)
        }
        admit(message)
    }

    /// Sends a line again whose earlier attempt ended in a failure.
    func retry(_ message: ChatMessage) {
        guard !pending.contains(where: { $0.id == message.id }) else { return }
        if known.insert(message.id).inserted { knownOrder.append(message.id) }
        admit(message)
    }

    private func admit(_ message: ChatMessage) {
        if let blocked, blocked.until > Date() {
            deliver([Outcome(id: message.id, state: .failed(describe(blocked.error)))])
            return
        }
        if pending.isEmpty { pendingSince = Date() }
        pending.append(message)
        if pending.count > Self.maxPending {
            let dropped = pending.prefix(pending.count - Self.maxPending)
            pending.removeFirst(dropped.count)
            dropped.forEach(forget)
            deliver(dropped.map { Outcome(id: $0.id, state: .failed("번역이 밀려 이 줄은 건너뛰었습니다")) })
        }
        wake(after: timing.debounce)
    }

    /// The lines `ids` are gone from the list (another line took their place: the same row of
    /// chat read again, whole): those still waiting are not sent, and an answer on its way for
    /// one of them is not delivered.
    func cancel(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        let dropped = pending.filter { gone.contains($0.id) }
        guard !dropped.isEmpty else { return }
        pending.removeAll { gone.contains($0.id) }
        dropped.forEach(forget)
        if pending.isEmpty { pendingSince = nil }
    }

    /// Lines waiting to be sent (for the self-test).
    var pendingCount: Int { pending.count }

    /// Forgets everything waiting; answers of requests already sent are ignored.
    func cancelAll() {
        epoch += 1
        pending.removeAll()
        pendingSince = nil
        attempts.removeAll()
        rateLimitRounds.removeAll()
        sizeLimit.removeAll()
        suspectContext.removeAll()
    }

    /// Call when the translator changed (provider, key or model): earlier errors no longer apply.
    func clearErrors() {
        setup += 1
        blocked = nil
        backoff = 0
        pausedUntil = .distantPast
        rateLimitRounds.removeAll()
        // Directly, not through a timer: the wake-up left over from a pause may be far off.
        pump()
    }

    // MARK: - Internals

    private func forget(_ message: ChatMessage) {
        attempts[message.id] = nil
        rateLimitRounds[message.id] = nil
        sizeLimit[message.id] = nil
    }

    /// One timer at a time; a request for an earlier wake-up replaces a later one.
    private func wake(after delay: TimeInterval) {
        let at = Date().addingTimeInterval(max(0, delay))
        if let wakeAt, wakeAt <= at { return }
        wakeAt = at
        wakeGeneration += 1
        let generation = wakeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self, self.wakeGeneration == generation else { return }
            self.wakeAt = nil
            self.pump()
        }
    }

    private func pump() {
        // Lines put back when their batch went out as more than one request (below): they
        // have had their turn, and no request that is out could have taken them along.
        var leftBehind = false
        while inFlight < Self.maxInFlight, !pending.isEmpty {
            let wait = pausedUntil.timeIntervalSinceNow
            if wait > 0 {
                wake(after: wait)
                return
            }
            if !leftBehind, inFlight > 0, pending.count < Self.maxBatch, sizeLimit[pending[0].id] == nil, let since = pendingSince {
                let hold = timing.holdWhileBusy - Date().timeIntervalSince(since)
                if hold > 0 {
                    wake(after: hold)
                    return
                }
            }
            let limit = sizeLimit[pending[0].id]
            let cap = min(Self.maxBatch, limit ?? Self.maxBatch)
            var count = 0
            while count < pending.count, count < cap, sizeLimit[pending[count].id] == limit { count += 1 }
            var batch = Array(pending.prefix(count))
            pending.removeFirst(count)
            // A translator may send some of these lines apart from the others (lines that
            // carry places of their zone, `Translating.incomingRequests`). Each of its
            // requests is then a request of this queue too, so that a failure of one is dealt
            // with as what it is (a rate limit pauses, a refusal is halved, a time-out is not
            // asked again) and the answer of the other is shown when it arrives. The request
            // of the oldest line goes now; the other lines go back to the front, in order.
            leftBehind = false
            let requests = translator().incomingRequests(for: batch)
            if requests.count > 1, let first = requests.first(where: { $0.contains { $0.id == batch[0].id } }) {
                let own = Set(first.map(\.id))
                let others = batch.filter { !own.contains($0.id) }
                if !others.isEmpty {
                    batch.removeAll { !own.contains($0.id) }
                    pending.insert(contentsOf: others, at: 0)
                    leftBehind = true
                }
            }
            pendingSince = pending.isEmpty ? nil : Date()
            send(batch, alone: limit != nil)
        }
    }

    private func send(_ batch: [ChatMessage], alone: Bool) {
        inFlight += 1
        let translator = self.translator()
        var context = self.context(batch)
        if alone {
            // A retry after a refusal or a bad answer: nothing but the lines themselves, so
            // that what went wrong can only be one of them.
            context.recent = []
        } else {
            context.recent.removeAll { suspectContext.contains($0.id) }
        }
        let contextIDs = context.recent.map(\.id)
        let engine = translator.engineName(for: context)
        let epoch = self.epoch
        let setup = self.setup
        Task { @MainActor [weak self, context] in
            let result: Result<[UUID: TranslationOutput], Error>
            do {
                result = .success(try await translator.translateIncoming(batch, context: context))
            } catch {
                result = .failure(error)
            }
            self?.finish(batch, contextIDs: contextIDs, result: result, engine: engine, reader: context.reader,
                         epoch: epoch, setup: setup)
        }
    }

    private func finish(_ batch: [ChatMessage], contextIDs: [UUID], result: Result<[UUID: TranslationOutput], Error>,
                        engine: String, reader: ReaderLanguage, epoch: Int, setup: Int) {
        inFlight -= 1
        guard epoch == self.epoch else {
            pump()
            return
        }
        var outcomes: [Outcome] = []
        var retry: [ChatMessage] = []
        func fail(_ message: ChatMessage, _ reason: String) {
            forget(message)
            outcomes.append(Outcome(id: message.id, state: .failed(reason)))
        }
        /// Puts the line back unless it already used up its tries.
        func again(_ message: ChatMessage, limit: Int, else reason: String) {
            let used = attempts[message.id, default: 0] + 1
            if used < limit {
                attempts[message.id] = used
                retry.append(message)
            } else {
                fail(message, reason)
            }
        }
        /// Sends the lines again in two smaller requests. `tries` is how many requests a line
        /// may be part of in all; nil lets the halving run down to single lines.
        func halve(tries: Int?, else reason: String) {
            let half = (batch.count + 1) / 2
            for message in batch {
                sizeLimit[message.id] = half
                if let tries { again(message, limit: tries, else: reason) } else { retry.append(message) }
            }
        }

        switch result {
        case .success(let translated):
            backoff = 0
            for message in batch {
                guard let output = translated[message.id],
                      !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    again(message, limit: 2, else: "번역 결과를 받지 못했습니다")
                    continue
                }
                guard TranslationEcho.isEcho(output.text, of: message, reader: reader) else {
                    forget(message)
                    outcomes.append(Outcome(id: message.id, state: .translated(output.text), note: output.note, engine: engine))
                    continue
                }
                // The line came back as it went out: no translation. It is not asked for again.
                // Measured against the live models (`--translate-check`): a line with nothing to
                // translate ("kekw") comes back unchanged every time it is asked, so a second
                // request would only be paid for, while readable chat came back unchanged in
                // none of about 340 lines.
                forget(message)
                outcomes.append(Outcome(id: message.id, state: .original, engine: engine, unchanged: true))
            }
        case .failure(let error as TranslationError) where setup != self.setup:
            // The lines go to the translator now in use instead of failing with the old one's error.
            batch.forEach { again($0, limit: 3, else: describe(error)) }
        case .failure(let error as TranslationError):
            let reason = describe(error)
            var report = true
            switch error {
            case .rateLimited:
                // Two requests failing together are one rate limit, not two.
                if pausedUntil <= Date() {
                    backoff = min(timing.rateLimitMaxPause, max(timing.rateLimitPause, backoff * 2))
                    pausedUntil = Date().addingTimeInterval(backoff)
                }
                for message in batch {
                    let rounds = rateLimitRounds[message.id, default: 0] + 1
                    if rounds < Self.maxRateLimitRounds {
                        rateLimitRounds[message.id] = rounds
                        retry.append(message)
                    } else {
                        fail(message, "요청 한도에 계속 걸려 번역하지 못했습니다")
                    }
                }
            case .network:
                pausedUntil = Date().addingTimeInterval(timing.networkPause)
                batch.forEach { again($0, limit: 2, else: reason) }
            case .refused:
                contextIDs.forEach { suspectContext.insert($0) }
                if suspectContext.count > 400 { suspectContext.removeAll() }
                if batch.count > 1 {
                    // One line (or a context line) set it off; the rest are innocent.
                    halve(tries: nil, else: reason)
                    report = false
                } else if sizeLimit[batch[0].id] == nil, !contextIDs.isEmpty {
                    // A single line refused together with context: once more on its own.
                    sizeLimit[batch[0].id] = 1
                    retry.append(batch[0])
                    report = false
                } else {
                    fail(batch[0], reason)
                }
            case .unusableReply:
                if batch.count > 1 { halve(tries: 3, else: reason) } else { again(batch[0], limit: 2, else: reason) }
            case .timedOut:
                // The provider may well finish and bill what was given up on: a single line is
                // not sent again, a batch once more in halves, which answer sooner.
                if batch.count > 1 { halve(tries: 2, else: reason) } else { fail(batch[0], reason) }
            case .badResponse:
                batch.forEach { fail($0, reason) }
            case .missingAPIKey, .invalidAPIKey, .insufficientCredit, .dailyLimitReached, .modelNotFound:
                blocked = (error, Date().addingTimeInterval(timing.blockTime))
                batch.forEach { fail($0, reason) }
                pending.forEach { fail($0, reason) }
                pending.removeAll()
                pendingSince = nil
            }
            if report { onError?(error) }
        case .failure(let error):
            let reason = error is CancellationError ? "번역이 취소되었습니다" : "번역 실패: \(error.localizedDescription)"
            batch.forEach { fail($0, reason) }
        }

        // Retried lines go first so chat stays in order.
        if !retry.isEmpty {
            if pending.isEmpty { pendingSince = Date() }
            pending.insert(contentsOf: retry, at: 0)
        }
        if !outcomes.isEmpty { deliver(outcomes) }
        pump()
    }
}
