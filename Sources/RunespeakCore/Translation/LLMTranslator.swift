import Foundation

/// Translates through an LLM API. Everything that decides translation quality — the frozen
/// system prompt, glossary hints, the numbered-lines protocol, tolerant reply parsing, output
/// hygiene — lives here once; a `ProviderBackend` supplies only the wire format of its API.
///
/// Request shape, for every task and provider: frozen system prompt (the cacheable prefix) →
/// one user message holding a JSON payload → structured JSON output. See `TranslationPrompt`.
public class LLMTranslator: Translating, @unchecked Sendable {

    /// Knobs that only tests change.
    struct Tuning: Sendable {
        /// Extra attempts after a 429 / 5xx.
        var maxRetries = 2
        /// Longest single wait; a longer `retry-after` fails at once (live chat cannot wait).
        var maxRetryDelay: TimeInterval = 6
        var liveTimeout: TimeInterval = 20
        /// Live requests to a model whose thinking cannot be switched off: the answer arrives
        /// in one piece after the thinking, and a request given up on is billed all the same.
        var thinkingLiveTimeout: TimeInterval = 60
        var carefulTimeout: TimeInterval = 60
        var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    }

    typealias Feature = RequestFeature

    /// WoW's chat box limit, in UTF-8 bytes.
    public static let chatByteLimit = 255

    private enum Profile {
        /// Incoming and outgoing chat: lowest latency. Both use the same settings on purpose —
        /// thinking/effort are part of the cache key on some models.
        case live
        /// Retranslation: let the model reason.
        case careful
    }

    public let provider: AIProvider
    private let backend: ProviderBackend
    private let apiKey: String
    private let glossary: GlossaryProviding
    private let usage: UsageTracking?
    private let session: URLSession
    private let tuning: Tuning

    private let lock = NSLock()
    /// Optional request features the API rejected, per model id, until the app restarts.
    private var rejected: [String: Set<RequestFeature>] = [:]

    public convenience init(provider: AIProvider, apiKey: String, glossary: GlossaryProviding, usage: UsageTracking?, session: URLSession = .shared) {
        self.init(backend: ProviderBackends.backend(for: provider), apiKey: apiKey, glossary: glossary, usage: usage, session: session, tuning: Tuning())
    }

    init(backend: ProviderBackend, apiKey: String, glossary: GlossaryProviding, usage: UsageTracking?, session: URLSession, tuning: Tuning) {
        self.provider = backend.provider
        self.backend = backend
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.glossary = glossary
        self.usage = usage
        self.session = session
        self.tuning = tuning
    }

    // MARK: - Translating

    public func engineName(for context: TranslationRequestContext) -> String {
        backend.engineName(modelID: context.model)
    }

    public func translateIncoming(_ messages: [ChatMessage], context: TranslationRequestContext) async throws -> [UUID: TranslationOutput] {
        if messages.isEmpty { return [:] }
        let hints = glossary.hints(for: messages.map { Self.withoutLinks($0.body) })
        let lines = messages.enumerated().map { TranslationPrompt.line($0.offset + 1, from: $0.element) }
        let user = TranslationPrompt.userMessage(task: .incoming, reader: context.reader, flavor: context.flavor,
                                                 hints: hints, recent: context.recent, lines: lines)
        let reply = try await complete(user: user, model: context.model, profile: .live, expectedLines: messages.count)

        var result: [UUID: TranslationOutput] = [:]
        for (index, message) in messages.enumerated() {
            guard var text = reply.lines[index + 1].map(Self.singleLine), !text.isEmpty else { continue }
            text = TranslationPrompt.restoringLinks(in: text, from: message.body, counterparts: counterparts)
            if lines[index].emote {
                text = TranslationPrompt.emoteTranslation(text, reader: context.reader)
            } else {
                text = TranslationPrompt.withoutChannelPrefix(text, for: message)
            }
            if text.isEmpty { continue }
            result[message.id] = TranslationOutput(text: text)
        }
        if result.isEmpty {
            throw TranslationError.unusableReply(reply.truncated ? "응답이 중간에 끊겼습니다" : "번역 결과가 비어 있습니다")
        }
        return result
    }

