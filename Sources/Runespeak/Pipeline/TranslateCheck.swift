import Foundation
import RunespeakCore

/// `--translate-check <file> [--data <dictionary folder>] [--batch N] [--flavor classic|retail]`:
/// translates the chat lines of a text file the way the app translates incoming chat — the
/// stored settings (provider, model, reader language), the stored key of that provider, the
/// real prompt and the glossary hints — and prints "source => translation" for each, then the
/// token usage and its cost. For judging prompt and dictionary changes against a real model.
///
/// One message per line: either the body alone (taken as a public-channel message) or
/// `channel<TAB>sender<TAB>body`, with the channel spelled like `ChatChannel` (guild, party,
/// yell, whisper, publicChannel, ...). Empty lines and lines starting with "#" are skipped.
/// `--data` reads the dictionary files from that folder (the repository's data/) instead of
/// the installed ones. `--batch` is the number of lines per request (default: the queue's
/// largest batch); 1 sends every line alone.
///
/// Makes real, billed requests. Never prints the key; writes nothing to the user's folder
/// (usage is counted in memory, the dictionary is read from a temporary copy).
enum TranslateCheck {
    /// Counts tokens in memory instead of token_usage.json.
    private final class Meter: UsageTracking, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests = 0
        private(set) var input = 0
        private(set) var output = 0
        private(set) var cacheRead = 0
        private(set) var cacheWrite = 0
        private(set) var usd = 0.0
        private(set) var unpriced = 0

        func record(provider: AIProvider, modelID: String, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) {
            lock.lock()
            defer { lock.unlock() }
            requests += 1
            input += inputTokens
            output += outputTokens
            cacheRead += cacheReadTokens
            cacheWrite += cacheWriteTokens
            if let cost = ModelCatalog.usd(provider: provider, modelID: modelID, inputTokens: inputTokens, outputTokens: outputTokens,
                                           cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens) {
                usd += cost
            } else {
                unpriced += 1
            }
        }

        var todayKRW: Double { usd * ModelCatalog.krwPerUSD }
        var totalKRW: Double { usd * ModelCatalog.krwPerUSD }
    }

    static func run() async -> Int32 {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        guard let file = value("--translate-check"), !file.hasPrefix("--") else {
            print("사용법: --translate-check <채팅 줄 파일> [--data <사전 폴더>] [--batch N] [--flavor classic|retail]")
            return 2
        }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            print("파일을 읽을 수 없습니다: \(file)")
            return 2
        }
        let messages = text.split(whereSeparator: \.isNewline).compactMap { message(from: String($0)) }
        guard !messages.isEmpty else {
            print("번역할 줄이 없습니다")
            return 2
        }

        let home = AppPaths.default
        let store = SettingsStore(paths: home)
        let settings = store.loadSettings()
        let provider = settings.provider
        guard let key = store.loadAPIKey(for: provider) else {
            print("\(provider.shortName) API 키가 저장되어 있지 않습니다")
            return 2
        }
        let flavor = value("--flavor").flatMap(GameFlavor.init(rawValue:)) ?? settings.flavor
        let largest = await MainActor.run { TranslationQueue.maxBatch }
        let batch = max(1, min(largest, value("--batch").flatMap(Int.init) ?? largest))

        // The dictionary is loaded from a temporary copy, so that neither the installed files
        // nor the user's own lists can be changed from here.
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("runespeak-translate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let paths = AppPaths(root: base)
        let folder = value("--data").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.dataDirectory
        let seeded = DictionaryFiles.seed(from: folder, to: paths)
        for (from, to) in [(home.correctionsFile, paths.correctionsFile), (home.myTermsFile, paths.myTermsFile)] {
            try? fm.copyItem(at: from, to: to)
        }
        let glossary = GlossaryStore(paths: paths, flavor: flavor)
        let meter = Meter()
        let translator = TranslatorFactory.make(provider: provider, apiKey: key, glossary: glossary, usage: meter)
        let context = TranslationRequestContext(reader: settings.readerLanguage, flavor: flavor, model: settings.modelID())

        print("모델: \(translator.engineName(for: context)) (\(settings.modelID())) · \(flavor.rawValue) · 읽는 언어: \(settings.readerLanguage == .korean ? "한국어" : "영어")")
        print("사전: \(folder.path) (파일 \(seeded.changed.count)개, 이름 \(glossary.entryCount)개, 줄임말 \(glossary.abbreviationCount)개)")
        print("요청당 \(batch)줄\n")

        var failed = false
        var start = 0
        while start < messages.count {
            let chunk = Array(messages[start..<min(start + batch, messages.count)])
            start += chunk.count
            // What the app itself would leave in the original is not sent here either.
            let wanted = chunk.filter { LanguageGate.needsTranslation($0.body, reader: settings.readerLanguage) }
            var results: [UUID: TranslationOutput] = [:]
            var problem: String?
            if !wanted.isEmpty {
                do {
                    results = try await translator.translateIncoming(wanted, context: context)
                } catch let error as TranslationError {
                    problem = error.userMessage(for: provider)
                } catch {
                    problem = error.localizedDescription
                }
            }
            for message in chunk {
                let head = "[\(message.channel.rawValue)] " + (message.sender.map { "\($0): " } ?? "") + message.body
                if !wanted.contains(where: { $0.id == message.id }) {
                    print("\(head)\n    == (번역 대상 아님: 원문 그대로 표시)")
                } else if let output = results[message.id] {
                    print("\(head)\n    => \(output.text)")
                } else {
                    failed = true
                    print("\(head)\n    !! \(problem ?? "응답에 이 줄이 없습니다")")
                }
            }
        }

        print(String(format: "\n요청 %d건 · 입력 %d · 캐시 읽기 %d · 캐시 쓰기 %d · 출력 %d 토큰 · 비용 $%.6f (약 %.1f원)%@",
                     meter.requests, meter.input, meter.cacheRead, meter.cacheWrite, meter.output, meter.usd,
                     meter.usd * ModelCatalog.krwPerUSD, meter.unpriced > 0 ? " · 일부 모델 단가 미상" : ""))
        return failed ? 1 : 0
    }

    private static func message(from line: String) -> ChatMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
        var channel = ChatChannel.publicChannel
        var sender: String?
        var body = trimmed
        let fields = line.components(separatedBy: "\t")
        if fields.count >= 3, let named = ChatChannel(rawValue: fields[0].trimmingCharacters(in: .whitespaces)) {
            channel = named
            let name = fields[1].trimmingCharacters(in: .whitespaces)
            sender = name.isEmpty ? nil : name
            body = fields[2...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        if body.isEmpty { return nil }
        let label: String? = channel == .publicChannel ? "1. 공개 - 스톰윈드" : nil
        return ChatMessage(channel: channel, channelLabel: label, sender: sender, body: body, rawText: body,
                           color: .white, firstSeen: Date())
    }
}
