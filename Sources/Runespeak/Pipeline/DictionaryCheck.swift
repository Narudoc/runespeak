import Foundation
import RunespeakCore

/// `--dictionary-check <data folder> [file of chat lines]`: loads the dictionary files of a
/// folder (the repository's data/, or Contents/Resources/data of a built app) the way the app
/// does, prints entry counts and timings for both flavors, and, given a file of chat lines,
/// the hints each line would send to the translation model. The file is read like the one of
/// `--translate-check` (`ChatLineFile`): a line may be the text alone, or
/// `channel[label]<TAB>sender<TAB>body`; the label of a zone's own channel
/// (`publicChannel[1. General - Tanaris]`) is what brings that zone's places in. Headless;
/// touches nothing but a temporary folder.
enum DictionaryCheck {
    static func run() -> Int32 {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--dictionary-check"), flag + 1 < arguments.count else {
            print("사용법: --dictionary-check <사전 폴더> [채팅 줄 파일]")
            return 2
        }
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        let lines: [ChatMessage] = flag + 2 < arguments.count
            ? ((try? String(contentsOfFile: arguments[flag + 2], encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline).compactMap { ChatLineFile.message(from: String($0)) }
            : []

        let base = fm.temporaryDirectory.appendingPathComponent("runespeak-dictionary-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let paths = AppPaths(root: base)
        let seeded = DictionaryFiles.seed(from: folder, to: paths)
        let missing = DictionaryFiles.all.filter { !seeded.changed.contains($0) }
        print("사전 폴더: \(folder.path)")
        print("복사한 파일 \(seeded.changed.count)개" + (missing.isEmpty ? "" : " — 없는 파일: \(missing.joined(separator: ", "))"))
        var failed = !missing.isEmpty || !seeded.failures.isEmpty

        // Lines that exercise every kind of entry, for the timing when no file is given. Each
        // is a line of a zone's general channel, so the zone lookup and the search through
        // that zone's places are timed with the rest; the last two also find a place.
        let probe = [
            "publicChannel[1. General - Tanaris]\t\tLFM UBRS need tank and healer, have key",
            "publicChannel[1. 공개 - 타나리스]\t\tWTS [Arcanite Bar] 45g, [Black Lotus] 120g pst",
            "publicChannel[1. General - Stormwind City]\t\tanyone up for Stratholme or Scholomance tonight? 60 holy paladin",
            "publicChannel[1. 공개 - 가시덤불 골짜기]\t\t가시덤불 골짜기에서 전사 한 분 구합니다 화산 심장부도 갑니다",
            "publicChannel[1. General - Elwynn Forest]\t\tthanks for the help everyone, see you tomorrow",
            "publicChannel[1. General - Tanaris]\t\tLF1M tank for +12, have key, 3200 io min, link AotC",
            "publicChannel[1. 공개 - 타나리스]\t\tLF2M for the pirates at steamwheedle, then the noxious bugs",
            "publicChannel[1. General - Tanarls]\t\tanyone at the gadget arena or rigger cove?",
        ].compactMap { ChatLineFile.message(from: $0) }

        for flavor in [GameFlavor.classic, .retail] {
            let started = Date()
            let store = GlossaryStore(paths: paths, flavor: flavor)
            let load = Date().timeIntervalSince(started)
            print("\n[\(flavor == .retail ? "retail" : "classic")] 이름 \(store.entryCount)개 · 줄임말 \(store.abbreviationCount)개"
                  + " · 장소 \(store.placeCount)곳(지역 \(store.placeZoneCount)개) · 읽는 데 \(String(format: "%.2f", load))초")
            if store.entryCount == 0 || store.abbreviationCount == 0 || store.placeZoneCount == 0 { failed = true }
            for warning in store.loadWarnings {
                print("주의: \(warning)")
                failed = true
            }

            // Chat commands as a Korean player types them.
            let commands = [("/ㅎ 안녕하세요", "/g"), ("/파티 잠시만요", "/p"), ("/귓 Thrall 안녕", "/w Thrall"),
                            ("/ㄴ 반가워요", "/s"), ("/공 모이세요", "/ra"), ("/외침 도와주세요", "/y")]
            let wrong = commands.filter { store.parseOutgoing($0.0).command != $0.1 }
            print("채팅 명령어 \(commands.count - wrong.count)/\(commands.count)개 맞음"
                  + wrong.map { " — \($0.0) → \(store.parseOutgoing($0.0).command ?? "없음")" }.joined())
            if !wrong.isEmpty { failed = true }

            let sample = lines.isEmpty ? probe : lines
            var slowest = 0.0
            let rounds = 20
            let all = Date()
            let asked = sample.map { GlossaryLine(incoming: $0) }
            for _ in 0..<rounds {
                for line in asked {
                    let t = Date()
                    _ = store.hints(forLines: [line])
                    slowest = max(slowest, Date().timeIntervalSince(t))
                }
            }
            let average = Date().timeIntervalSince(all) / Double(rounds * sample.count)
            print(String(format: "hints(): 줄당 평균 %.3f ms · 가장 느린 줄 %.3f ms (%d줄 × %d회)",
                         average * 1000, slowest * 1000, sample.count, rounds))

            for line in lines {
                let hints = LLMTranslator.incomingHints(for: [line], glossary: store)
                var where_ = line.channel.rawValue
                if line.channel == .publicChannel, let label = line.channelLabel {
                    where_ += " " + label
                    if let zone = store.zone(forChannelLabel: label) { where_ += " → \(zone.korean) / \(zone.english)" }
                }
                print("\n> [\(where_)] \(line.body)")
                for pair in hints.names { print("    이름  \(pair.korean) ↔ \(pair.english)") }
                for pair in hints.looseNames { print("    느슨  \(pair.korean) ↔ \(pair.english)") }
                for sense in hints.abbreviations {
                    print("    줄임  \(sense.abbr): \(sense.english) / \(sense.korean) — \(sense.note)")
                }
                for entry in hints.zonePlaces {
                    for place in entry.places {
                        print("    장소  [\(entry.zone.korean) / \(entry.zone.english)] \"\(place.written)\" → \(place.korean) ↔ \(place.english)")
                    }
                }
            }
        }
        return failed ? 1 : 0
    }
}