    public func retranslate(_ message: ChatMessage, previous: String?, context: TranslationRequestContext) async throws -> TranslationOutput {
        let hints = glossary.hints(for: [Self.withoutLinks(message.body)])
        let line = TranslationPrompt.line(1, from: message)
        let user = TranslationPrompt.userMessage(task: .retranslate, reader: context.reader, flavor: context.flavor,
                                                 previous: previous, hints: hints, recent: context.recent,
                                                 lines: [line])
        let reply = try await complete(user: user, model: context.model, profile: .careful, expectedLines: 1)
        guard var text = reply.lines[1].map(Self.singleLine), !text.isEmpty else {
            throw TranslationError.badResponse(reply.truncated ? "응답이 중간에 끊겼습니다" : "번역 결과가 비어 있습니다")
        }
        text = TranslationPrompt.restoringLinks(in: text, from: message.body, counterparts: counterparts)
        if line.emote {
            text = TranslationPrompt.emoteTranslation(text, reader: context.reader)
        } else {
            text = TranslationPrompt.withoutChannelPrefix(text, for: message)
        }
        if text.isEmpty { throw TranslationError.badResponse("번역 결과가 비어 있습니다") }
        let note = reply.note.map(Self.singleLine).flatMap { $0.isEmpty ? nil : $0 }
        return TranslationOutput(text: text, note: note)
    }

    public func translateOutgoing(_ text: String, to language: String, context: TranslationRequestContext) async throws -> String {
        let source = Self.singleLine(text)
        if source.isEmpty { return "" }
        let target = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let hints = glossary.hints(for: [source])
        let user = TranslationPrompt.userMessage(task: .outgoing, reader: context.reader, flavor: context.flavor,
                                                 targetLanguage: target.isEmpty ? "English" : target,
                                                 hints: hints, recent: context.recent,
                                                 lines: [TranslationPrompt.Line(number: 1, channel: nil, sender: nil, text: source)])
        let reply = try await complete(user: user, model: context.model, profile: .live, expectedLines: 1)
        let line = Self.pasteable(reply.lines[1] ?? "")
        if line.isEmpty {
            throw TranslationError.badResponse(reply.truncated ? "응답이 중간에 끊겼습니다" : "번역 결과가 비어 있습니다")
        }
        return line
    }

    // MARK: - Hint lookup

    /// The official names of the thing a link names, in both languages (for telling which
    /// link a rewritten one was, see `TranslationPrompt.restoringLinks`).
    private func counterparts(of link: String) -> [String] {
        func name(_ entry: String) -> String {
            // "Undercity | UC": the official name stands in front of the bar.
            (entry.split(separator: "|").first.map(String.init) ?? entry).trimmingCharacters(in: .whitespaces)
        }
        let wanted = link.lowercased()
        return glossary.hints(for: [link]).names.flatMap { pair -> [String] in
            let ko = name(pair.korean), en = name(pair.english)
            return ko.lowercased() == wanted || en.lowercased() == wanted ? [ko, en] : []
        }
    }
    private var counterparts: (String) -> [String] { { [unowned self] in self.counterparts(of: $0) } }

