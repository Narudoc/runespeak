import Foundation
import RunespeakCore

/// `--translate-check <file> [--data <dictionary folder>] [--batch N] [--flavor classic|retail]
/// [--model <id>] [--context <file>]
/// [--ledger <file> [--max-requests N] [--max-usd X] [--agent <name>] [--run <label>]]`:
/// translates the chat lines of a text file the way the app translates incoming chat — the
/// stored settings (provider, model, reader language), the stored key of that provider, the
/// real prompt and the glossary hints — and prints "source => translation" for each, then the
/// token usage and its cost. For judging prompt and dictionary changes against a real model.
///
/// One message per line (`ChatLineFile`): either the body alone (taken as a public-channel
/// message) or `channel<TAB>sender<TAB>body`, with the channel spelled like `ChatChannel`
/// (guild, party, yell, whisper, publicChannel, ...). The channel may carry its label as the
/// game shows it, in square brackets: `publicChannel[1. General - Tanaris]<TAB>sender<TAB>body`
/// is a line of that zone's general channel, which is what brings the zone's places in as
/// hints; a public-channel line without a label is taken as said in "1. 공개 - 스톰윈드".
/// Empty lines and lines starting with "#" are skipped.
/// Before each request the hints that go with it are printed ("힌트: ..."): how many names,
/// abbreviations, loose names and corrections, and every place with its zone and the words of
/// the line it was found by (`"IB site" → ...`), so that a translation can be traced back to
/// what the model was given. A place goes to the model with the line that found it; the
/// number of that line within the request is printed with it.
/// Lines that carry places are sent apart from the others, as the app sends them
/// (`LLMTranslator.incomingRequests`): `--batch` lines can therefore be two requests, each is
/// printed and counted as one, and the plan checked against the ledger counts them so.
/// `--data` reads the dictionary files from that folder (the repository's data/) instead of
/// the installed ones. `--batch` is the number of lines per request (default: the queue's
/// largest batch); 1 sends every line alone. `--model` uses that model id of the configured
/// provider instead of the configured model. `--context` names a file of earlier chat in the
/// same format: its lines go with every request as the chat that came before (the app sends
/// the last few lines it showed), which is where a model picks up words a line does not say.
///
/// Makes real, billed requests. `--ledger` keeps them inside a budget shared by everyone who
/// uses the same file (see `LiveLedger`): the run does not start when the ledger's totals plus
/// what this run is expected to use would pass `--max-requests` or `--max-usd`, stops before
/// a request once a limit is reached, and appends "run, agent, requests, usd" after every
/// request (so that a run stopped half-way has still been counted).
/// A limit without a ledger, or a cost limit for a model without a known price, is refused.
///
/// Never prints the key; writes nothing to the user's folder (usage is counted in memory, the
/// dictionary is read from a temporary copy, and reading the key leaves an owner-only key file
/// as it is).
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

    private static let usage = "사용법: --translate-check <채팅 줄 파일> [--data <사전 폴더>] [--batch N] [--flavor classic|retail] [--model <모델 id>] [--context <앞 대화 파일>]"
        + " [--ledger <장부 파일> [--max-requests N] [--max-usd X] [--agent <이름>] [--run <이름>]]"

    static func run() async -> Int32 {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        guard let file = value("--translate-check"), !file.hasPrefix("--") else {
            print(usage)
            return 2
        }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            print("파일을 읽을 수 없습니다: \(file)")
            return 2
        }
        let messages = text.split(whereSeparator: \.isNewline).compactMap { ChatLineFile.message(from: String($0)) }
        guard !messages.isEmpty else {
            print("번역할 줄이 없습니다")
            return 2
        }

        var recent: [ChatMessage] = []
        if let contextFile = value("--context") {
            guard let earlier = try? String(contentsOfFile: contextFile, encoding: .utf8) else {
                print("파일을 읽을 수 없습니다: \(contextFile)")
                return 2
            }
            recent = earlier.split(whereSeparator: \.isNewline).compactMap { ChatLineFile.message(from: String($0)) }
        }

        // A flag whose value is missing or not a number must not quietly run without its limit.
        var limits = LiveLedger.Limits()
        if arguments.contains("--max-requests") {
            guard let n = value("--max-requests").flatMap(Int.init), n >= 0 else {
                print("--max-requests에는 0 이상의 정수가 필요합니다\n\(usage)")
                return 2
            }
            limits.maxRequests = n
        }
        if arguments.contains("--max-usd") {
            guard let x = value("--max-usd").flatMap(Double.init), x >= 0, x.isFinite else {
                print("--max-usd에는 0 이상의 금액이 필요합니다\n\(usage)")
                return 2
            }
            limits.maxUSD = x
        }
        for flag in ["--ledger", "--agent", "--run", "--model", "--context", "--data", "--batch", "--flavor"] where arguments.contains(flag) {
            guard let given = value(flag), !given.hasPrefix("--"), !given.trimmingCharacters(in: .whitespaces).isEmpty else {
                print("\(flag)에 값이 없습니다\n\(usage)")
                return 2
            }
        }
        let ledgerPath = value("--ledger")
        if ledgerPath == nil, limits != LiveLedger.Limits() || arguments.contains("--agent") || arguments.contains("--run") {
            print("--max-requests, --max-usd, --agent, --run은 --ledger와 함께 써야 합니다\n\(usage)")
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
        let model = value("--model")?.trimmingCharacters(in: .whitespaces) ?? settings.modelID()
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

        // The requests this run makes: what the app itself would leave in the original is not
        // sent here either, a request with nothing to send is not made, and the lines of a
        // batch that carry places of their zone are a request of their own.
        var chunks: [(all: [ChatMessage], wanted: [ChatMessage], requests: [[ChatMessage]])] = []
        var start = 0
        while start < messages.count {
            let chunk = Array(messages[start..<min(start + batch, messages.count)])
            start += chunk.count
            let wanted = chunk.filter { LanguageGate.needsTranslation($0, reader: settings.readerLanguage) }
            chunks.append((chunk, wanted, LLMTranslator.incomingRequests(for: wanted, glossary: glossary)))
        }
        let planned = chunks.reduce(0) { $0 + $1.requests.count }
        let plannedLines = chunks.reduce(0) { $0 + $1.wanted.count }

        // The ledger is read, and locked, before anything is sent.
        var ledger: LiveLedger?
        var spentBefore = LiveLedger.Totals()
        defer { ledger?.close() }
        if let ledgerPath {
            let price = ModelCatalog.price(provider: provider, modelID: model)
            if limits.maxUSD != nil, price == nil {
                print("모델 \(model)의 단가를 몰라 비용 한도를 지킬 수 없습니다. 실행하지 않습니다")
                return 3
            }
            do {
                let opened = try LiveLedger(file: URL(fileURLWithPath: ledgerPath)) {
                    print("다른 실행이 장부를 쓰고 있어 끝나기를 기다립니다…")
                }
                ledger = opened
                spentBefore = try opened.totals()
            } catch LiveLedger.Failure.unreadableLine(let number) {
                print("장부 \(number)번째 줄을 읽을 수 없어 지금까지 쓴 양을 알 수 없습니다. 실행하지 않습니다: \(ledgerPath)")
                return 3
            } catch {
                print("장부를 열 수 없습니다. 실행하지 않습니다: \(ledgerPath) (\(error))")
                return 3
            }
            let expected = LiveLedger.Totals(
                requests: planned,
                usd: price.map { LiveLedger.estimate(requests: planned, lines: plannedLines,
                                                     systemPromptBytes: LLMTranslator.systemPromptByteCount, price: $0) } ?? 0)
            print(String(format: "장부: 지금까지 %d건 · $%.6f  |  이번 실행 예상 %d건 · 약 $%.6f  |  한도 %@건 · %@",
                         spentBefore.requests, spentBefore.usd, expected.requests, expected.usd,
                         limits.maxRequests.map(String.init) ?? "없음",
                         limits.maxUSD.map { String(format: "$%.4f", $0) } ?? "없음"))
            if let reason = LiveLedger.refusal(spent: spentBefore, planned: expected, limits: limits) {
                print("실행하지 않습니다 — \(reason)")
                return 3
            }
        }

        let meter = Meter()
        let translator = TranslatorFactory.make(provider: provider, apiKey: key, glossary: glossary, usage: meter)
        let context = TranslationRequestContext(reader: settings.readerLanguage, flavor: flavor, model: model, recent: recent)

        print("모델: \(translator.engineName(for: context)) (\(model)) · \(flavor.rawValue) · 읽는 언어: \(settings.readerLanguage == .korean ? "한국어" : "영어")")
        print("시스템 프롬프트: \(LLMTranslator.systemPromptByteCount)바이트 (장소가 딸린 요청에는 장소 안내 \(LLMTranslator.zonePlacesNoteByteCount)바이트가 뒤에 붙음)")
        print("사전: \(folder.path) (파일 \(seeded.changed.count)개, 이름 \(glossary.entryCount)개, 줄임말 \(glossary.abbreviationCount)개, 장소가 있는 지역 \(glossary.placeZoneCount)개)")
        print("요청당 \(batch)줄" + (recent.isEmpty ? "" : " · 앞 대화 \(recent.count)줄") + "\n")

        var failed = false
        var stopped: String?
        // Requests sent, answered or not: the budget counts every one of them. (The meter only
        // hears of answers that carry a token count.)
        var sent = 0
        // Each request is written into the ledger as soon as it is over: a run that is stopped
        // half-way (a time limit, Ctrl-C) has still spent what it sent.
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd'T'HHmmss"
        let runName = stamp.string(from: Date()) + "/" + (value("--run") ?? URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent)
        var recorded = 0.0
        var unrecorded: [String] = []
        for (chunk, wanted, requests) in chunks {
            var results: [UUID: TranslationOutput] = [:]
            var problems: [UUID: String] = [:]
            for lines in requests {
                var problem: String?
                defer { if let problem { lines.forEach { problems[$0.id] = problem } } }
                if stopped == nil, ledger != nil {
                    stopped = LiveLedger.reached(spent: spentBefore + LiveLedger.Totals(requests: sent, usd: meter.usd), limits: limits)
                }
                if let stopped {
                    problem = "보내지 않음 — \(stopped)"
                } else if LLMTranslator.incomingRequests(for: lines, glossary: glossary).count != 1 {
                    // Never more requests than were counted.
                    problem = "보내지 않음 — 이 줄들이 요청 하나로 나가지 않습니다"
                } else {
                    sent += 1
                    // What the translator is about to look up for these lines (the same calls).
                    let hints = LLMTranslator.incomingHints(for: lines, glossary: glossary)
                    print(hintSummary(hints, places: LLMTranslator.incomingPlaces(for: lines, among: hints, glossary: glossary), request: sent,
                                      lines: lines.map { line in (wanted.firstIndex { $0.id == line.id } ?? 0) + 1 }))
                    do {
                        results.merge(try await translator.translateIncoming(lines, context: context)) { first, _ in first }
                    } catch let error as TranslationError {
                        problem = error.userMessage(for: provider)
                    } catch {
                        problem = error.localizedDescription
                    }
                    if let ledger {
                        let used = LiveLedger.Totals(requests: 1, usd: max(0, meter.usd - recorded))
                        recorded = meter.usd
                        let name = planned > 1 ? "\(runName)#\(sent)" : runName
                        do {
                            try ledger.append(run: name, agent: value("--agent") ?? "-", used: used)
                        } catch {
                            unrecorded.append(LiveLedger.line(run: name, agent: value("--agent") ?? "-", used: used))
                        }
                    }
                }
            }
            for message in chunk {
                let head = "[\(message.channel.rawValue)\(message.channelLabel.map { " " + $0 } ?? "")] "
                    + (message.sender.map { "\($0): " } ?? "") + message.body
                if !wanted.contains(where: { $0.id == message.id }) {
                    print("\(head)\n    == (번역 대상 아님: 원문 그대로 표시)")
                } else if let output = results[message.id] {
                    // What the app does with an answer that says the line over again.
                    if TranslationEcho.isEcho(output.text, of: message, reader: settings.readerLanguage) {
                        print("\(head)\n    =? \(output.text)   (원문과 같은 답: 번역으로 치지 않음)")
                    } else {
                        print("\(head)\n    => \(output.text)")
                    }
                } else {
                    failed = true
                    print("\(head)\n    !! \(problems[message.id] ?? "응답에 이 줄이 없습니다")")
                }
            }
        }

        print(String(format: "\n요청 %d건 · 입력 %d · 캐시 읽기 %d · 캐시 쓰기 %d · 출력 %d 토큰 · 비용 $%.6f (약 %.1f원)%@",
                     meter.requests, meter.input, meter.cacheRead, meter.cacheWrite, meter.output, meter.usd,
                     meter.usd * ModelCatalog.krwPerUSD, meter.unpriced > 0 ? " · 일부 모델 단가 미상" : ""))
        if ledger != nil {
            let used = LiveLedger.Totals(requests: sent, usd: meter.usd)
            if sent > meter.requests {
                print("!! 요청 \(sent - meter.requests)건은 사용량 없이 끝나(오류·시간 초과) 비용을 알 수 없습니다. 장부에는 요청 수만 더합니다")
            }
            let total = spentBefore + used
            print(String(format: "장부: 이번 실행 %d건 · $%.6f  →  합계 %d건 · $%.6f", used.requests, used.usd, total.requests, total.usd))
            if !unrecorded.isEmpty {
                // The requests were made: say so loudly rather than lose them from the budget.
                print("!! 장부에 적지 못한 줄이 있습니다. 직접 적어 주세요:\n" + unrecorded.joined(separator: "\n"))
                return 1
            }
        }
        return failed ? 1 : 0
    }

    /// The hints of one request, for the reader of the output: counts of the long lists, and
    /// the places in full (they are few, and the reason a place name appears in a translation),
    /// each with the number of the line of the request that carries it.
    /// `lines`: where the lines of the request stand among the lines of their batch (1-based),
    /// when the batch went out as more than one request.
    static func hintSummary(_ hints: GlossaryHints, places: [GlossaryZonePlaces?], request: Int, lines: [Int] = []) -> String {
        let placeCount = places.reduce(0) { $0 + ($1?.places.count ?? 0) }
        var out = "— 요청 \(request) 힌트: 이름 \(hints.names.count) · 줄임말 \(hints.abbreviations.count)"
            + " · 느슨한 이름 \(hints.looseNames.count) · 교정 \(hints.corrections.count)"
            + " · 장소 \(placeCount)" + (placeCount > 0 ? " (장소 안내 붙음)" : "")
        if !lines.isEmpty { out += "\n    묶음의 \(lines.map(String.init).joined(separator: ", "))번째 줄 (\(lines.count)줄)" }
        for (index, entry) in places.enumerated() {
            guard let entry else { continue }
            for place in entry.places {
                out += "\n    장소 \(index + 1)번 줄 [\(entry.zone.korean) / \(entry.zone.english)] \"\(place.written)\" → \(place.korean) ↔ \(place.english)"
            }
        }
        return out
    }
}
