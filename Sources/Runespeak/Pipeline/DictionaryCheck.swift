import Foundation
import RunespeakCore

/// `--dictionary-check <data folder> [file of chat lines]`: loads the dictionary files of a
/// folder (the repository's data/, or Contents/Resources/data of a built app) the way the app
/// does, prints entry counts and timings for both flavors, and, given a file of chat lines,
/// the hints each line would send to the translation model. Headless; touches nothing but a
/// temporary folder.
enum DictionaryCheck {
    static func run() -> Int32 {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--dictionary-check"), flag + 1 < arguments.count else {
            print("사용법: --dictionary-check <사전 폴더> [채팅 줄 파일]")
            return 2
        }
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        let lines: [String] = flag + 2 < arguments.count
            ? ((try? String(contentsOfFile: arguments[flag + 2], encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline).map(String.init)
            : []

        let base = fm.temporaryDirectory.appendingPathComponent("runespeak-dictionary-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let paths = AppPaths(root: base)
        let seeded = DictionaryFiles.seed(from: folder, to: paths)
        let missing = DictionaryFiles.all.filter { !seeded.changed.contains($0) }
        print("사전 폴더: \(folder.path)")
        print("복사한 파일 \(seeded.changed.count)개" + (missing.isEmpty ? "" : " — 없는 파일: \(missing.joined(separator: ", "))"))
        var failed = !missing.isEmpty || !seeded.failures.isEmpty

        // Lines that exercise every kind of entry, for the timing when no file is given.
        let probe = [
            "LFM UBRS need tank and healer, have key",
            "WTS [Arcanite Bar] 45g, [Black Lotus] 120g pst",
            "anyone up for Stratholme or Scholomance tonight? 60 holy paladin",
            "가시덤불 골짜기에서 전사 한 분 구합니다 화산 심장부도 갑니다",
            "thanks for the help everyone, see you tomorrow",
            "LF1M tank for +12, have key, 3200 io min, link AotC",
        ]

        for flavor in [GameFlavor.classic, .retail] {
            let started = Date()
            let store = GlossaryStore(paths: paths, flavor: flavor)
            let load = Date().timeIntervalSince(started)
            print("\n[\(flavor == .retail ? "retail" : "classic")] 이름 \(store.entryCount)개 · 줄임말 \(store.abbreviationCount)개 · 읽는 데 \(String(format: "%.2f", load))초")
            if store.entryCount == 0 || store.abbreviationCount == 0 { failed = true }
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
            for _ in 0..<rounds {
                for line in sample {
                    let t = Date()
                    _ = store.hints(for: [line])
                    slowest = max(slowest, Date().timeIntervalSince(t))
                }
            }
            let average = Date().timeIntervalSince(all) / Double(rounds * sample.count)
            print(String(format: "hints(): 줄당 평균 %.3f ms · 가장 느린 줄 %.3f ms (%d줄 × %d회)",
                         average * 1000, slowest * 1000, sample.count, rounds))

            for line in lines {
                let hints = store.hints(for: [line])
                print("\n> \(line)")
                for pair in hints.names { print("    이름  \(pair.korean) ↔ \(pair.english)") }
                for pair in hints.looseNames { print("    느슨  \(pair.korean) ↔ \(pair.english)") }
                for sense in hints.abbreviations {
                    print("    줄임  \(sense.abbr): \(sense.english) / \(sense.korean) — \(sense.note)")
                }
            }
        }
        return failed ? 1 : 0
    }
}