    /// Incoming text without its [item / spell links]. A link is copied into the translation as
    /// it stands, so its name must not be looked up: an official counterpart among the hints
    /// reads as an order to translate the link after all.
    static func withoutLinks(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            let inside = rest[rest.index(after: open)...]
            guard let close = inside.firstIndex(where: { $0 == "]" || $0 == "[" }), inside[close] == "]",
                  rest.distance(from: open, to: close) <= 80 else {
                out += rest[...open]
                rest = inside
                continue
            }
            out += rest[..<open] + " "
            rest = inside[inside.index(after: close)...]
        }
        return out + rest
    }

    // MARK: - Output hygiene

    /// Chat lines are single lines; a model line break would break the overlay row / the paste.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Makes model output safe to paste into the WoW chat box: one line, no wrapping quotes,
    /// within the byte limit, and never starting with "/" — pasted text that begins with a slash
    /// would be executed by the game as a command, and the wording is influenced by untrusted chat.
    static func pasteable(_ raw: String) -> String {
        var line = singleLine(raw)
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("「", "」"), ("«", "»"), ("`", "`")]
        for (open, close) in quotePairs where line.count >= 2 && line.first == open && line.last == close {
            let inner = line.dropFirst().dropLast()
            // Only unwrap when the quotes wrap the whole line, not `"gg" he said "wp"`.
            if !inner.contains(open) && !inner.contains(close) {
                line = String(inner).trimmingCharacters(in: .whitespaces)
            }
            break
        }
        while line.first == "/" || line.first == " " { line.removeFirst() }
        return clamp(line, toUTF8Bytes: chatByteLimit)
    }

    /// The translation cut so that "<command> <translation>" still fits the chat box: the game
    /// counts the slash command pasted in front of it against the same limit.
    public static func fitChatBox(_ translation: String, after command: String?) -> String {
        let used = command.map { $0.utf8.count + 1 } ?? 0
        return clamp(translation, toUTF8Bytes: max(0, chatByteLimit - used))
    }

    /// Cuts at a word boundary when possible, never inside a character or an [item link].
    static func clamp(_ text: String, toUTF8Bytes limit: Int) -> String {
        if text.utf8.count <= limit { return text }
        var cut = text.startIndex
        var bytes = 0
        for index in text.indices {
            let size = String(text[index]).utf8.count
            if bytes + size > limit { break }
            bytes += size
            cut = text.index(after: index)
        }
        var head = text[..<cut]
        // A stray "[" near the start is not a link worth giving up the whole line for.
        if let open = head.lastIndex(of: "["), !head[open...].contains("]"),
           !head[..<open].allSatisfy({ $0 == " " }) {
            head = head[..<open]
        } else if cut < text.endIndex, text[cut] != " ", let space = head.lastIndex(of: " "),
                  head.distance(from: head.startIndex, to: space) > head.count / 2 {
            head = head[..<space]
        }
        return head.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Request

    private func features(for modelID: String, profile: Profile) -> Set<RequestFeature> {
        let set = backend.features(modelID: modelID, careful: profile == .careful)
        lock.lock()
        defer { lock.unlock() }
        return set.subtracting(rejected[modelID] ?? [])
    }

    private func reject(_ feature: RequestFeature, for modelID: String) {
        lock.lock()
        rejected[modelID, default: []].insert(feature)
        lock.unlock()
    }

    private func complete(user: String, model: String, profile: Profile, expectedLines: Int) async throws -> ModelReply {
        guard !apiKey.isEmpty else { throw TranslationError.missingAPIKey }
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { throw TranslationError.modelNotFound("") }
        let backend = self.backend

        // Each pass may drop one rejected feature, so the loop is bounded by the feature count.
        for _ in 0...RequestFeature.allCases.count {
            let active = features(for: modelID, profile: profile)
            var request = backend.request(apiKey: apiKey, modelID: modelID, system: TranslationPrompt.system, user: user,
                                          careful: profile == .careful, features: active)
            switch profile {
            case .careful: request.timeoutInterval = tuning.carefulTimeout
            case .live: request.timeoutInterval = active.contains(.thinkingOff) ? tuning.liveTimeout : tuning.thinkingLiveTimeout
            }

            let (data, response) = try await HTTPSupport.send(
                request, session: session, maxRetries: tuning.maxRetries, maxRetryDelay: tuning.maxRetryDelay,
                rateLimitNeedsRetryAfter: true,
                // An empty balance or a used-up quota also arrives as 429 on some APIs; waiting does not help.
                shouldRetry: { status, data in
                    let kind = backend.kind(of: backend.failure(status: status, data: data))
                    return kind == nil || kind == .rateLimited
                },
                sleep: tuning.sleep)
            if response.statusCode == 200 {
                return try handleSuccess(data, modelID: modelID, expectedLines: expectedLines)
            }
            let failure = backend.failure(status: response.statusCode, data: data)
            if response.statusCode == 400, let feature = backend.rejectedFeature(failure, among: active) {
                reject(feature, for: modelID)
                continue
            }
            throw failure.translationError(backend: backend, modelID: modelID)
        }
        throw TranslationError.badResponse("요청 형식을 서버가 받아들이지 않습니다")
    }

    private func handleSuccess(_ data: Data, modelID: String, expectedLines: Int) throws -> ModelReply {
        let response = try backend.parseResponse(data)
        if let u = response.usage {
            usage?.record(provider: provider, modelID: modelID, inputTokens: u.input, outputTokens: u.output,
                          cacheReadTokens: u.cacheRead, cacheWriteTokens: u.cacheWrite)
        }
        if response.refused { throw TranslationError.refused }
        var reply = ModelReply.parse(response.text, expectedLines: expectedLines)
        reply.truncated = response.truncated
        if reply.lines.isEmpty {
            throw TranslationError.unusableReply(reply.truncated ? "응답이 중간에 끊겼습니다" : "번역 결과를 해석할 수 없습니다")
        }
        return reply
    }
}

