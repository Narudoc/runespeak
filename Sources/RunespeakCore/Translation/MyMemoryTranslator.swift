import Foundation
import NaturalLanguage

/// Free fallback used when there is no Claude API key: the public MyMemory API
/// (`GET https://api.mymemory.translated.net/get?q=…&langpair=src|dst`). No glossary, no game
/// knowledge, and an anonymous quota of about 5,000 characters a day.
public final class MyMemoryTranslator: Translating, @unchecked Sendable {

    struct Tuning: Sendable {
        var timeout: TimeInterval = 10
        var maxConcurrent = 3
        var maxRetries = 1
        var maxRetryDelay: TimeInterval = 2
        /// After a quota answer, how long to refuse locally before asking the server again.
        var quotaBackoffDefault: TimeInterval = 600
        var quotaBackoffMax: TimeInterval = 1800
        var now: @Sendable () -> Date = { Date() }
        var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    }

    static let endpoint = "https://api.mymemory.translated.net/get"
    /// The API rejects a `q` longer than 500 bytes of UTF-8.
    static let maxQueryBytes = 500

    private let session: URLSession
    private let tuning: Tuning
    private let lock = NSLock()
    private var quotaExhaustedUntil: Date?

    public convenience init(session: URLSession = .shared) {
        self.init(session: session, tuning: Tuning())
    }

    init(session: URLSession, tuning: Tuning) {
        self.session = session
        self.tuning = tuning
    }

    // MARK: - Translating

    public func engineName(for context: TranslationRequestContext) -> String { "MyMemory" }

    public func translateIncoming(_ messages: [ChatMessage], context: TranslationRequestContext) async throws -> [UUID: TranslationOutput] {
        if messages.isEmpty { return [:] }
        try checkQuota()
        let target = context.reader == .korean ? "ko" : "en"

        var results: [UUID: TranslationOutput] = [:]
        var firstError: TranslationError?
        var quotaHit = false

        await withTaskGroup(of: (UUID, Result<String, TranslationError>?).self) { group in
            var pending = messages.makeIterator()
            var running = 0
            func addNext() {
                guard !quotaHit, let message = pending.next() else { return }
                running += 1
                group.addTask { [self] in
                    do {
                        let source = Self.detectLanguage(message.body, excluding: target, fallback: "en")
                        return (message.id, .success(try await translate(message.body, from: source, to: target)))
                    } catch let error as TranslationError {
                        return (message.id, .failure(error))
                    } catch {
                        return (message.id, nil)   // cancelled
                    }
                }
            }
            for _ in 0..<max(1, tuning.maxConcurrent) { addNext() }
            while running > 0, let (id, outcome) = await group.next() {
                running -= 1
                switch outcome {
                case .success(let text)?:
                    let line = LLMTranslator.singleLine(text)
                    if !line.isEmpty { results[id] = TranslationOutput(text: line) }
                case .failure(let error)?:
                    if error == .dailyLimitReached { quotaHit = true }
                    if firstError == nil || error == .dailyLimitReached { firstError = error }
                case nil:
                    break
                }
                addNext()
            }
        }
        try Task.checkCancellation()
        // The contract: throw only when nothing at all came back.
        if results.isEmpty, let firstError { throw firstError }
        return results
    }

    public func retranslate(_ message: ChatMessage, previous: String?, context: TranslationRequestContext) async throws -> TranslationOutput {
        // "다시 번역" needs a model that can reason about the line.
        throw TranslationError.missingAPIKey
    }

    public func translateOutgoing(_ text: String, to language: String, context: TranslationRequestContext) async throws -> String {
        let source = LLMTranslator.singleLine(text)
        if source.isEmpty { return "" }
        try checkQuota()
        guard let target = Self.languageCode(forEnglishName: language) else {
            throw TranslationError.badResponse("무료 번역이 지원하지 않는 언어입니다: \(language)")
        }
        let from = Self.detectLanguage(source, excluding: target, fallback: context.reader == .korean ? "ko" : "en")
        let translated = try await translate(source, from: from, to: target)
        let line = LLMTranslator.pasteable(translated)
        if line.isEmpty { throw TranslationError.badResponse("번역 결과가 비어 있습니다") }
        return line
    }

    // MARK: - One text

