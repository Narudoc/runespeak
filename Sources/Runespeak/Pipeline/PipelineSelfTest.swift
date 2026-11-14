import CoreGraphics
import CoreText
import Foundation
import RunespeakCore

/// `--pipeline-selftest`: a scripted chat session is rendered frame by frame as the game would
/// scroll it, and pushed through the real chain — fingerprint skip, Vision OCR, ChatTracker,
/// LanguageGate / channel policy, TranslationQueue — with a fake translator at the end.
/// Headless: no screen capture, no network, no permission.
///
///   --pipeline-selftest             pass/fail
///   --pipeline-selftest --verbose   also print every emitted message
///   --pipeline-selftest --dump <dir> also write every rendered frame as PNG
@MainActor
enum PipelineSelfTest {

    // MARK: - Script

    struct Spoken {
        var channel: ChatChannel
        var sender: String?
        var body: String
        /// Whether the default settings (길드, 파티/공격대, 귓속말 on; Korean reader) translate it.
        var translate: Bool
    }

    private static func m(_ channel: ChatChannel, _ sender: String?, _ body: String, _ translate: Bool) -> Spoken {
        Spoken(channel: channel, sender: sender, body: body, translate: translate)
    }

    static let script: [Spoken] = [
        m(.guild, "Thrall", "need 1 more dps for mara", true),
        m(.party, "Anduin", "omw, 2 min. pull when rdy", true),
        m(.guild, "달빛기사", "오늘 저녁 9시에 화산심장부 가실 분 계신가요?", false),
        m(.whisper, "Varian", "can u tank BRD? need 1 for arena/anger run", true),
        m(.publicChannel, "Jaina", "WTS Arcanite Bar x5, 40g each or 180g for all", false),
        m(.yell, "Garrosh", "LF2M UBRS need healer + dps, have key", false),
        m(.system, nil, "경험치 250을 획득했습니다.", false),
        m(.raid, "Sylvanas", "MT on skull, OT pick up adds @ 35%", true),
        m(.guild, "Thrall", "we are going to do a full clear of molten core tonight at nine so please bring your fire resistance gear and enough consumables for three hours", true),
        m(.party, "검은용", "잠시만요 마나 좀 채우고 갈게요", false),
        m(.guild, "Pedro", "alguien para mazmorras? necesito un tanque", true),
        m(.guild, "Jaina", "2000", false),
        m(.party, "Sylvanas", "can someone summon me, i am at the stone", true),
        m(.whisper, "Anduin", "are you coming to the raid tonight?", true),
        m(.say, "Thrall", "anyone selling arcane crystal?", false),
        m(.guild, "Garrosh", "grats on the new mount", true),
        m(.raid, "Varian", "everyone stack behind the boss and stop dps at 52% until the adds are dead, then burn him down before the next fear", true),
        m(.guild, "달빛기사", "다들 수고하셨습니다 내일 봬요", false),
        m(.party, "Anduin", "wait for me, selling junk first", true),
        m(.publicChannel, "Pedro", "LFG Scarlet Monastery, mage lvl 38", false),
        m(.guild, "Иван", "привет всем, кто идёт в рейд сегодня?", true),
        m(.whisper, "Jaina", "thanks for the help earlier, really appreciate it", true),
        m(.guild, "Sylvanas", "who has the key for scholomance?", true),
        m(.party, "Thrall", "sheep moon, sap square, kill skull first", true),
        m(.system, nil, "전리품을 획득했습니다: 10골드", false),
        m(.guild, "Varian", "can any enchanter do crusader on my sword?", true),
        m(.raid, "Garrosh", "healers please dispel the curse faster", true),
        m(.guild, "검은용", "저도 갈게요 초대 부탁드립니다", false),
        m(.party, "Jaina", "need to repair after this pull", true),
        m(.whisper, "Thrall", "do you still need a tank for strat?", true),
        m(.guild, "Anduin", "logging off for today, see you all tomorrow", true),
        m(.party, "Varian", "last boss then i have to go", true),
    ]

    private static func color(_ channel: ChatChannel) -> RGBColor {
        typealias P = SyntheticChat.Palette
        switch channel {
        case .guild, .officer: return P.guild
        case .party, .instance: return P.party
        case .raid, .raidWarning: return P.raid
        case .whisper: return P.whisper
        case .yell: return P.yell
        case .publicChannel: return P.channel
        case .system: return P.system
        case .say, .emote, .unknown: return P.say
        }
    }

    /// The line as each client language prints it.
    static func screenText(_ s: Spoken, locale: ClientLocale) -> String {
        guard let who = s.sender else { return s.body }
        let ko = locale == .koKR
        switch s.channel {
        case .guild: return "[\(ko ? "길드" : "Guild")] [\(who)]: \(s.body)"
        case .party: return "[\(ko ? "파티" : "Party")] [\(who)]: \(s.body)"
        case .raid: return "[\(ko ? "공격대" : "Raid")] [\(who)]: \(s.body)"
        case .publicChannel: return "[\(ko ? "2. 거래" : "2. Trade")] [\(who)]: \(s.body)"
        case .whisper: return ko ? "[\(who)]님의 귓속말: \(s.body)" : "[\(who)] whispers: \(s.body)"
        case .yell: return ko ? "[\(who)]의 외침: \(s.body)" : "[\(who)] yells: \(s.body)"
        case .say: return ko ? "[\(who)]의 말: \(s.body)" : "[\(who)] says: \(s.body)"
        default: return "[\(who)]: \(s.body)"
        }
    }

    // MARK: - Rendering a scrolling window

    @MainActor struct Window {
        var locale: ClientLocale
        var style: SyntheticChat.Style
        var widthPoints: CGFloat = 520
        var rows = 8

        var label: String { "\(locale.rawValue) \(style.label)" }
        private var lineHeight: CGFloat { ceil(style.pointSize * 1.3 * style.scale) }
        var canvas: CGSize {
            CGSize(width: widthPoints, height: (lineHeight * CGFloat(rows) + 12 * style.scale) / style.scale)
        }

        /// Breaks a message at spaces the way the chat frame does.
        func wrap(_ text: String) -> [String] {
            let font = CTFontCreateWithName(style.fontName as CFString, style.pointSize * style.scale, nil)
            let limit = Double((widthPoints - 12) * style.scale)
            func width(_ s: String) -> Double {
                let attributed = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
            }
            var lines: [String] = []
            var current = ""
            for word in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                let candidate = current.isEmpty ? word : current + " " + word
                if current.isEmpty || width(candidate) <= limit {
                    current = candidate
                } else {
                    lines.append(current)
                    current = word
                }
            }
            if !current.isEmpty { lines.append(current) }
            return lines
        }