// MARK: - Reply parsing

/// The model's answer mapped to line numbers. Structured output makes the happy path plain JSON;
/// everything after the first attempt exists for truncated answers and for the mode without a schema.
struct ModelReply: Equatable {
    var lines: [Int: String] = [:]
    var note: String?
    var truncated = false

    static func parse(_ raw: String, expectedLines: Int) -> ModelReply {
        let text = stripCodeFence(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.isEmpty { return ModelReply() }

        if let reply = fromJSON(text, expectedLines: expectedLines) { return reply }
        if let open = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let close = text.lastIndex(where: { $0 == "}" || $0 == "]" }), open < close,
           let reply = fromJSON(String(text[open...close]), expectedLines: expectedLines) {
            return reply
        }
        let salvaged = salvage(text, expectedLines: expectedLines)
        if !salvaged.lines.isEmpty { return salvaged }

        let looksLikeJSON = text.hasPrefix("{") || text.hasPrefix("[")
        if !looksLikeJSON {
            // A plain sentence can only be the answer to a single-line request; do not look for
            // numbering in it ("1-2 healers needed" is not line 1).
            if expectedLines <= 1 { return ModelReply(lines: [1: text]) }
            let numbered = numberedLines(text, expectedLines: expectedLines)
            if !numbered.isEmpty { return ModelReply(lines: numbered) }
        }
        return ModelReply()
    }

    private static func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fromJSON(_ text: String, expectedLines: Int) -> ModelReply? {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else { return nil }
        var reply = ModelReply()
        let items: [Any]
        if let object = value as? [String: Any] {
            if let note = object["note"] as? String { reply.note = note }
            if let list = (object["translations"] ?? object["lines"] ?? object["results"]) as? [Any] {
                items = list
            } else if object["text"] != nil || object["translation"] != nil {
                items = [object]
            } else {
                return nil
            }
        } else if let list = value as? [Any] {
            items = list
        } else {
            return nil
        }
        for (position, item) in items.enumerated() {
            var number: Int?
            var body: String?
            if let entry = item as? [String: Any] {
                body = (entry["text"] ?? entry["translation"] ?? entry["t"]) as? String
                let n = entry["n"] ?? entry["number"] ?? entry["id"] ?? entry["line"]
                if let n = n as? NSNumber { number = n.intValue } else if let n = n as? String { number = Int(n.trimmingCharacters(in: .whitespaces)) }
                // An entry without a usable number can only be placed by position.
                if number == nil && n == nil { number = position + 1 }
            } else if let string = item as? String {
                number = position + 1
                body = string
            }
            guard let number, let body, (1...max(expectedLines, 1)).contains(number), reply.lines[number] == nil else { continue }
            reply.lines[number] = body
        }
        return reply
    }

    /// Pulls complete `{"n": 3, "text": "..."}` entries out of JSON that does not parse as a whole
    /// (cut off by max_tokens, or wrapped in stray text).
    private static func salvage(_ text: String, expectedLines: Int) -> ModelReply {
        var reply = ModelReply()
        let pattern = #"\{\s*"n"\s*:\s*"?(\d+)"?\s*,\s*"text"\s*:\s*("(?:[^"\\]|\\.)*")"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return reply }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let number = Int(ns.substring(with: match.range(at: 1))),
                  (1...max(expectedLines, 1)).contains(number), reply.lines[number] == nil,
                  let body = try? JSONSerialization.jsonObject(with: Data(ns.substring(with: match.range(at: 2)).utf8),
                                                               options: [.fragmentsAllowed]) as? String
            else { continue }
            reply.lines[number] = body
        }
        return reply
    }

    /// "1. text" / "2) text" / "3: text" — what a model writes when it ignores the JSON instruction.
    private static func numberedLines(_ text: String, expectedLines: Int) -> [Int: String] {
        var result: [Int: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: #"^\s*\[?(\d{1,3})\]?\s*[.):\-]\s*(.+?)\s*$"#) else { return result }
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let number = Int(ns.substring(with: match.range(at: 1))),
                  (1...max(expectedLines, 1)).contains(number), result[number] == nil
            else { continue }
            result[number] = ns.substring(with: match.range(at: 2))
        }
        return result
    }
}