    private func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || Self.primary(source) == Self.primary(target) { return trimmed }
        var parts: [String] = []
        for chunk in Self.chunks(trimmed, maxBytes: Self.maxQueryBytes) {
            parts.append(try await request(chunk, from: source, to: target))
        }
        return parts.joined(separator: " ")
    }

    private func request(_ text: String, from source: String, to target: String) async throws -> String {
        try checkQuota()
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "\(source)|\(target)"),
        ]
        // URLComponents leaves "+" alone, and servers read a bare "+" in a query as a space ("55+").
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = tuning.timeout
        request.setValue("application/json", forHTTPHeaderField: "accept")

        // A 429 here is the daily quota, not a burst limit: retrying cannot help.
        let (data, response) = try await HTTPSupport.send(request, session: session, maxRetries: tuning.maxRetries,
                                                         maxRetryDelay: tuning.maxRetryDelay, retryRateLimit: false,
                                                         sleep: tuning.sleep)
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let translated = (root?["responseData"] as? [String: Any])?["translatedText"] as? String
        let details = root?["responseDetails"] as? String ?? ""
        // responseStatus is a number on success and has been seen as a string on errors.
        let status = (root?["responseStatus"] as? NSNumber)?.intValue
            ?? (root?["responseStatus"] as? String).flatMap { Int($0) }
            ?? response.statusCode

        let quotaFinished = (root?["quotaFinished"] as? Bool) == true
        let warning = (translated ?? "").uppercased().contains("MYMEMORY WARNING") || details.uppercased().contains("MYMEMORY WARNING")
        if response.statusCode == 429 || status == 429 || quotaFinished || warning {
            markQuotaExhausted(retryAfter: response.statusCode == 429 ? HTTPSupport.retryAfter(response) : nil)
            throw TranslationError.dailyLimitReached
        }
        guard response.statusCode == 200, status == 200 else {
            let reason = details.isEmpty ? (translated ?? "") : details
            throw TranslationError.badResponse("MyMemory 오류 (\(status))" + (reason.isEmpty ? "" : ": " + String(reason.prefix(80))))
        }
        guard let translated, !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.badResponse("MyMemory 번역 결과가 비어 있습니다")
        }
        return Self.decodeEntities(translated)
    }

    // MARK: - Quota memory

    private func checkQuota() throws {
        lock.lock()
        defer { lock.unlock() }
        if let until = quotaExhaustedUntil {
            if tuning.now() < until { throw TranslationError.dailyLimitReached }
            quotaExhaustedUntil = nil
        }
    }

    private func markQuotaExhausted(retryAfter: TimeInterval?) {
        let wait = min(max(retryAfter ?? tuning.quotaBackoffDefault, 1), tuning.quotaBackoffMax)
        lock.lock()
        quotaExhaustedUntil = tuning.now().addingTimeInterval(wait)
        lock.unlock()
    }

    // MARK: - Language detection

    /// Rough source-language guess for MyMemory, which cannot auto-detect.
    /// Script decides for Korean / Japanese / Chinese / Russian; Latin text is English unless the
    /// system recogniser is confident about another European language. Letters in the script of
    /// `excluding` (the language being translated INTO) are ignored when anything else is present,
    /// so "ㅋㅋ lf tank" read by a Korean is still English.
    static func detectLanguage(_ text: String, excluding target: String, fallback: String) -> String {
        var hangul = 0, kana = 0, han = 0, cyrillic = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D: kana += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: han += 1
            case 0x0400...0x052F: cyrillic += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1
            default: break
            }
        }
        var counts: [(code: String, count: Int)] = [
            // Japanese text is mostly kanji with some kana; any kana makes the Han characters Japanese.
            ("ja", kana > 0 ? kana + han : 0),
            ("zh-CN", kana > 0 ? 0 : han),
            ("ko", hangul),
            ("ru", cyrillic),
            ("latin", latin),
        ]
        let targetPrimary = primary(target)
        let withoutTarget = counts.filter { entry in
            if entry.code == "latin" { return !latinLanguages.contains(targetPrimary) }
            return primary(entry.code) != targetPrimary
        }
        if withoutTarget.contains(where: { $0.count > 0 }) { counts = withoutTarget }
        guard let best = counts.max(by: { $0.count < $1.count }), best.count > 0 else { return fallback }
        if best.code != "latin" { return best.code }
        return latinLanguage(text)
    }

    private static let latinLanguages: Set<String> = ["en", "es", "pt", "de", "fr", "it", "nl", "pl", "tr", "sv", "da", "nb", "fi", "cs", "hu", "ro"]

    private static func latinLanguage(_ text: String) -> String {
        // Chat is short and full of abbreviations, which the recogniser happily calls Dutch or
        // Danish; only trust it on a real sentence and a clear verdict.
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 16 else { return "en" }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish, .portuguese, .german, .french, .italian, .polish, .turkish, .dutch, .swedish]
        recognizer.languageHints = [.english: 0.6, .spanish: 0.1, .portuguese: 0.1, .german: 0.1, .french: 0.1]
        recognizer.processString(text)
        if let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.85 {
            return language.rawValue
        }
        return "en"
    }

    static func primary(_ code: String) -> String {
        String(code.lowercased().split(separator: "-").first ?? "")
    }

    /// "English" → "en". Accepts the names offered in the settings UI, a few aliases, any language
    /// name the system knows, and codes passed through as they are.
    static func languageCode(forEnglishName name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return nil }
        let known: [String: String] = [
            "english": "en", "korean": "ko", "japanese": "ja", "russian": "ru",
            "chinese": "zh-CN", "chinese (simplified)": "zh-CN", "simplified chinese": "zh-CN", "mandarin": "zh-CN",
            "chinese (traditional)": "zh-TW", "traditional chinese": "zh-TW",
            "spanish": "es", "portuguese": "pt", "brazilian portuguese": "pt-BR", "portuguese (brazil)": "pt-BR",
            "german": "de", "french": "fr", "italian": "it", "polish": "pl", "turkish": "tr", "dutch": "nl",
            "swedish": "sv", "danish": "da", "norwegian": "nb", "finnish": "fi", "czech": "cs", "hungarian": "hu",
            "romanian": "ro", "ukrainian": "uk", "thai": "th", "vietnamese": "vi", "indonesian": "id", "arabic": "ar",
            "greek": "el", "hebrew": "he",
        ]
        if let code = known[key] { return code }
        let english = Locale(identifier: "en_US")
        for code in Locale.LanguageCode.isoLanguageCodes where code.identifier.count == 2 {
            if english.localizedString(forLanguageCode: code.identifier)?.lowercased() == key { return code.identifier }
        }
        // Already a code ("es", "pt-BR").
        let looksLikeCode = key.range(of: #"^[a-z]{2,3}(-[a-z]{2,4})?$"#, options: .regularExpression) != nil
        if looksLikeCode, english.localizedString(forLanguageCode: primary(key)) != nil {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - Text helpers

    /// Splits at sentence ends or spaces so every piece fits the API's byte limit.
    static func chunks(_ text: String, maxBytes: Int) -> [String] {
        if text.utf8.count <= maxBytes { return [text] }
        var result: [String] = []
        var rest = Substring(text)
        while rest.utf8.count > maxBytes {
            var end = rest.startIndex
            var bytes = 0
            for index in rest.indices {
                let size = String(rest[index]).utf8.count
                if bytes + size > maxBytes { break }
                bytes += size
                end = rest.index(after: index)
            }
            let window = rest[..<end]
            var cut = end
            let half = window.index(window.startIndex, offsetBy: window.count / 2)
            if let stop = window.lastIndex(where: { ".!?。！？".contains($0) }), stop >= half {
                cut = window.index(after: stop)
            } else if let space = window.lastIndex(of: " "), space >= half {
                cut = space
            }
            let piece = rest[..<cut].trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { result.append(piece) }
            rest = rest[cut...]
            rest = rest.drop(while: { $0 == " " })
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// MyMemory returns some punctuation as HTML entities ("don&#39;t").
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, value) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]{1,6}|[0-9]{1,7});") {
            let ns = out as NSString
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let body = ns.substring(with: match.range(at: 1))
                let value = body.hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
                if let value, let scalar = Unicode.Scalar(value) {
                    out = (out as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
                }
            }
        }
        // Last, so that "&amp;lt;" becomes "&lt;" and not "<".
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