        /// The picture after `count` messages of the script arrived: newest line at the bottom.
        func image(after count: Int) -> CGImage? {
            var lines: [SyntheticChat.Line] = []
            for spoken in PipelineSelfTest.script.prefix(count) {
                for piece in wrap(PipelineSelfTest.screenText(spoken, locale: locale)) {
                    lines.append(SyntheticChat.Line("", "", PipelineSelfTest.color(spoken.channel), piece))
                }
            }
            var visible = Array(lines.suffix(rows))
            let blank = SyntheticChat.Line("", "", .white, "")
            visible.insert(contentsOf: Array(repeating: blank, count: rows - visible.count), at: 0)
            return SyntheticChat.render(lines: visible, style: style, canvasPoints: canvas)?.image
        }
    }

    /// How many messages arrive before each capture pair: singles, pairs and a burst of three.
    private static let arrivals = [3, 1, 2, 1, 1, 3, 1, 2, 1, 1, 2, 1, 3, 1, 2, 1, 1, 2, 1, 1]

    // MARK: - Fake translator

    final class FakeTranslator: Translating, @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var maxRunning = 0
        private(set) var batchSizes: [Int] = []
        private(set) var answered: [UUID: Int] = [:]
        private var calls = 0
        private var droppedOnce = false

        func engineName(for context: TranslationRequestContext) -> String { "Fake" }

        func translateIncoming(_ messages: [ChatMessage], context: TranslationRequestContext) async throws -> [UUID: TranslationOutput] {
            let call: Int = lock.withLock {
                running += 1
                maxRunning = max(maxRunning, running)
                batchSizes.append(messages.count)
                calls += 1
                return calls
            }
            defer { lock.withLock { running -= 1 } }
            try await Task.sleep(nanoseconds: 60_000_000)
            // The queue has to survive a rate limit and an answer with a line missing.
            if call == 2 { throw TranslationError.rateLimited }
            var out: [UUID: TranslationOutput] = [:]
            let dropFirst: Bool = lock.withLock {
                if call >= 4, !droppedOnce, messages.count > 0 { droppedOnce = true; return true }
                return false
            }
            for (i, message) in messages.enumerated() where !(dropFirst && i == 0) {
                out[message.id] = TranslationOutput(text: "번역: \(message.body)")
                lock.withLock { answered[message.id, default: 0] += 1 }
            }
            return out
        }

        func retranslate(_ message: ChatMessage, previous: String?, context: TranslationRequestContext) async throws -> TranslationOutput {
            TranslationOutput(text: "번역: \(message.body)")
        }

        func translateOutgoing(_ text: String, to language: String, context: TranslationRequestContext) async throws -> String { text }
    }

    // MARK: - Run

    static func run() async -> Int32 {
        let verbose = CommandLine.arguments.contains("--verbose")
        print("파이프라인 자가 진단 — 스크롤되는 합성 채팅을 OCR → 추적 → 번역 대기열까지 흘려 봅니다.\n")
        var failed = false
        for locale in ClientLocale.allCases {
            let font = SyntheticChat.fontName(for: locale)
            let styles: [SyntheticChat.Style] = [
                .init(fontName: font, pointSize: 14, scale: 2, background: .darkPanel, edge: .shadow),
                .init(fontName: font, pointSize: 14, scale: 2, background: .busy, edge: .shadow),
                .init(fontName: font, pointSize: 14, scale: 1, background: .darkPanel, edge: .shadow),
            ]
            for style in styles {
                let problems = await runSession(Window(locale: locale, style: style), verbose: verbose)
                if !problems.isEmpty { failed = true }
            }
        }
        if await !runQueueFaults() { failed = true }
        if await !runQueueRecovery() { failed = true }
        if await !runProviderSwitch() { failed = true }
        if !runProviders() { failed = true }
        if !runStorage() { failed = true }
        print(failed ? "\n결과: 실패" : "\n결과: 통과")
        return failed ? 1 : 0
    }

    private static func runSession(_ window: Window, verbose: Bool) async -> [String] {
        var problems: [String] = []
        let settings = AppSettings()
        let processor = FrameProcessor(recognizer: VisionTextRecognizer(), locale: window.locale)
        let translator = FakeTranslator()
        var states: [UUID: TranslationState] = [:]
        var emitted: [ChatMessage] = []
        var queued: Set<UUID> = []

        let queue = TranslationQueue(
            translator: { translator },
            context: { _ in TranslationRequestContext(reader: settings.readerLanguage, flavor: .classic, model: .haiku) },
            deliver: { outcomes in outcomes.forEach { states[$0.id] = $0.state } })
        // The fake translator answers one request with a rate limit; the real pause is 15 s.
        queue.timing.rateLimitPause = 0.4

        func take(_ messages: [ChatMessage]) {
            for message in messages {
                emitted.append(message)
                if TranslationPolicy.shouldTranslate(message, settings: settings) {
                    states[message.id] = .pending
                    queued.insert(message.id)
                    queue.enqueue(message)
                } else {
                    states[message.id] = .original
                }
            }
        }

        // Capture schedule: after each arrival the same picture is captured twice, as happens
        // when chat is slower than the capture interval; a quiet stretch at the end.
        var shown = 0
        var captures: [Int] = []
        for count in arrivals where shown < script.count {
            shown = min(script.count, shown + count)
            captures += [shown, shown]
        }
        while shown < script.count { shown += 1; captures += [shown, shown] }
        captures += Array(repeating: script.count, count: FrameProcessor.settleFrames + 2)

        var clock = Date()
        var frames = 0
        var dumpDir: URL?
        if let i = CommandLine.arguments.firstIndex(of: "--dump"), i + 1 < CommandLine.arguments.count {
            dumpDir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: dumpDir!, withIntermediateDirectories: true)
        }
        let started = CFAbsoluteTimeGetCurrent()
        for count in captures {
            guard let image = window.image(after: count) else {
                problems.append("이미지를 만들지 못했습니다")
                break
            }
            clock += 0.7
            frames += 1
            if let dumpDir {
                let name = "\(window.label)_\(String(format: "%02d", count)).png"
                    .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
                OCRSelfTest.writePNG(image, to: dumpDir.appendingPathComponent(name))
            }
            do {
                take(try await processor.process(image, now: clock))
            } catch {
                problems.append("OCR 오류: \(error)")
            }
            // Lets the queue's timers and answers run between captures, as in the app.
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let ocrSeconds = CFAbsoluteTimeGetCurrent() - started

        let deadline = Date().addingTimeInterval(20)
        while !queue.isIdle, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        if !queue.isIdle { problems.append("번역 대기열이 비워지지 않았습니다") }

        // --- Each scripted message exactly once, in order, with the right channel and sender.
        var used = Set<Int>()
        var lastIndex = -1
        var missing = 0, wrongChannel = 0, wrongSender = 0, outOfOrder = 0, wrongDecision = 0
        for spoken in script {
            var best: (index: Int, score: Double)?
            for (i, message) in emitted.enumerated() where !used.contains(i) {
                let score = similarity(spoken.body, message.body)
                if score > (best?.score ?? 0.75) { best = (i, score) }
            }
            guard let best else {
                missing += 1
                problems.append("빠짐: \(screenText(spoken, locale: window.locale))")
                continue
            }
            used.insert(best.index)
            let message = emitted[best.index]
            if best.index < lastIndex { outOfOrder += 1; problems.append("순서 뒤바뀜: \(message.rawText)") }
            lastIndex = max(lastIndex, best.index)
            if message.channel != spoken.channel {
                wrongChannel += 1
                problems.append("채널 \(spoken.channel.rawValue) 이어야 하는데 \(message.channel.rawValue): \(message.rawText)")
            }
            if message.sender != spoken.sender {
                wrongSender += 1
                problems.append("보낸 사람 \(spoken.sender ?? "없음") 이어야 하는데 \(message.sender ?? "없음"): \(message.rawText)")
            }
            if queued.contains(message.id) != spoken.translate {
                wrongDecision += 1
                problems.append("번역 \(spoken.translate ? "해야" : "하지 말아야") 하는데 반대로 처리: \(message.rawText)")
            }
        }
        let extras = emitted.indices.filter { !used.contains($0) }
        for i in extras { problems.append("대본에 없는 줄(중복 또는 쓰레기): \(emitted[i].rawText)") }

        // --- Translation queue behaviour.
        var notTranslated = 0
        for id in queued {
            if case .translated = states[id] { continue }
            notTranslated += 1
        }
        if notTranslated > 0 { problems.append("번역 결과가 붙지 않은 줄 \(notTranslated)개") }
        let twice = translator.answered.values.filter { $0 > 1 }.count
        if twice > 0 { problems.append("두 번 번역된 줄 \(twice)개") }
        if Set(translator.answered.keys) != queued { problems.append("번역기에 간 줄이 대기열에 넣은 줄과 다릅니다") }
        if translator.maxRunning > TranslationQueue.maxInFlight { problems.append("동시 요청 \(translator.maxRunning)개") }
        if let big = translator.batchSizes.max(), big > TranslationQueue.maxBatch { problems.append("한 요청에 \(big)줄") }
        if states.values.contains(.pending) { problems.append("대기 중으로 남은 줄이 있습니다") }

        print("[\(window.label)]")
        print(String(format: "  캡처 %d번 (OCR %d번, 캡처당 %.0f ms) · 대본 %d줄 → 내보낸 메시지 %d개",
                     frames, processor.ocrRuns, ocrSeconds / Double(max(1, frames)) * 1000, script.count, emitted.count))
        print("  빠짐 \(missing) · 군더더기 \(extras.count) · 순서 \(outOfOrder) · 채널 오류 \(wrongChannel) · 이름 오류 \(wrongSender) · 번역 판단 오류 \(wrongDecision)")
        print("  번역 요청 \(translator.batchSizes.count)번 (줄 수 \(translator.batchSizes)) · 동시 최대 \(translator.maxRunning) · 번역된 줄 \(queued.count - notTranslated)/\(queued.count)")
        if verbose {
            for message in emitted {
                print("    \(message.channel.rawValue) | \(message.sender ?? "-") | \(message.body)")
            }
        }
        if problems.isEmpty {
            print("  통과")
        } else {
            print("  실패")
            problems.forEach { print("    - \($0)") }
        }
        return problems
    }

    // MARK: - Queue under errors

    final class FailingTranslator: Translating, @unchecked Sendable {
        private let lock = NSLock()
        private var _error: TranslationError?
        private var _calls = 0
        var error: TranslationError? {
            get { lock.withLock { _error } }
            set { lock.withLock { _error = newValue } }
        }
        var calls: Int { lock.withLock { _calls } }

        func engineName(for context: TranslationRequestContext) -> String { "Fake" }
        func translateIncoming(_ messages: [ChatMessage], context: TranslationRequestContext) async throws -> [UUID: TranslationOutput] {
            lock.withLock { _calls += 1 }
            if let error { throw error }
            return Dictionary(uniqueKeysWithValues: messages.map { ($0.id, TranslationOutput(text: "ok")) })
        }
        func retranslate(_ message: ChatMessage, previous: String?, context: TranslationRequestContext) async throws -> TranslationOutput {
            TranslationOutput(text: "ok")
        }
        func translateOutgoing(_ text: String, to language: String, context: TranslationRequestContext) async throws -> String { text }
    }

    private static func runQueueFaults() async -> Bool {
        print("[번역 대기열 · 오류 상황]")
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            print("  \(condition ? "통과" : "실패")  \(what)")
            if !condition { ok = false }
        }
        func message(_ n: Int) -> ChatMessage {
            ChatMessage(channel: .guild, channelLabel: "Guild", sender: "Thrall", body: "line \(n)",
                        rawText: "[Guild] [Thrall]: line \(n)", color: .white, firstSeen: Date())
        }
        let translator = FailingTranslator()
        var states: [UUID: TranslationState] = [:]
        var errors: [TranslationError] = []
        let queue = TranslationQueue(
            translator: { translator },
            context: { _ in TranslationRequestContext(reader: .korean, flavor: .classic, model: .haiku) },
            deliver: { $0.forEach { states[$0.id] = $0.state } })
        queue.onError = { errors.append($0) }
        func settle() async {
            let deadline = Date().addingTimeInterval(10)
            repeat { try? await Task.sleep(nanoseconds: 50_000_000) } while !queue.isIdle && Date() < deadline
        }

        // A bad key fails everything waiting, with one request, and later lines without any.
        translator.error = .invalidAPIKey
        let first = (0..<30).map(message)
        first.forEach(queue.enqueue)
        await settle()
        expect(first.allSatisfy { states[$0.id] == .failed(TranslationError.invalidAPIKey.userMessage) },
               "키 오류: 기다리던 30줄 모두 실패로 표시")
        expect(translator.calls <= 2, "키 오류: 요청은 \(translator.calls)번뿐")
        let callsBefore = translator.calls
        let late = message(100)
        queue.enqueue(late)
        await settle()
        expect(states[late.id] == .failed(TranslationError.invalidAPIKey.userMessage) && translator.calls == callsBefore,
               "키 오류 직후의 새 줄은 요청 없이 실패")

        // A new key: translating again.
        translator.error = nil
        queue.clearErrors()
        let fresh = message(200)
        queue.enqueue(fresh)
        queue.enqueue(fresh)
        await settle()
        expect(states[fresh.id] == .translated("ok"), "키를 바꾼 뒤에는 다시 번역")
        expect(translator.calls == callsBefore + 1, "같은 줄을 두 번 넣어도 요청은 한 번")

        // A network failure is retried once, then reported.
        translator.error = .network("끊김")
        let offline = message(300)
        let before = translator.calls
        queue.enqueue(offline)
        await settle()
        expect(translator.calls == before + 2 && states[offline.id] == .failed(TranslationError.network("끊김").userMessage),
               "네트워크 오류: 한 번 더 해 보고 실패로 표시")

        // Cancelled work never reports back.
        translator.error = nil
        let dropped = message(400)
        queue.enqueue(dropped)
        queue.cancelAll()
        await settle()
        expect(states[dropped.id] == nil, "기록을 지우면 기다리던 줄은 버림")
        expect(!errors.isEmpty, "오류가 알림으로 전달됨")
        return ok
    }

    // MARK: - Queue: one bad line, slow answers, rate limits

    /// Answers through a closure, so each check scripts exactly what the provider does.
    final class ScriptedTranslator: Translating, @unchecked Sendable {
        struct Call {
            var bodies: [String]
            var recent: [String]
        }
        typealias Script = @Sendable (_ call: Int, _ messages: [ChatMessage], _ context: TranslationRequestContext) throws -> Void

        private let lock = NSLock()
        private var _calls: [Call] = []
        private var _open = true
        private let script: Script

        init(_ script: @escaping Script) { self.script = script }

        var calls: [Call] { lock.withLock { _calls } }
        func hold() { lock.withLock { _open = false } }
        func release() { lock.withLock { _open = true } }

        func engineName(for context: TranslationRequestContext) -> String { "Scripted" }
        func translateIncoming(_ messages: [ChatMessage], context: TranslationRequestContext) async throws -> [UUID: TranslationOutput] {
            let call: Int = lock.withLock {
                _calls.append(Call(bodies: messages.map(\.body), recent: context.recent.map(\.body)))
                return _calls.count
            }
            while !lock.withLock({ _open }) { try await Task.sleep(nanoseconds: 10_000_000) }
            try script(call, messages, context)
            return Dictionary(uniqueKeysWithValues: messages.map { ($0.id, TranslationOutput(text: "ok: \($0.body)")) })
        }
        func retranslate(_ message: ChatMessage, previous: String?, context: TranslationRequestContext) async throws -> TranslationOutput {
            TranslationOutput(text: "ok")
        }
        func translateOutgoing(_ text: String, to language: String, context: TranslationRequestContext) async throws -> String { text }
    }

    private static func runQueueRecovery() async -> Bool {
        print("[번역 대기열 · 거절·지연·한도]")
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            print("  \(condition ? "통과" : "실패")  \(what)")
            if !condition { ok = false }
        }
        func message(_ body: String) -> ChatMessage {
            ChatMessage(channel: .guild, channelLabel: "Guild", sender: "Thrall", body: body,
                        rawText: "[Guild] [Thrall]: \(body)", color: .white, firstSeen: Date())
        }
        func wait(seconds: TimeInterval = 10, until done: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        func isTranslated(_ state: TranslationState?) -> Bool {
            if case .translated = state { return true } else { return false }
        }
        /// A queue on `translator` whose requests carry `recent` as context.
        func makeQueue(_ translator: ScriptedTranslator, recent: [ChatMessage] = [],
                       states: @escaping (UUID, TranslationState) -> Void) -> TranslationQueue {
            TranslationQueue(
                translator: { translator },
                context: { _ in TranslationRequestContext(reader: .korean, flavor: .classic, model: .haiku, recent: recent) },
                deliver: { $0.forEach { states($0.id, $0.state) } })
        }

        // One line a provider refuses: the other eleven of its request still get translated.
        do {
            let translator = ScriptedTranslator { _, messages, context in
                if (messages.map(\.body) + context.recent.map(\.body)).contains(where: { $0.contains("BAD") }) { throw TranslationError.refused }
            }
            var states: [UUID: TranslationState] = [:]
            var errors: [TranslationError] = []
            let queue = makeQueue(translator, recent: [message("earlier line")]) { states[$0] = $1 }
            queue.onError = { errors.append($0) }
            let lines = (0..<12).map { message($0 == 7 ? "BAD line" : "fine line \($0)") }
            lines.forEach(queue.enqueue)
            await wait { queue.isIdle }
            let good = lines.filter { !$0.body.contains("BAD") }
            expect(good.allSatisfy { isTranslated(states[$0.id]) }
                   && states[lines[7].id] == .failed(TranslationError.refused.userMessage),
                   "거절당한 요청 12줄 중 11줄은 번역되고, 문제의 한 줄만 실패 (요청 \(translator.calls.count)번)")
            expect(translator.calls.count <= 10 && translator.calls.dropFirst().allSatisfy { $0.recent.isEmpty },
                   "나눠 다시 보낼 때는 앞 대화 없이 그 줄들만 보냄")
            expect(errors == [.refused], "거절 알림은 끝내 실패한 줄에 대해 한 번")
        }

        // The refused text sits in the context, not in the request's own lines.
        do {
            let poison = message("POISON said earlier")
            let translator = ScriptedTranslator { _, _, context in
                if context.recent.contains(where: { $0.body.contains("POISON") }) { throw TranslationError.refused }
            }
            var states: [UUID: TranslationState] = [:]
            let queue = makeQueue(translator, recent: [poison]) { states[$0] = $1 }
            let lines = (0..<3).map { message("after poison \($0)") }
            lines.forEach(queue.enqueue)
            await wait { queue.isIdle }
            let before = translator.calls.count
            let later = message("a later line")
            queue.enqueue(later)
            await wait { queue.isIdle }
            expect((lines + [later]).allSatisfy { isTranslated(states[$0.id]) },
                   "앞 대화 때문에 거절당한 줄들도 앞 대화를 빼고 번역됨")
            expect(translator.calls.count == before + 1 && translator.calls.last?.recent.isEmpty == true,
                   "거절당한 요청에 들어 있던 앞 대화는 그 뒤 요청에 다시 넣지 않음")
        }

        // An answer that cannot be used for a big request: smaller requests instead of failing all.
        do {
            let translator = ScriptedTranslator { _, messages, _ in
                if messages.count > 3 { throw TranslationError.unusableReply("끊김") }
            }
            var states: [UUID: TranslationState] = [:]
            let queue = makeQueue(translator) { states[$0] = $1 }
            let lines = (0..<12).map { message("long batch \($0)") }
            lines.forEach(queue.enqueue)
            await wait { queue.isIdle }
            expect(lines.allSatisfy { isTranslated(states[$0.id]) }, "쓸 수 없는 응답: 줄을 나눠 다시 보내 모두 번역 (요청 \(translator.calls.count)번)")
        }

        // Time-outs: the provider may still bill what was given up on.
        do {
            let translator = ScriptedTranslator { _, _, _ in throw TranslationError.timedOut }
            var states: [UUID: TranslationState] = [:]
            let queue = makeQueue(translator) { states[$0] = $1 }
            let single = message("slow single")
            queue.enqueue(single)
            await wait { queue.isIdle }
            expect(translator.calls.count == 1 && states[single.id] == .failed(TranslationError.timedOut.userMessage),
                   "시간 초과: 한 줄짜리 요청은 다시 보내지 않음")
            let lines = (0..<4).map { message("slow batch \($0)") }
            lines.forEach(queue.enqueue)
            await wait { queue.isIdle }
            expect(translator.calls.count == 1 + 3 && translator.calls.suffix(2).allSatisfy { $0.bodies.count == 2 }
                   && lines.allSatisfy { states[$0.id] == .failed(TranslationError.timedOut.userMessage) },
                   "시간 초과: 여러 줄은 반으로 나눠 한 번만 더")
        }

        // A rate limit that lasts: the lines wait it out instead of being dropped after four tries.
        do {
            let translator = ScriptedTranslator { call, _, _ in
                if call <= 5 { throw TranslationError.rateLimited }
            }
            var states: [UUID: TranslationState] = [:]
            let queue = makeQueue(translator) { states[$0] = $1 }
            queue.timing.rateLimitPause = 0.1
            queue.timing.rateLimitMaxPause = 0.2
            let line = message("rate limited")
            queue.enqueue(line)
            await wait { queue.isIdle }
            expect(isTranslated(states[line.id]) && translator.calls.count == 6, "요청 한도 오류 다섯 번 뒤에도 그 줄은 번역됨")
        }

        // Switching provider during a long rate-limit pause translates at once.
        do {
            let translator = ScriptedTranslator { call, _, _ in
                if call == 1 { throw TranslationError.rateLimited }
            }
            var states: [UUID: TranslationState] = [:]
            let queue = makeQueue(translator) { states[$0] = $1 }
            let line = message("waiting for the switch")
            queue.enqueue(line)
            await wait { translator.calls.count == 1 && states[line.id] == nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
            let switched = Date()
            queue.clearErrors()
            await wait(seconds: 5) { queue.isIdle }
            expect(isTranslated(states[line.id]) && Date().timeIntervalSince(switched) < 2,
                   "한도 오류로 쉬는 중(15초)에 제공자를 바꾸면 기다리던 줄이 바로 번역됨")
            // New lines are not held back by a stale timer either.
            let next = message("after the switch")
            queue.enqueue(next)
            await wait(seconds: 3) { queue.isIdle }
            expect(isTranslated(states[next.id]), "그 뒤의 새 줄도 바로 번역")
        }

        // A failed line can be sent again through the ordinary queue.
        do {
            let failing = LockedFlag(true)
            let translator = ScriptedTranslator { _, _, _ in
                if failing.value { throw TranslationError.badResponse("서버 오류") }
            }
            var states: [UUID: TranslationState] = [:]
            let queue = makeQueue(translator) { states[$0] = $1 }
            let line = message("retry me")
            queue.enqueue(line)
            await wait { queue.isIdle }
            let failed = states[line.id] == .failed(TranslationError.badResponse("서버 오류").userMessage)
            queue.enqueue(line)
            await wait { queue.isIdle }
            let ignored = translator.calls.count == 1
            failing.value = false
            queue.retry(line)
            await wait { queue.isIdle }
            expect(failed && ignored && isTranslated(states[line.id]) && translator.calls.count == 2,
                   "실패한 줄은 [다시 시도]로 평소 번역기에 한 번 더 보낼 수 있음")
        }

        // Lines that trickle in while a request is out share the next request.
        do {
            let translator = ScriptedTranslator { _, _, _ in }
            var states: [UUID: TranslationState] = [:]
            let queue = makeQueue(translator) { states[$0] = $1 }
            queue.timing.holdWhileBusy = 5
            translator.hold()
            let first = message("first capture")
            queue.enqueue(first)
            await wait { translator.calls.count == 1 }
            var later: [ChatMessage] = []
            for n in 0..<3 {
                let line = message("capture \(n + 2)")
                later.append(line)
                queue.enqueue(line)
                // Longer than the debounce, like consecutive captures.
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            let heldBack = translator.calls.count == 1
            translator.release()
            await wait { queue.isIdle }
            expect(heldBack && translator.calls.count == 2 && translator.calls.last?.bodies.count == 3
                   && ([first] + later).allSatisfy { isTranslated(states[$0.id]) },
                   "요청이 나가 있는 동안 들어온 줄들은 다음 요청 하나에 모아 보냄 (요청 \(translator.calls.count)번)")
        }

        // The same line again is answered from memory.
        do {
            var memo = TranslationMemo()
            func chat(_ channel: ChatChannel, _ sender: String, _ body: String) -> ChatMessage {
                ChatMessage(channel: channel, channelLabel: nil, sender: sender, body: body, rawText: body, color: .white, firstSeen: Date())
            }
            let advert = chat(.publicChannel, "Garrosh", "LFM Molten Core tonight, need 2 healers!")
            memo.store(.init(text: "화산 심장부 힐러 2명 구함", note: nil, engine: "Haiku"), for: advert, reader: .korean)
            let repost = chat(.publicChannel, "Thrall", "LFM  molten core tonight - need 2 healers")
            expect(memo.lookup(repost, reader: .korean)?.text == "화산 심장부 힐러 2명 구함",
                   "되풀이되는 광고는 앞의 번역을 다시 씀 (띄어쓰기·문장부호·보낸 사람이 달라도)")
            expect(memo.lookup(chat(.guild, "Garrosh", advert.body), reader: .korean) == nil
                   && memo.lookup(advert, reader: .english) == nil
                   && memo.lookup(chat(.publicChannel, "Garrosh", "LFM Molten Core tonight, need 3 healers!"), reader: .korean) == nil,
                   "다른 채널 묶음·다른 읽는 언어·숫자가 다른 글은 다시 번역")
            let short = chat(.guild, "Jaina", "inv pls")
            memo.store(.init(text: "초대 좀", note: nil, engine: nil), for: short, reader: .korean)
            expect(memo.lookup(short, reader: .korean) == nil, "아주 짧은 말은 앞뒤 맥락을 타므로 기억하지 않음")
            for n in 0..<(TranslationMemo.capacity + 50) {
                memo.store(.init(text: "t", note: nil, engine: nil), for: chat(.guild, "A", "filler line number \(n)"), reader: .korean)
            }
            expect(memo.count == TranslationMemo.capacity && memo.lookup(repost, reader: .korean) == nil, "기억은 \(TranslationMemo.capacity)줄까지")
        }

        // Switching a tab on translates what is already on screen for it.
        do {
            func entry(_ channel: ChatChannel, _ body: String, _ state: TranslationState = .original) -> ChatEntry {
                ChatEntry(message: ChatMessage(channel: channel, channelLabel: nil, sender: "A", body: body, rawText: body,
                                               color: .white, firstSeen: Date()), state: state)
            }
            var entries = [
                entry(.publicChannel, "WTS arcanite bars cheap"), entry(.guild, "hello guild", .translated("길드 안녕")),
                entry(.publicChannel, "거래 채널 한국어 글"), entry(.yell, "LF2M UBRS need healer"),
                entry(.publicChannel, "LFM strat live need tank", .failed("x")), entry(.system, "You receive loot"),
            ]
            entries += (0..<40).map { entry(.publicChannel, "LFG scholomance mage number \($0)") }
            let picked = TranslationPolicy.catchUp(entries, groups: [.publicChannel], reader: .korean, limit: 30)
            expect(picked == Array(16..<46), "꺼 두었던 탭을 켜면 그 채널의 최근 원문 30줄만 번역 대상")
            let few = TranslationPolicy.catchUp(Array(entries.prefix(6)), groups: [.publicChannel, .general], reader: .korean, limit: 30)
            expect(few == [0, 3], "이미 번역됐거나 실패한 줄, 한국어 글, 시스템 글, 다른 탭의 글은 건드리지 않음")
        }
        return ok
    }

    final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Bool
        init(_ value: Bool) { _value = value }
        var value: Bool {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    // MARK: - Providers

    /// Refuses every request, so nothing here can reach the network even by mistake.
    final class NoNetwork: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }

    private static func runProviders() -> Bool {
        print("[AI 제공자·키]")
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            print("  \(condition ? "통과" : "실패")  \(what)")
            if !condition { ok = false }
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("runespeak-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let paths = AppPaths(root: base)
        do { try paths.ensureDirectories() } catch {
            expect(false, "임시 폴더 만들기: \(error)")
            return false
        }
        let store = SettingsStore(paths: paths)
        let glossary = GlossaryStore(paths: paths, flavor: .classic)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoNetwork.self]
        let session = URLSession(configuration: configuration)
        func provider(of translator: Translating) -> AIProvider? { (translator as? LLMTranslator)?.provider }
        func context(_ settings: AppSettings) -> TranslationRequestContext {
            TranslationRequestContext(reader: .korean, flavor: .classic, model: settings.modelID())
        }

        var settings = AppSettings()
        let hub = TranslatorHub(store: store, glossary: glossary, usage: nil, session: session)
        expect(hub.keyedProviders.isEmpty && hub.activeProvider(for: settings) == nil
               && hub.translator(for: settings) is MyMemoryTranslator,
               "키가 하나도 없으면 무료 번역(MyMemory)")

        hub.setKey("  test-key-claude-0000\n", for: .claude)
        hub.setKey("test-key-gemini-0000", for: .gemini)
        expect(hub.keyedProviders == [.claude, .gemini]
               && store.loadAPIKey(for: .claude) == "test-key-claude-0000"
               && !fm.fileExists(atPath: paths.keyFile(for: .openai).path),
               "키는 제공자별 파일에 (앞뒤 공백 제거)")

        for candidate in AIProvider.allCases {
            settings.provider = candidate
            let translator = hub.translator(for: settings)
            if hub.hasKey(candidate) {
                let name = translator.engineName(for: context(settings))
                expect(provider(of: translator) == candidate && hub.activeProvider(for: settings) == candidate
                       && !name.isEmpty && name != "MyMemory",
                       "\(candidate.shortName) 선택 → \(candidate.shortName) 번역기 (\(name))")
            } else {
                expect(translator is MyMemoryTranslator && hub.activeProvider(for: settings) == nil,
                       "\(candidate.shortName) 선택, 키 없음 → 무료 번역(MyMemory)")
            }
        }

        settings.provider = .gemini
        let gemini = hub.translator(for: settings)
        settings.provider = .claude
        _ = hub.translator(for: settings)
        settings.provider = .gemini
        expect(hub.translator(for: settings) === gemini, "제공자를 오가도 같은 번역기를 다시 씀")
        settings.setModelID("gemini-3.8-flash", for: .gemini)
        expect(hub.translator(for: settings) === gemini
               && gemini.engineName(for: context(settings)) == ModelCatalog.displayName(provider: .gemini, modelID: "gemini-3.8-flash"),
               "모델을 바꾸면 번역기는 그대로, 요청의 모델만 바뀜")
        hub.setKey("test-key-gemini-1111", for: .gemini)
        let replaced = hub.translator(for: settings)
        expect(replaced !== gemini && provider(of: replaced) == .gemini, "키를 바꾸면 새 번역기")

        let restarted = TranslatorHub(store: store, glossary: glossary, usage: nil, session: session)
        expect(restarted.keyedProviders == [.claude, .gemini] && provider(of: restarted.translator(for: settings)) == .gemini,
               "다시 켜면 저장된 키를 모두 읽음")

        hub.setKey("", for: .gemini)
        expect(!hub.hasKey(.gemini) && !fm.fileExists(atPath: paths.keyFile(for: .gemini).path)
               && hub.translator(for: settings) is MyMemoryTranslator,
               "고른 제공자의 키를 지우면 파일 삭제 + 무료 번역으로")
        settings.provider = .claude
        expect(provider(of: hub.translator(for: settings)) == .claude, "다른 제공자의 키는 그대로")

        // What the UI shows for the same situations.
        let state = AppState()
        state.settings = settings
        state.keyedProviders = hub.keyedProviders
        expect(state.hasAPIKey && state.activeProvider == .claude && state.activeEngineTitle == "Claude Haiku 5.5",
               "화면 상태: 고른 제공자에 키가 있음 (\(state.activeEngineTitle))")
        state.settings.provider = .openai
        expect(!state.hasAPIKey && state.activeProvider == nil && state.activeEngineTitle.contains("MyMemory")
               && state.errorText(.invalidAPIKey) == TranslationError.invalidAPIKey.userMessage,
               "화면 상태: 선택한 제공자의 키가 비면 엔진 이름이 MyMemory로 바뀜")
        state.settings.setModelID("gpt-9-custom", for: .openai)
        state.liveModels[.openai] = [ModelInfo(provider: .openai, id: "gpt-6-luna", displayName: "GPT-6 Luna"),
                                     ModelInfo(provider: .openai, id: "gpt-7-new", displayName: "GPT-7 New")]
        let offered = state.models(for: .openai).map(\.id)
        expect(offered == ModelCatalog.builtIn(.openai).map(\.id) + ["gpt-7-new", "gpt-9-custom"],
               "모델 목록 = 기본 목록 + 불러온 목록 + 직접 입력한 모델 (중복 없음)")
        return ok
    }

    /// Waits inside each request until released, so the test decides what is in flight when.
    final class GatedTranslator: Translating, @unchecked Sendable {
        let name: String
        private let lock = NSLock()
        private var _started = 0
        private var _open: Bool
        private var _error: TranslationError?
        private var _answered: [UUID: Int] = [:]

        init(name: String, open: Bool) { self.name = name; self._open = open }

        var started: Int { lock.withLock { _started } }
        var answered: [UUID: Int] { lock.withLock { _answered } }
        func release() { lock.withLock { _open = true } }
        func fail(with error: TranslationError) { lock.withLock { _error = error } }

        func engineName(for context: TranslationRequestContext) -> String { name }
        func translateIncoming(_ messages: [ChatMessage], context: TranslationRequestContext) async throws -> [UUID: TranslationOutput] {
            lock.withLock { _started += 1 }
            while !lock.withLock({ _open }) { try await Task.sleep(nanoseconds: 10_000_000) }
            if let error = lock.withLock({ _error }) { throw error }
            lock.withLock { messages.forEach { _answered[$0.id, default: 0] += 1 } }
            return Dictionary(uniqueKeysWithValues: messages.map { ($0.id, TranslationOutput(text: "\(name): \($0.body)")) })
        }
        func retranslate(_ message: ChatMessage, previous: String?, context: TranslationRequestContext) async throws -> TranslationOutput {
            TranslationOutput(text: name)
        }
        func translateOutgoing(_ text: String, to language: String, context: TranslationRequestContext) async throws -> String { text }
    }

    private static func runProviderSwitch() async -> Bool {
        print("[번역 대기열 · 제공자 바꾸기]")
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            print("  \(condition ? "통과" : "실패")  \(what)")
            if !condition { ok = false }
        }
        func message(_ n: Int) -> ChatMessage {
            ChatMessage(channel: .guild, channelLabel: "Guild", sender: "Thrall", body: "line \(n)",
                        rawText: "[Guild] [Thrall]: line \(n)", color: .white, firstSeen: Date())
        }
        func wait(until done: () -> Bool) async {
            let deadline = Date().addingTimeInterval(10)
            while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        }

        // Switching with requests out and lines waiting: nothing lost, nothing sent twice.
        do {
            let old = GatedTranslator(name: "old", open: false)
            let new = GatedTranslator(name: "new", open: true)
            var current: GatedTranslator = old
            var outcomes: [UUID: TranslationQueue.Outcome] = [:]
            let queue = TranslationQueue(
                translator: { current },
                context: { _ in TranslationRequestContext(reader: .korean, flavor: .classic, model: current.name) },
                deliver: { $0.forEach { outcomes[$0.id] = $0 } })
            let lines = (0..<30).map(message)
            lines.forEach(queue.enqueue)
            await wait { old.started == TranslationQueue.maxInFlight }
            current = new
            queue.clearErrors()
            old.release()
            await wait { queue.isIdle }
            let sentOld = TranslationQueue.maxInFlight * TranslationQueue.maxBatch
            expect(lines.allSatisfy { if case .translated = outcomes[$0.id]?.state { return true } else { return false } },
                   "바꾸는 동안 기다리던 30줄이 모두 번역됨")
            expect(old.answered.count == sentOld && new.answered.count == lines.count - sentOld
                   && Set(old.answered.keys).isDisjoint(with: new.answered.keys)
                   && (Array(old.answered.values) + Array(new.answered.values)).allSatisfy { $0 == 1 },
                   "이미 보낸 \(old.answered.count)줄은 이전 번역기가 마무리, 남은 \(new.answered.count)줄은 새 번역기로 (중복 없음)")
            expect(lines.allSatisfy { outcomes[$0.id]?.engine == (old.answered[$0.id] != nil ? "old" : "new") },
                   "줄마다 실제로 번역한 쪽 이름이 붙음")
        }

        // An error of the provider just left neither fails its lines nor pauses the new one.
        do {
            let old = GatedTranslator(name: "old", open: false)
            old.fail(with: .invalidAPIKey)
            let new = GatedTranslator(name: "new", open: true)
            var current: GatedTranslator = old
            var outcomes: [UUID: TranslationQueue.Outcome] = [:]
            var errors: [TranslationError] = []
            let queue = TranslationQueue(
                translator: { current },
                context: { _ in TranslationRequestContext(reader: .korean, flavor: .classic, model: current.name) },
                deliver: { $0.forEach { outcomes[$0.id] = $0 } })
            queue.onError = { errors.append($0) }
            queue.describe = { "설명: " + $0.userMessage }
            let lines = (0..<5).map(message)
            lines.forEach(queue.enqueue)
            await wait { old.started == 1 }
            current = new
            queue.clearErrors()
            old.release()
            await wait { queue.isIdle }
            let late = message(50)
            queue.enqueue(late)
            await wait { queue.isIdle }
            expect((lines + [late]).allSatisfy { outcomes[$0.id]?.state == .translated("new: \($0.body)") } && errors.isEmpty,
                   "떠난 제공자의 키 오류는 새 제공자를 막지 않고, 그 줄들은 새 번역기로 다시 감")

            // Without a switch the same error still blocks, with the app's wording on the lines.
            new.fail(with: .insufficientCredit)
            let doomed = message(60)
            queue.enqueue(doomed)
            await wait { queue.isIdle }
            expect(outcomes[doomed.id]?.state == .failed("설명: " + TranslationError.insufficientCredit.userMessage)
                   && errors == [.insufficientCredit],
                   "바꾸지 않았을 때의 오류는 그대로 표시 (앱이 정한 문구로)")
        }
        return ok
    }

    // MARK: - Files

    private static func runStorage() -> Bool {
        print("[설정·사전 파일]")
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            print("  \(condition ? "통과" : "실패")  \(what)")
            if !condition { ok = false }
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("runespeak-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let paths = AppPaths(root: base.appendingPathComponent("app", isDirectory: true))
        let store = SettingsStore(paths: paths)
        do { try paths.ensureDirectories() } catch {
            expect(false, "임시 폴더 만들기: \(error)")
            return false
        }

        var settings = AppSettings()
        settings.provider = .gemini
        settings.setModelID("gemini-3.8-flash", for: .gemini)
        settings.setRetranslateModelID("my-own-model", for: .openai)
        settings.enabledGroups = [.guild]
        settings.captureInterval = 99
        settings.overlayFrame = CGRect(x: 1, y: 2, width: 300, height: 200)
        store.save(SettingsStore.sanitized(settings))
        let loaded = store.loadSettings()
        expect(loaded.enabledGroups == [.guild] && loaded.overlayFrame == settings.overlayFrame,
               "settings.json 저장 후 다시 읽기")
        expect(loaded.provider == .gemini && loaded.modelID() == "gemini-3.8-flash"
               && loaded.retranslateModelID(for: .openai) == "my-own-model"
               && loaded.modelID(for: .claude) == ModelCatalog.defaultModelID(for: .claude, role: .fast),
               "AI 제공자와 제공자별 모델이 저장됨 (고르지 않은 것은 기본 모델)")
        expect(loaded.captureInterval == 5, "범위를 벗어난 값은 고쳐서 저장")
        try? Data("{ broken".utf8).write(to: paths.settingsFile)
        expect(store.loadSettings() == AppSettings(), "깨진 settings.json은 기본값으로")

        try? Data(#"{"provider":"some-new-ai","translationModels":"oops","fontSize":18}"#.utf8).write(to: paths.settingsFile)
        let odd = store.loadSettings()
        expect(odd.provider == .claude && odd.fontSize == 18 && odd.modelID() == "claude-haiku-5-5",
               "모르는 제공자·망가진 모델 값은 기본값으로 (나머지 설정은 유지)")

        let region = CaptureRegion(rect: CGRect(x: 10, y: 20, width: 600, height: 250))
        store.save(region: region)
        expect(store.loadRegion() == region, "chat_area.json 저장 후 다시 읽기")

        // One key file per provider, each owner-only, each removed on its own.
        let names: [AIProvider: String] = [.claude: "key_claude.txt", .openai: "key_openai.txt", .gemini: "key_gemini.txt"]
        for provider in AIProvider.allCases {
            store.saveAPIKey("test-key-\(provider.rawValue)-0000", for: provider)
        }
        for provider in AIProvider.allCases {
            let file = paths.keyFile(for: provider)
            let mode = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
            expect(file.lastPathComponent == names[provider] && mode == 0o600
                   && store.loadAPIKey(for: provider) == "test-key-\(provider.rawValue)-0000",
                   "\(names[provider] ?? "?")는 소유자만 읽기(0600), 제 키만 담음")
        }
        store.saveAPIKey(nil, for: .openai)
        expect(store.loadAPIKey(for: .openai) == nil && !fm.fileExists(atPath: paths.keyFile(for: .openai).path)
               && store.loadAPIKey(for: .claude) != nil && store.loadAPIKey(for: .gemini) != nil,
               "키를 지우면 그 제공자의 파일만 삭제")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.keyFile(for: .gemini).path)
        _ = store.loadAPIKey(for: .gemini)
        let fixed = (try? fm.attributesOfItem(atPath: paths.keyFile(for: .gemini).path))?[.posixPermissions] as? Int
        expect(fixed == 0o600, "느슨한 권한의 키 파일은 읽을 때 0600으로 고침")
        store.saveAPIKey(nil, for: .claude)
        store.saveAPIKey(nil, for: .gemini)
        expect(AIProvider.allCases.allSatisfy { !fm.fileExists(atPath: paths.keyFile(for: $0).path) }, "모두 지우면 키 파일이 남지 않음")

        // Fetched model lists survive a restart; prices come back from the built-in table.
        let lists: [AIProvider: [ModelInfo]] = [.openai: [
            ModelInfo(provider: .openai, id: "gpt-6-luna", displayName: "GPT-6 Luna"),
            ModelInfo(provider: .openai, id: "gpt-9-custom", displayName: "GPT-9 Custom"),
        ]]
        store.save(modelLists: lists)
        let reread = store.loadModelLists()
        expect(reread[.openai]?.map(\.id) == ["gpt-6-luna", "gpt-9-custom"] && reread[.openai]?.first?.price != nil
               && reread[.openai]?.last?.price == nil && reread[.claude] == nil,
               "불러온 모델 목록 저장 후 다시 읽기")
        store.save(modelLists: [:])
        expect(store.loadModelLists().isEmpty, "모델 목록을 비우면 파일도 삭제")

        // Dictionary upkeep at launch (BundledDictionary.install): bundled files are copied and
        // nothing of the user's is touched.
        let bundled = base.appendingPathComponent("bundle-data", isDirectory: true)
        try? fm.createDirectory(at: bundled, withIntermediateDirectories: true)
        try? paths.ensureDirectories()
        let official = DictionaryFiles.names(for: .classic).officialNames
        try? Data("# test\nkind\tkorean\tenglish\nzone\t타나리스\tTanaris\ninstance\t줄파락\tZul'Farrak\n".utf8)
            .write(to: bundled.appendingPathComponent(official))
        try? Data("korean\tenglish\taliases\n줄파락\tZul'Farrak\tZF\n".utf8)
            .write(to: bundled.appendingPathComponent(DictionaryFiles.nicknames))
        try? Data("not a dictionary".utf8).write(to: bundled.appendingPathComponent("readme.txt"))
        try? Data().write(to: bundled.appendingPathComponent("empty.tsv"))

        try? Data("mine".utf8).write(to: paths.dataDirectory.appendingPathComponent("notes.txt"))
        try? Data("stale".utf8).write(to: paths.dataDirectory.appendingPathComponent(official))
        // The user's own files, which the upkeep must leave byte for byte.
        store.save(SettingsStore.sanitized(settings))
        store.save(region: region)
        store.saveAPIKey("test-key-claude-0000", for: .claude)
        try? Data("타나리스\tTanaris\t타나, Tana\n".utf8).write(to: paths.myTermsFile)
        try? Data("gz on the drop\t득템 축하해요\tgz = congratulations\n".utf8).write(to: paths.correctionsFile)
        let userFiles = [paths.settingsFile, paths.chatAreaFile, paths.keyFile(for: .claude), paths.myTermsFile,
                         paths.correctionsFile]
        func snapshot() -> [Data?] {
            userFiles.map { try? Data(contentsOf: $0) }
        }
        let before = snapshot()

        let installed = BundledDictionary.install(to: paths, from: bundled)
        let present = ((try? fm.contentsOfDirectory(atPath: paths.dataDirectory.path)) ?? []).sorted()
        expect(installed == [DictionaryFiles.nicknames, official]
               && present == [DictionaryFiles.nicknames, "notes.txt", official],
               "내장 사전(.tsv)만 데이터 폴더로 복사 (다른 내용이면 덮어씀): \(present)")
        let again = BundledDictionary.install(to: paths, from: bundled)
        expect(again.isEmpty,
               "두 번째 실행에서는 아무것도 바꾸지 않음")
        let keyMode = (try? fm.attributesOfItem(atPath: paths.keyFile(for: .claude).path))?[.posixPermissions] as? Int
        expect(before.allSatisfy { $0 != nil } && snapshot() == before && keyMode == 0o600,
               "사용자 파일(설정·채팅창 위치·AI 키·내 이름표·교정 기록)은 그대로")
        let glossary = GlossaryStore(paths: paths, flavor: .classic)
        let hinted = glossary.hints(for: ["LFM ZF", "타나 가요", "gz on the drop"])
        expect(glossary.entryCount == 3 && hinted.names.contains { $0.korean == "줄파락" }
               && hinted.names.contains { $0.english.hasPrefix("Tanaris") } && hinted.corrections.count == 1,
               "복사한 사전과 사용자 파일이 함께 읽힘 (이름 \(glossary.entryCount)개)")
        expect(BundledDictionary.install(to: paths, from: base.appendingPathComponent("nowhere")).isEmpty
               && BundledDictionary.install(to: paths, from: nil).isEmpty
               && ((try? fm.contentsOfDirectory(atPath: paths.dataDirectory.path)) ?? []).sorted() == present,
               "앱 번들에 사전이 없으면 있던 파일을 그대로 둠")
        store.saveAPIKey(nil, for: .claude)

        // Logs stay bounded.
        let log = base.appendingPathComponent("log.txt")
        for i in 0..<400 { appendLine("line \(i) " + String(repeating: "x", count: 40) + "\n", to: log, limit: 4000) }
        let size = ((try? fm.attributesOfItem(atPath: log.path))?[.size] as? Int) ?? -1
        let tail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        expect(size > 0 && size <= 4100 && tail.hasSuffix("line 399 " + String(repeating: "x", count: 40) + "\n")
               && tail.hasPrefix("line "), "로그 파일은 크기 제한을 넘지 않고 최신 줄을 유지 (\(size)바이트)")
        return ok
    }

    /// 1 = same text, ignoring spacing and letter case.
    private static func similarity(_ a: String, _ b: String) -> Double {
        func form(_ s: String) -> [Character] {
            Array(s.lowercased().precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace })
        }
        let x = form(a), y = form(b)
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(OCRSelfTest.levenshtein(x, y)) / Double(longest)
    }
}
