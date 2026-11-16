import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import RunespeakCore

/// `--ocr-selftest`: renders synthetic chat screenshots, runs the OCR pipeline on them and
/// checks text accuracy and colour classification. Headless; needs no screen-recording permission.
///
///   --ocr-selftest               pass/fail run with the shipping configuration
///   --ocr-selftest --grid        compare recognition strategies (how the defaults were chosen)
///   --ocr-selftest --dump <dir>  also write the rendered images as PNG
///   --ocr-selftest --verbose     print every line that was not read perfectly
///   --ocr-selftest --image <png> [enUS]   read a real screenshot of the chat window and print it
///   --ocr-selftest --capture-check        check region maths, the selection view and, if this
///                                         process may record the screen, a real window capture
enum OCRSelfTest {

    static func run() -> Int32 {
        let args = CommandLine.arguments
        let verbose = args.contains("--verbose")
        var dumpDir: URL? = nil
        if let i = args.firstIndex(of: "--dump"), i + 1 < args.count {
            dumpDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: dumpDir!, withIntermediateDirectories: true)
        }
        if let i = args.firstIndex(of: "--image"), i + 1 < args.count {
            let locale: ClientLocale = args.contains("enUS") ? .enUS : .koKR
            return runImage(URL(fileURLWithPath: args[i + 1]), locale: locale)
        }
        if args.contains("--capture-check") { return MainActor.assumeIsolated { CaptureSelfCheck.run() } }
        if args.contains("--grid") { return runGrid(verbose: verbose) }
        return runGate(verbose: verbose, dumpDir: dumpDir)
    }

    // MARK: - Real screenshot

    private static func runImage(_ url: URL, locale: ClientLocale) -> Int32 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            print("이미지를 열 수 없습니다: \(url.path)")
            return 2
        }
        let recognizer = VisionTextRecognizer()
        _ = try? recognizer.recognizeSync(image, clientLocale: locale)   // load the models
        let start = CFAbsoluteTimeGetCurrent()
        guard let frame = try? recognizer.recognizeSync(image, clientLocale: locale) else {
            print("글자를 읽지 못했습니다.")
            return 1
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "%d x %d px · %@ 클라이언트 · %d줄 · %.0f ms", image.width, image.height,
                     locale.rawValue, frame.lines.count, ms))
        for line in frame.lines {
            print(String(format: "y=%4.0f  %.2f  %-8@ (%.2f %.2f %.2f)  %@", line.box.minY, line.confidence,
                         classify(line.color), line.color.r, line.color.g, line.color.b, line.text))
        }
        return 0
    }

    // MARK: - Gate

    /// Realistic settings: default drop shadow, chat frame dark or faded, 12–16 pt, 1x and 2x.
    private static func gateStyles(_ locale: ClientLocale) -> [SyntheticChat.Style] {
        var styles: [SyntheticChat.Style] = []
        for scale in [CGFloat(2), 1] {
            for size in [CGFloat(12), 14, 16] {
                for bg in [SyntheticChat.Background.darkPanel, .busy] {
                    styles.append(.init(fontName: SyntheticChat.fontName(for: locale), pointSize: size,
                                        scale: scale, background: bg, edge: .shadow))
                }
            }
        }
        return styles
    }

    /// Harder renderings that are reported but do not decide pass/fail.
    private static func stressStyles(_ locale: ClientLocale) -> [SyntheticChat.Style] {
        let font = SyntheticChat.fontName(for: locale)
        return [
            .init(fontName: font, pointSize: 14, scale: 2, background: .darkPanel, edge: .outline),
            .init(fontName: font, pointSize: 14, scale: 2, background: .bright, edge: .shadow),
            .init(fontName: font, pointSize: 14, scale: 2, background: .bright, edge: .outline),
            .init(fontName: font, pointSize: 14, scale: 1, background: .bright, edge: .shadow),
        ]
    }

    private static func runGate(verbose: Bool, dumpDir: URL?) -> Int32 {
        let recognizer = VisionTextRecognizer()
        var failures: [String] = []
        print("OCR 자가 진단 — 합성 채팅 이미지를 만들어 글자 인식과 색 판별을 잽니다.\n")

        for locale in ClientLocale.allCases {
            let lines = SyntheticChat.lines(for: locale)
            warmUp(recognizer, locale)
            for (title, styles, gating) in [("기본 조건", gateStyles(locale), true),
                                            ("어려운 조건 (참고용)", stressStyles(locale), false)] {
                var total = Score()
                var byScale: [Int: Score] = [:]
                for style in styles {
                    guard let rendered = SyntheticChat.render(lines: lines, style: style) else {
                        failures.append("이미지를 만들지 못했습니다: \(style.label)")
                        continue
                    }
                    if let dumpDir {
                        let name = "\(locale.rawValue)_\(style.label).png".replacingOccurrences(of: "/", with: "-")
                            .replacingOccurrences(of: " ", with: "_")
                        writePNG(rendered.image, to: dumpDir.appendingPathComponent(name))
                    }
                    let score = evaluate(rendered, recognizer: recognizer, locale: locale, verbose: verbose)
                    total.add(score)
                    byScale[Int(style.scale), default: Score()].add(score)
                }
                print("[\(locale.rawValue) 클라이언트 · \(title)]")
                print(total.report())
                for scale in byScale.keys.sorted() {
                    let s = byScale[scale]!
                    print(String(format: "  %dx 화면: 글자 %.1f%%  구조 문자 %.1f%%  색 %.1f%%",
                                 scale, s.overall * 100, s.structure * 100, s.colorAccuracy * 100))
                }
                print("")
                guard gating else { continue }
                for (language, floor) in thresholds {
                    let acc = total.accuracy(language)
                    if acc < floor {
                        failures.append(String(format: "%@ %@ 글자 정확도 %.1f%% < 기준 %.0f%%",
                                               locale.rawValue, language, acc * 100, floor * 100))
                    }
                }
                if total.structure < structureThreshold {
                    failures.append(String(format: "%@ 구조 문자([]:숫자) 정확도 %.1f%% < 기준 %.0f%%",
                                           locale.rawValue, total.structure * 100, structureThreshold * 100))
                }
                if total.colorAccuracy < colorThreshold {
                    failures.append(String(format: "%@ 색 판별 %.1f%% < 기준 %.0f%%",
                                           locale.rawValue, total.colorAccuracy * 100, colorThreshold * 100))
                }
                if total.msPerFrame > 800 {
                    failures.append(String(format: "%@ 프레임당 %.0f ms — 너무 느립니다", locale.rawValue, total.msPerFrame))
                }
            }
        }

        // What a frame costs in everyday play: a 600 x 250 pt chat window on a Retina display
        // showing Korean and English only, so no second-model passes.
        for locale in ClientLocale.allCases {
            let everyday = SyntheticChat.lines(for: locale).filter { $0.language == "en" || $0.language == "ko" }
            let lines = Array((everyday + everyday).prefix(12))
            let style = SyntheticChat.Style(fontName: SyntheticChat.fontName(for: locale), pointSize: 14, scale: 2,
                                            background: .busy, edge: .shadow)
            guard let rendered = SyntheticChat.render(lines: lines, style: style, canvasPoints: CGSize(width: 600, height: 250))
            else { continue }
            if let dumpDir { writePNG(rendered.image, to: dumpDir.appendingPathComponent("\(locale.rawValue)_everyday.png")) }
            _ = try? recognizer.recognizeSync(rendered.image, clientLocale: locale)
            var seconds = 0.0
            let rounds = 5
            for _ in 0..<rounds {
                let start = CFAbsoluteTimeGetCurrent()
                _ = try? recognizer.recognizeSync(rendered.image, clientLocale: locale)
                seconds += CFAbsoluteTimeGetCurrent() - start
            }
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<20 { _ = VisionTextRecognizer.fingerprint(rendered.image) }
            let fingerprintMs = (CFAbsoluteTimeGetCurrent() - start) / 20 * 1000
            print(String(format: "[%@ 평소 화면] %d×%d px, 한국어·영어 12줄: 프레임당 %.0f ms · fingerprint %.2f ms",
                         locale.rawValue, rendered.image.width, rendered.image.height,
                         seconds / Double(rounds) * 1000, fingerprintMs))
        }
        print("")

        if !fingerprintBehaves() { failures.append("fingerprint가 같은/다른 화면을 구분하지 못합니다") }
        failures += worldTextFailures(recognizer, dumpDir: dumpDir)
        failures += wrappedLinkFailures(recognizer, dumpDir: dumpDir)
        failures += wrappedLinkRunFailures(recognizer, dumpDir: dumpDir)
        failures += koreanGuildFailures(recognizer, dumpDir: dumpDir)
        failures += ownLineFailures(recognizer, dumpDir: dumpDir)
        // A second-model pass that throws is skipped silently in the app; here it would make a
        // broken run look like a clean one.
        if VisionTextRecognizer.failedPasses > 0 {
            failures.append("글자 인식 요청 \(VisionTextRecognizer.failedPasses)번이 실패해 건너뛰었습니다 (이 결과는 믿을 수 없습니다)")
        }

        if failures.isEmpty {
            print("결과: 통과")
            return 0
        }
        print("결과: 실패")
        failures.forEach { print("  - \($0)") }
        return 1
    }

    // Floors sit a few points under what the shipping configuration measures, so a regression in
    // Vision or in the preprocessing shows up without the test being flaky.
    private static let thresholds: [(String, Double)] = [
        ("en", 0.95), ("ko", 0.93), ("es", 0.90), ("pt", 0.90), ("ru", 0.88), ("zh", 0.88), ("ja", 0.88),
    ]
    private static let structureThreshold = 0.93
    private static let colorThreshold = 0.97

    /// A wrapped message under a header row with a class-coloured name, with names of the game
    /// world (and a row of chat tab labels) showing through the window: the world text must not
    /// end up in the chat, and the message must come out whole, under its full sender name.
    private static func worldTextFailures(_ recognizer: VisionTextRecognizer, dumpDir: URL?) -> [String] {
        typealias Line = SyntheticChat.Line
        typealias Segment = SyntheticChat.Segment
        let pink = SyntheticChat.Palette.channel
        let gold = RGBColor(r: 1, g: 0.82, b: 0)
        let green = RGBColor(r: 0, g: 1, b: 0)
        func header(_ name: String, _ body: String) -> Line {
            Line("en", "channel", pink, segments: [
                Segment(text: "[1. 공개 - 도시] [", color: pink),
                Segment(text: name, color: SyntheticChat.Palette.mageName),
                Segment(text: "]: " + body, color: pink),
            ])
        }
        func wrapped(_ text: String) -> Line {
            var line = Line("en", "channel", pink, text)
            line.wrapped = true
            return line
        }
        let lines: [Line] = [
            Line("ko", "system", gold, "일반"),
            Line("ko", "system", SyntheticChat.Palette.system, "규칙을 지키며 즐겁게 플레이하시기 바랍니다."),
            header("Lorem Dolor", "We're"),
            wrapped("<The Example Guild> and we rule! Recruiting"),
            wrapped("all for Leveling, Dungeoning, and Raiding."),
            header("Tamsin Alder", "Dps Lf"),
            wrapped("Stocks"),
        ]
        let world = [
            SyntheticChat.WorldText(text: "전투", color: gold, row: 0, gap: 40, sizeFactor: 1),
            SyntheticChat.WorldText(text: "Trade", color: gold, row: 0, gap: 110, sizeFactor: 1),
            SyntheticChat.WorldText(text: "가나다 라마", color: green, row: 1, gap: 90),
            SyntheticChat.WorldText(text: "<빵 장수>", color: green, row: 2, gap: -8),
            // A player's name through the middle of a wrapped row, and one over the name group
            // of a header row.
            SyntheticChat.WorldText(text: "Mossy Example", color: RGBColor(r: 0.42, g: 0.42, b: 1), row: 4, gap: -190),
            SyntheticChat.WorldText(text: "Quill Harrow", color: RGBColor(r: 0.42, g: 0.42, b: 1), row: 5, gap: -150),
        ]
        let style = SyntheticChat.Style(fontName: SyntheticChat.fontName(for: .koKR), pointSize: 16, scale: 2,
                                        background: .darkPanel, edge: .shadow)
        guard let rendered = SyntheticChat.render(lines: lines, style: style, canvasPoints: CGSize(width: 470, height: 160),
                                                  world: world),
              let frame = try? recognizer.recognizeSync(rendered.image, clientLocale: .koKR) else {
            return ["세상 글자 겹침: 이미지를 만들거나 읽지 못했습니다"]
        }
        if let dumpDir { writePNG(rendered.image, to: dumpDir.appendingPathComponent("koKR_world_text.png")) }
        let tracker = ChatTracker(clientLocale: .koKR)
        var messages: [ChatMessage] = []
        let start = Date()
        for n in 0..<4 { messages += tracker.ingest(frame, now: start.addingTimeInterval(Double(n) * 0.7)) }

        var failures: [String] = []
        func fail(_ what: String) {
            failures.append("세상 글자 겹침: \(what) — " + messages.map { "〈\($0.sender ?? "-")〉\($0.body)" }.joined(separator: " / "))
        }
        let chat = messages.filter { $0.channel == .publicChannel }
        if messages.count != 3 || chat.count != 2 {
            fail("메시지 3개(안내 1, 채팅 2)가 나와야 하는데 \(messages.count)개")
        } else {
            if chat[0].sender != "Lorem Dolor" || chat[1].sender != "Tamsin Alder" { fail("보낸 사람 이름이 다름") }
            if !chat[0].body.hasPrefix("We're <The Example Guild>") || !chat[0].body.hasSuffix("all for Leveling, Dungeoning, and Raiding.") {
                fail("줄바꿈된 메시지가 온전하지 않음")
            }
            if chat[1].body != "Dps Lf Stocks" { fail("둘째 메시지가 온전하지 않음") }
        }
        if messages.contains(where: { m in ["장수", "빵", "라마", "가나다", "일반", "전투", "Trade", "Mossy", "Quill", "Harrow"].contains { m.rawText.contains($0) } }) {
            fail("채팅이 아닌 글자가 섞임")
        }

        // A hostile name, in the red a yell is written in, over the end of a channel header
        // row: the channel tag tells that the row is no yell, so the red is not its own.
        let hostile = [
            header("Lorem Dolor", "any tips"),
            wrapped("for leveling a warrior in these caves please?"),
            header("Tamsin Alder", "Dps Lf Stocks"),
        ]
        let red = [SyntheticChat.WorldText(text: "Quill Harrow", color: RGBColor(r: 1, g: 0.16, b: 0.16), row: 0, gap: -120)]
        if let scene = SyntheticChat.render(lines: hostile, style: style, canvasPoints: CGSize(width: 470, height: 80), world: red),
           let read = try? recognizer.recognizeSync(scene.image, clientLocale: .koKR) {
            if let dumpDir { writePNG(scene.image, to: dumpDir.appendingPathComponent("koKR_hostile_name.png")) }
            let second = ChatTracker(clientLocale: .koKR)
            var said: [ChatMessage] = []
            for n in 0..<8 { said += second.ingest(read, now: start.addingTimeInterval(Double(n) * 0.7)) }
            let shown = said.map { "〈\($0.sender ?? "-")〉\($0.body)" }.joined(separator: " / ")
            if said.contains(where: { $0.rawText.contains("Quill") || $0.rawText.contains("Harrow") }) {
                failures.append("세상 글자 겹침: 붉은 이름이 채팅에 섞임 — \(shown)")
            }
            if said.first?.sender != "Lorem Dolor" || !(said.first?.body.hasSuffix("for leveling a warrior in these caves please?") ?? false)
                || said.last?.body != "Dps Lf Stocks" {
                failures.append("세상 글자 겹침: 붉은 이름에 가린 메시지가 온전하지 않음 — \(shown)")
            }
        } else {
            failures.append("세상 글자 겹침: 붉은 이름 화면을 만들거나 읽지 못했습니다")
        }

        // Names in colours that prove little by themselves (the grey of a dead or tapped unit,
        // the white of a name plate) behind the end of a wrapped row and behind the few
        // words of a header row: they show nothing of the row's colour and are made of name
        // words, so they are cut all the same. A chat word in the row's own colour stays.
        let quiet = [
            header("Lorem Dolor", "any tips for leveling a"),
            wrapped("warrior in these caves please?"),
            header("Tamsin Alder", "Dps Lf Stocks"),
        ]
        let paleNames = [
            SyntheticChat.WorldText(text: "Quill Harrow", color: RGBColor(r: 0.67, g: 0.67, b: 0.67), row: 1, gap: 10),
            SyntheticChat.WorldText(text: "<Mossy Example>", color: RGBColor(r: 0.92, g: 0.92, b: 0.92), row: 2, gap: 10),
        ]
        if let scene = SyntheticChat.render(lines: quiet, style: style, canvasPoints: CGSize(width: 560, height: 80), world: paleNames),
           let read = try? recognizer.recognizeSync(scene.image, clientLocale: .koKR) {
            if let dumpDir { writePNG(scene.image, to: dumpDir.appendingPathComponent("koKR_pale_names.png")) }
            let third = ChatTracker(clientLocale: .koKR)
            var said: [ChatMessage] = []
            for n in 0..<8 { said += third.ingest(read, now: start.addingTimeInterval(Double(n) * 0.7)) }
            let shown = said.map { "〈\($0.sender ?? "-")〉\($0.body)" }.joined(separator: " / ")
            if said.contains(where: { m in ["Quill", "Harrow", "Mossy", "Example"].contains { m.rawText.contains($0) } }) {
                failures.append("세상 글자 겹침: 회색·흰색 이름이 채팅에 섞임 — \(shown)")
            }
            if said.count != 2 || said.first?.sender != "Lorem Dolor"
                || said.first?.body != "any tips for leveling a warrior in these caves please?" || said.last?.body != "Dps Lf Stocks" {
                failures.append("세상 글자 겹침: 회색·흰색 이름 옆의 메시지가 온전하지 않음 — \(shown)")
            }
        } else {
            failures.append("세상 글자 겹침: 회색·흰색 이름 화면을 만들거나 읽지 못했습니다")
        }
        print("[세상 글자 겹침] 채팅 탭 이름·머리 위 이름이 비치는 화면: \(failures.isEmpty ? "통과" : "실패")\n")
        return failures
    }

    /// Item links in their quality colours that wrap onto the next row: the words of a link at
    /// the end of a row are chat in another colour, not text of the world, and must stay.
    private static func wrappedLinkFailures(_ recognizer: VisionTextRecognizer, dumpDir: URL?) -> [String] {
        typealias Line = SyntheticChat.Line
        typealias Segment = SyntheticChat.Segment
        let pink = SyntheticChat.Palette.channel
        // The last two are the white of a common item and the grey of a poor one: colours
        // that are told from text of the world by more than the colour itself, also on a
        // wrapped row that has only a word or two behind the end of its link.
        let qualities = [SyntheticChat.Palette.epic, SyntheticChat.Palette.legendary, RGBColor(r: 0.12, g: 1, b: 0),
                         RGBColor(r: 1, g: 1, b: 1), RGBColor(r: 0.62, g: 0.62, b: 0.62)]
        let cases: [(name: String, lead: String, linkHead: String, linkTail: String, rest: String)] = [
            ("Odalys", "WTS cheap today ", "[Blade of Eternal", "Darkness]", " and also some cloth"),
            ("Hexbloom", "Selling this ", "[Sulfuras, Hand of", "Ragnaros]", " to the best offer"),
            ("Quillon", "have a spare ", "[Robe of the", "Archmage]", " whisper me if you need it"),
            ("Mirelda", "anyone need some ", "[Heavy Linen", "Bandage]", " pst me"),
            ("Aldric", "haha who wants my ", "[Cracked Leather", "Belt]", " for free"),
        ]
        var lines: [Line] = []
        for (n, c) in cases.enumerated() {
            lines.append(Line("en", "channel", pink, segments: [
                Segment(text: "[2. 거래 - 도시] [\(c.name)]: " + c.lead, color: pink),
                Segment(text: c.linkHead, color: qualities[n]),
            ]))
            var tail = Line("en", "channel", pink, segments: [
                Segment(text: c.linkTail, color: qualities[n]),
                Segment(text: c.rest, color: pink),
            ])
            tail.wrapped = true
            lines.append(tail)
        }
        let style = SyntheticChat.Style(fontName: SyntheticChat.fontName(for: .koKR), pointSize: 16, scale: 2,
                                        background: .darkPanel, edge: .shadow)
        guard let rendered = SyntheticChat.render(lines: lines, style: style, canvasPoints: CGSize(width: 470, height: 230)),
              let frame = try? recognizer.recognizeSync(rendered.image, clientLocale: .koKR) else {
            return ["줄바꿈된 아이템 링크: 이미지를 만들거나 읽지 못했습니다"]
        }
        if let dumpDir { writePNG(rendered.image, to: dumpDir.appendingPathComponent("koKR_wrapped_links.png")) }
        let tracker = ChatTracker(clientLocale: .koKR)
        var messages: [ChatMessage] = []
        let start = Date()
        for n in 0..<4 { messages += tracker.ingest(frame, now: start.addingTimeInterval(Double(n) * 0.7)) }

        var failures: [String] = []
        let got = messages.map { "〈\($0.sender ?? "-")〉\($0.body)" }.joined(separator: " / ")
        if messages.count != cases.count {
            failures.append("줄바꿈된 아이템 링크: 메시지 \(cases.count)개가 나와야 하는데 \(messages.count)개 — \(got)")
        } else {
            for (n, (message, c)) in zip(messages, cases).enumerated() {
                let want = c.lead + c.linkHead + " " + c.linkTail + c.rest
                // Compared without case and spacing: this checks that no word went missing, not
                // how well each glyph was read.
                func fold(_ s: String) -> String { s.lowercased().filter { $0.isLetter } }
                // A bracket in a pale colour is read as a thin letter at times ("Bandagel"):
                // for the pale links one letter more or less is no missing word.
                func oneLetterApart(_ a: String, _ b: String) -> Bool {
                    let x = Array(a), y = Array(b)
                    guard abs(x.count - y.count) <= 1 else { return false }
                    var i = 0, j = 0, edits = 0
                    while i < x.count, j < y.count {
                        if x[i] == y[j] { i += 1; j += 1; continue }
                        edits += 1
                        if x.count > y.count { i += 1 } else if y.count > x.count { j += 1 } else { i += 1; j += 1 }
                    }
                    return edits + (x.count - i) + (y.count - j) <= 1
                }
                let whole = n < 3 ? fold(message.body) == fold(want) : oneLetterApart(fold(message.body), fold(want))
                if message.sender != c.name || !whole {
                    failures.append("줄바꿈된 아이템 링크: \(c.name)의 메시지가 온전하지 않음 — \(got)")
                }
            }
        }
        print("[줄바꿈된 아이템 링크] 품질 색 링크가 다음 줄로 넘어가는 화면: \(failures.isEmpty ? "통과" : "실패")\n")
        return failures
    }

    /// Quest links (orange, the colour of an emote) and links in the yellow of a notice that
    /// wrap: a wrapped row that is all link, beginning in the middle of one, is the rest of the
    /// message above and no line of its own, whatever the colour says.
    private static func wrappedLinkRunFailures(_ recognizer: VisionTextRecognizer, dumpDir: URL?) -> [String] {
        typealias Line = SyntheticChat.Line
        typealias Segment = SyntheticChat.Segment
        let pink = SyntheticChat.Palette.channel
        let orange = RGBColor(r: 1, g: 0.5, b: 0.25), yellow = RGBColor(r: 1, g: 1, b: 0)
        func header(_ name: String, _ text: String, link: String, _ colour: RGBColor) -> Line {
            Line("en", "channel", pink, segments: [
                Segment(text: "[1. 공개 - 저습지] [\(name)]: " + text, color: pink), Segment(text: link, color: colour),
            ])
        }
        func wrapped(_ segments: [Segment]) -> Line {
            var line = Line("en", "channel", pink, segments: segments)
            line.wrapped = true
            return line
        }
        let lines: [Line] = [
            Line("en", "channel", pink, "[1. 공개 - 저습지] [Odalys]: anyone around for some quests"),
            header("Exa Stormcaller", "LFG", link: "[The Old Iron", orange),
            wrapped([Segment(text: "Vow][Bring Back a Ring][The Marrow Span]", color: orange)]),
            header("Fenna Pim", "who has done ", link: "[The Lost Tablets", yellow),
            wrapped([Segment(text: "of Will]", color: yellow), Segment(text: " yet? need help", color: pink)]),
            header("Hexbloom", "can share ", link: "[Fall of Dun", orange),
            wrapped([Segment(text: "Modr][The Greenwarden]", color: orange)]),
            Line("en", "channel", pink, "[1. 공개 - 저습지] [Odalys]: what about tomorrow"),
        ]
        let wanted: [(String, String)] = [
            ("Odalys", "anyone around for some quests"),
            ("Exa Stormcaller", "LFG[The Old Iron Vow][Bring Back a Ring][The Marrow Span]"),
            ("Fenna Pim", "who has done [The Lost Tablets of Will] yet? need help"),
            ("Hexbloom", "can share [Fall of Dun Modr][The Greenwarden]"),
            ("Odalys", "what about tomorrow"),
        ]
        var failures: [String] = []
        for background in [SyntheticChat.Background.black, .darkPanel] {
            let style = SyntheticChat.Style(fontName: SyntheticChat.fontName(for: .koKR), pointSize: 16, scale: 2,
                                            background: background, edge: .shadow)
            guard let rendered = SyntheticChat.render(lines: lines, style: style, canvasPoints: CGSize(width: 470, height: 185)),
                  let frame = try? recognizer.recognizeSync(rendered.image, clientLocale: .koKR) else {
                failures.append("줄바꿈된 퀘스트 링크: 이미지를 만들거나 읽지 못했습니다")
                continue
            }
            if let dumpDir { writePNG(rendered.image, to: dumpDir.appendingPathComponent("koKR_wrapped_link_run_\(background.rawValue).png")) }
            let tracker = ChatTracker(clientLocale: .koKR)
            var messages: [ChatMessage] = []
            let start = Date()
            for n in 0..<4 { messages += tracker.ingest(frame, now: start.addingTimeInterval(Double(n) * 0.7)) }
            let got = messages.map { "〈\($0.sender ?? "-")〉\($0.body)" }.joined(separator: " / ")
            // Compared without spacing: this checks that no link went missing or was split off
            // and that the brackets are brackets, not how every glyph was read.
            func fold(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0 == "[" || $0 == "]" } }
            if messages.count != wanted.count {
                failures.append("줄바꿈된 퀘스트 링크(\(background.rawValue)): 메시지 \(wanted.count)개가 나와야 하는데 \(messages.count)개 — \(got)")
            } else if zip(messages, wanted).contains(where: { $0.sender != $1.0 || fold($0.body) != fold($1.1) || $0.channel != .publicChannel }) {
                failures.append("줄바꿈된 퀘스트 링크(\(background.rawValue)): 메시지가 온전하지 않음 — \(got)")
            }
            if messages.contains(where: { LanguageGate.isOnlyLinks($0.body) && TranslationPolicy.shouldTranslate($0, settings: everyTab) }) {
                failures.append("줄바꿈된 퀘스트 링크(\(background.rawValue)): 링크뿐인 줄이 번역 대상이 됨 — \(got)")
            }
        }
        print("[줄바꿈된 퀘스트 링크] 주황·노랑 링크가 다음 줄로 넘어가는 화면 (불투명·반투명 배경): \(failures.isEmpty ? "통과" : "실패")\n")
        return failures
    }

    private static var everyTab: AppSettings {
        var settings = AppSettings()
        settings.enabledGroups = Set(ChannelGroup.allCases)
        return settings
    }

    /// The commonest chat of a Korean guild on a foreign realm: the Korean guild tag, a Latin
    /// name in its class colour, a short Korean message. No model but the Korean one can read
    /// such a message, and the Latin/Cyrillic model answers with digits, bars and Cyrillic for
    /// it: none of that may come out, on an opaque background or a translucent one.
    private static func koreanGuildFailures(_ recognizer: VisionTextRecognizer, dumpDir: URL?) -> [String] {
        typealias Line = SyntheticChat.Line
        typealias Segment = SyntheticChat.Segment
        let green = SyntheticChat.Palette.guild, pink = SyntheticChat.Palette.channel
        // Class colours: paladin, druid, rogue, mage, hunter, shaman.
        let classes = [RGBColor(r: 0.96, g: 0.55, b: 0.73), RGBColor(r: 1, g: 0.49, b: 0.04), RGBColor(r: 1, g: 0.96, b: 0.41),
                       RGBColor(r: 0.41, g: 0.8, b: 0.94), RGBColor(r: 0.67, g: 0.83, b: 0.45), RGBColor(r: 0, g: 0.44, b: 0.87)]
        let names = ["Brann Oakheart", "Mira Fenwick", "Odo Marsh", "Lu Mi", "Wren Thorn", "Dorn Flint"]
        func said(_ who: Int, _ tag: String, _ colour: RGBColor, _ body: [Segment]) -> Line {
            Line(tag == "길드" ? "ko" : "en", tag == "길드" ? "guild" : "channel", colour, segments: [
                Segment(text: "[\(tag)] [", color: colour), Segment(text: names[who], color: classes[who]), Segment(text: "]: ", color: colour),
            ] + body)
        }
        func guild(_ who: Int, _ body: String) -> Line { said(who, "길드", green, [Segment(text: body, color: green)]) }
        let lines: [Line] = [
            guild(0, "와 재밌겠다"), guild(1, "그거 법사님"), guild(1, "왜 안오시는..."), guild(2, "비싼템인데 ㄷㄷ"),
            guild(2, "그럴거면 저도 불러요!!"), guild(3, "우편함 확인해도 안들어왔네 ㅠㅠ"),
            said(3, "길드", green, [Segment(text: "[조잡한 연마석]", color: .white), Segment(text: " 이거 필요하신분?", color: green)]),
            guild(4, "20렙 3개 구함"), guild(4, "법사는"), guild(4, "넵"),
            // Mixed: Korean with an English word, English with a Korean word.
            guild(5, "오늘 MC 가실분"), guild(0, "버프 plz ㅠㅠ"),
            said(5, "1. 공개 - 저습지", pink, [Segment(text: "lol that 탱커 is so good", color: pink)]),
            said(2, "1. 공개 - 저습지", pink, [Segment(text: "THEY TOOK OUR FISH", color: pink)]),
        ]
        var failures: [String] = []
        var styles: [SyntheticChat.Style] = []
        for background in [SyntheticChat.Background.black, .darkPanel, .busy] {
            // (Small text on a 1x display over a busy scene is measured with the hard conditions.)
            for (size, scale) in [(CGFloat(16), CGFloat(2)), (14, 2), (14, 1)] where !(background == .busy && scale == 1) {
                styles.append(.init(fontName: SyntheticChat.fontName(for: .koKR), pointSize: size, scale: scale, background: background, edge: .shadow))
            }
        }
        var rows = 0, exact = 0
        for style in styles {
            guard let rendered = SyntheticChat.render(lines: lines, style: style),
                  let frame = try? recognizer.recognizeSync(rendered.image, clientLocale: .koKR) else {
                failures.append("한글 길드 대화: 이미지를 만들거나 읽지 못했습니다 (\(style.label))")
                continue
            }
            if let dumpDir {
                let name = "koKR_guild_\(style.label).png".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
                writePNG(rendered.image, to: dumpDir.appendingPathComponent(name))
            }
            // No pass may hand out letters of a script that cannot stand in these rows.
            let foreign = frame.lines.filter { line in
                line.text.unicodeScalars.contains { (0x370...0x52F).contains($0.value) || (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
            }
            if !foreign.isEmpty {
                failures.append("한글 길드 대화(\(style.label)): 있을 수 없는 문자가 나옴 — " + foreign.map(\.text).joined(separator: " / "))
            }
            let tracker = ChatTracker(clientLocale: .koKR)
            var messages: [ChatMessage] = []
            let start = Date()
            for n in 0..<8 { messages += tracker.ingest(frame, now: start.addingTimeInterval(Double(n) * 0.7)) }
            let got = messages.map { "〈\($0.sender ?? "-")〉\($0.body)" }.joined(separator: " / ")
            guard messages.count == lines.count else {
                failures.append("한글 길드 대화(\(style.label)): 메시지 \(lines.count)개가 나와야 하는데 \(messages.count)개 — \(got)")
                continue
            }
            for (message, line) in zip(messages, lines) {
                let truth = line.text
                let body = String(truth[truth.range(of: "]: ")!.upperBound...])
                let name = names.first { truth.contains("[\($0)]") }
                rows += 1
                // The Korean of the message letter for letter (spacing aside), under the whole name.
                func fold(_ s: String) -> String { s.filter { !$0.isWhitespace } }
                if message.sender == name, fold(message.body) == fold(body) {
                    exact += 1
                } else if hangul(message.body) != hangul(body) || message.sender == nil {
                    failures.append("한글 길드 대화(\(style.label)): \(truth) → 〈\(message.sender ?? "-")〉\(message.body)")
                } else if CommandLine.arguments.contains("--verbose") {
                    print("    \(style.label): \(truth) → 〈\(message.sender ?? "-")〉\(message.body)")
                }
                if line.channel == "guild", TranslationPolicy.shouldTranslate(message, settings: everyTab) {
                    failures.append("한글 길드 대화(\(style.label)): 한국어 글이 번역 대상이 됨 — \(message.body)")
                }
            }
        }
        // Every Hangul syllable must be right in every row (checked above); glyph slips in the
        // Latin names and punctuation of a rendering are allowed for in a few rows.
        if rows > 0, Double(exact) / Double(rows) < 0.9 {
            failures.append(String(format: "한글 길드 대화: 글자 하나까지 맞은 줄 %d/%d (%.0f%%) < 기준 90%%", exact, rows, Double(exact) / Double(rows) * 100))
        }
        print("[한글 길드 대화] 직업 색 영문 이름 + 짧은 한글 본문, 불투명·반투명 배경 \(styles.count)종: "
              + "\(failures.isEmpty ? "통과" : "실패") (완전 일치 \(exact)/\(rows)줄)\n")
        return failures
    }

    private static func hangul(_ s: String) -> String {
        String(s.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }.map(Character.init))
    }

    /// Lines of their own on the message column right below chat: the speech of a creature whose
    /// name has a quoted nickname (with a wrapped row), and crafting notices that begin with an
    /// item link in the link's colour. None of it belongs to the guild line above it, and the
    /// notice keeps all of its text.
    private static func ownLineFailures(_ recognizer: VisionTextRecognizer, dumpDir: URL?) -> [String] {
        typealias Line = SyntheticChat.Line
        typealias Segment = SyntheticChat.Segment
        let green = SyntheticChat.Palette.guild
        let creature = RGBColor(r: 1, g: 1, b: 0.62), loot = RGBColor(r: 0, g: 0.67, b: 0)
        func guild(_ name: String, _ body: String) -> Line { Line("ko", "guild", green, "[길드] [\(name)]: \(body)") }
        func crafted(_ item: String, _ particle: String, _ quality: RGBColor = .white) -> Line {
            Line("ko", "system", loot, segments: [Segment(text: "[\(item)]", color: quality), Segment(text: "\(particle) 만들었습니다.", color: loot)])
        }
        var second = Line("ko", "say", creature, "챙겨서 주막에서 다시 만나도록 하세나.")
        second.wrapped = true
        let lines: [Line] = [
            guild("Mira Dawnsong", "조심해서 가야겠다"),
            Line("ko", "say", creature, "\"말라깽이\" 토르벤 하크의 말: 내 창고에 그 일에 쓸 연장이 좀 있으니 그걸"),
            second,
            crafted("조잡한 연마석", "을"),
            guild("Lu Mi", "법사는"),
            crafted("일반 숫돌", "을"),
            guild("Lu Mi", "먼저 달려들어갔다가"),
            crafted("구리 주괴", "를", RGBColor(r: 0.12, g: 1, b: 0)),
            guild("Hazel Monk", "사냥꾼을 그래서 요즘에"),
            guild("Lu Mi", "안되겠다 싶으면 얼리고 점멸"),
        ]
        let wanted: [(ChatChannel, String?, String)] = [
            (.guild, "Mira Dawnsong", "조심해서 가야겠다"),
            (.say, "\"말라깽이\" 토르벤 하크", "내 창고에 그 일에 쓸 연장이 좀 있으니 그걸 챙겨서 주막에서 다시 만나도록 하세나."),
            (.system, nil, "[조잡한 연마석]을 만들었습니다."), (.guild, "Lu Mi", "법사는"),
            (.system, nil, "[일반 숫돌]을 만들었습니다."), (.guild, "Lu Mi", "먼저 달려들어갔다가"),
            (.system, nil, "[구리 주괴]를 만들었습니다."), (.guild, "Hazel Monk", "사냥꾼을 그래서 요즘에"),
            (.guild, "Lu Mi", "안되겠다 싶으면 얼리고 점멸"),
        ]
        var failures: [String] = []
        for background in [SyntheticChat.Background.black, .darkPanel] {
            let style = SyntheticChat.Style(fontName: SyntheticChat.fontName(for: .koKR), pointSize: 16, scale: 2,
                                            background: background, edge: .shadow)
            guard let rendered = SyntheticChat.render(lines: lines, style: style, canvasPoints: CGSize(width: 560, height: 225)),
                  let frame = try? recognizer.recognizeSync(rendered.image, clientLocale: .koKR) else {
                failures.append("제자리 줄: 이미지를 만들거나 읽지 못했습니다")
                continue
            }
            if let dumpDir { writePNG(rendered.image, to: dumpDir.appendingPathComponent("koKR_own_lines_\(background.rawValue).png")) }
            let tracker = ChatTracker(clientLocale: .koKR)
            var messages: [ChatMessage] = []
            let start = Date()
            for n in 0..<6 { messages += tracker.ingest(frame, now: start.addingTimeInterval(Double(n) * 0.7)) }
            let got = messages.map { "〈\($0.channel.rawValue) \($0.sender ?? "-")〉\($0.body)" }.joined(separator: " / ")
            // Letters, digits and brackets: which rows are one line and that none lost its
            // text, not how every glyph of this rendering was read.
            func fold(_ s: String) -> String {
                String(s.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "[" || $0 == "]" }
                    .map(Character.init))
            }
            if messages.count != wanted.count {
                failures.append("제자리 줄(\(background.rawValue)): 메시지 \(wanted.count)개가 나와야 하는데 \(messages.count)개 — \(got)")
            } else if zip(messages, wanted).contains(where: { message, want in
                // (A glyph of a name read wrong in this rendering is no line gone astray.)
                let name = levenshtein(Array(fold(message.sender ?? "")), Array(fold(want.1 ?? "")))
                return message.channel != want.0 || name > 1 || (message.sender == nil) != (want.1 == nil) || fold(message.body) != fold(want.2)
            }) {
                failures.append("제자리 줄(\(background.rawValue)): 줄이 온전하지 않음 — \(got)")
            }
        }
        print("[제자리 줄] 따옴표 별명이 붙은 NPC의 말과 아이템 링크로 시작하는 제작 안내 (불투명·반투명 배경): \(failures.isEmpty ? "통과" : "실패")\n")
        return failures
    }

    private static func fingerprintBehaves() -> Bool {
        let style = SyntheticChat.Style(fontName: SyntheticChat.fontName(for: .koKR), pointSize: 14, scale: 2,
                                        background: .darkPanel, edge: .shadow)
        let lines = SyntheticChat.koreanClientLines
        guard let a = SyntheticChat.render(lines: lines, style: style),
              let b = SyntheticChat.render(lines: lines, style: style),
              // A new message arrived: everything scrolls up one line.
              let c = SyntheticChat.render(lines: Array(lines.dropFirst()) + [lines[0]], style: style)
        else { return false }
        let fa = VisionTextRecognizer.fingerprint(a.image)
        return fa == VisionTextRecognizer.fingerprint(b.image) && fa != VisionTextRecognizer.fingerprint(c.image)
    }

    /// The first request with a language set loads its model (about a second); keep that out of
    /// the per-frame timing. The full line set makes the rescue passes load theirs too.
    private static func warmUp(_ recognizer: VisionTextRecognizer, _ locale: ClientLocale) {
        let style = SyntheticChat.Style(fontName: SyntheticChat.fontName(for: locale), pointSize: 14, scale: 1,
                                        background: .darkPanel, edge: .shadow)
        if let r = SyntheticChat.render(lines: SyntheticChat.lines(for: locale), style: style) {
            _ = try? recognizer.recognizeSync(r.image, clientLocale: locale)
        }
    }

    // MARK: - Strategy grid

    private static func runGrid(verbose: Bool) -> Int32 {
        typealias O = VisionTextRecognizer.Options
        func make(_ edit: (inout O) -> Void) -> O { var o = O(); edit(&o); return o }
        let all = ["ko-KR", "en-US", "zh-Hans", "ja-JP", "ru-RU"]
        func single(_ languages: [String], _ edit: (inout O) -> Void = { _ in }) -> O {
            make {
                $0.languages = languages; $0.automaticallyDetectsLanguage = false; $0.rescue = false
                $0.upscale = 1; $0.preprocess = VisionTextRecognizer.Options.Preprocess.none; edit(&$0)
            }
        }
        let strategies: [(String, O)] = [
            ("SHIPPING (primary + rescue)", make { _ in }),
            ("shipping without rescue", make { $0.rescue = false }),
            ("ko,en", single(["ko-KR", "en-US"])),
            ("en,ko", single(["en-US", "ko-KR"])),
            ("en,ru", single(["en-US", "ru-RU"])),
            ("ko,en,zh,ja,ru", single(all)),
            ("ru,en,ko,zh,ja", single(["ru-RU", "en-US", "ko-KR", "zh-Hans", "ja-JP"])),
            ("zh,ko,en,ja,ru", single(["zh-Hans", "ko-KR", "en-US", "ja-JP", "ru-RU"])),
            ("ja,ko,en,zh,ru", single(["ja-JP", "ko-KR", "en-US", "zh-Hans", "ru-RU"])),
            ("ko,en.. + autodetect", single(all) { $0.automaticallyDetectsLanguage = true }),
            ("en,ko.. + autodetect", single(["en-US", "ko-KR", "zh-Hans", "ja-JP", "ru-RU"]) {
                $0.automaticallyDetectsLanguage = true }),
            ("ko,en + langcorr", single(["ko-KR", "en-US"]) { $0.languageCorrection = true }),
            ("en,ru + langcorr", single(["en-US", "ru-RU"]) { $0.languageCorrection = true }),
            ("ko,en fast", single(["ko-KR", "en-US"]) { $0.accurate = false }),
            ("en fast", single(["en-US"]) { $0.accurate = false }),
            ("ko,en + up1.5", single(["ko-KR", "en-US"]) { $0.upscale = 1.5 }),
            ("ko,en + up2", single(["ko-KR", "en-US"]) { $0.upscale = 2 }),
            ("ko,en + maxch", single(["ko-KR", "en-US"]) { $0.preprocess = .maxChannel }),
            ("ko,en + maxch inv", single(["ko-KR", "en-US"]) { $0.preprocess = .maxChannelInverted }),
            ("ko,en + maxch inv up2", single(["ko-KR", "en-US"]) { $0.preprocess = .maxChannelInverted; $0.upscale = 2 }),
            ("ko,en + customWords", single(["ko-KR", "en-US"]) { $0.customWords = gamingWords }),
            ("ko,en + langcorr + customWords", single(["ko-KR", "en-US"]) {
                $0.languageCorrection = true; $0.customWords = gamingWords }),
            ("SHIPPING, never upscale", make { $0.upscale = 1 }),
            ("SHIPPING, always up2", make { $0.upscale = 2 }),
            ("SHIPPING, colours untouched", make { $0.preprocess = VisionTextRecognizer.Options.Preprocess.none }),
            ("SHIPPING + maxch", make { $0.preprocess = .maxChannel }),
            ("SHIPPING + 2nd opinion (enUS)", make { $0.secondOpinionForUnsureLines = true }),
            ("SHIPPING + maxch inv, no up", make { $0.preprocess = .maxChannelInverted; $0.upscale = 1 }),
            ("SHIPPING + maxch inv", make { $0.preprocess = .maxChannelInverted }),
            ("SHIPPING + langcorr", make { $0.languageCorrection = true }),
        ]
        let filter = CommandLine.arguments.firstIndex(of: "--only").flatMap { i -> String? in
            i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
        }

        for locale in ClientLocale.allCases {
            let lines = SyntheticChat.lines(for: locale)
            let rendered = gateStyles(locale).compactMap { SyntheticChat.render(lines: lines, style: $0) }
            print("=== \(locale.rawValue) client, \(rendered.count) images x \(lines.count) lines ===")
            print("strategy".padding(toLength: 30, withPad: " ", startingAt: 0)
                  + "   all    en    ko    es    pt    ru    zh    ja  struct color  1x-all 2x-all  ms/frame")
            for (name, options) in strategies {
                if let filter, !name.contains(filter) { continue }
                let recognizer = VisionTextRecognizer(options: options)
                warmUp(recognizer, locale)
                var total = Score(), one = Score(), two = Score()
                for r in rendered {
                    let s = evaluate(r, recognizer: recognizer, locale: locale, verbose: verbose)
                    total.add(s)
                    if r.style.scale == 1 { one.add(s) } else { two.add(s) }
                }
                var row = name.padding(toLength: 30, withPad: " ", startingAt: 0)
                row += String(format: " %5.1f", total.overall * 100)
                for language in ["en", "ko", "es", "pt", "ru", "zh", "ja"] {
                    row += String(format: " %5.1f", total.accuracy(language) * 100)
                }
                row += String(format: "  %5.1f %5.1f   %5.1f  %5.1f   %6.1f", total.structure * 100,
                              total.colorAccuracy * 100, one.overall * 100, two.overall * 100, total.msPerFrame)
                print(row)
            }
            print("")
        }
        return 0
    }

    private static let gamingWords = [
        "dps", "mara", "WTS", "WTB", "LF2M", "LFG", "LFM", "UBRS", "LBRS", "BRD", "omw", "rdy", "inv", "pls",
        "Thrall", "Jaina", "Anduin", "Varian", "Sylvanas", "Garrosh", "Thunderfury", "Windseeker",
    ]

    // MARK: - Scoring

    struct Score {
        var charTotal: [String: Double] = [:]
        var charCorrect: [String: Double] = [:]
        var structTotal = 0.0, structCorrect = 0.0
        var colorTotal = 0, colorCorrect = 0
        var seconds = 0.0
        var frames = 0

        mutating func add(_ o: Score) {
            for (k, v) in o.charTotal { charTotal[k, default: 0] += v }
            for (k, v) in o.charCorrect { charCorrect[k, default: 0] += v }
            structTotal += o.structTotal; structCorrect += o.structCorrect
            colorTotal += o.colorTotal; colorCorrect += o.colorCorrect
            seconds += o.seconds; frames += o.frames
        }
        func accuracy(_ language: String) -> Double {
            guard let t = charTotal[language], t > 0 else { return 1 }
            return (charCorrect[language] ?? 0) / t
        }
        var overall: Double {
            let t = charTotal.values.reduce(0, +)
            return t > 0 ? charCorrect.values.reduce(0, +) / t : 1
        }
        var structure: Double { structTotal > 0 ? structCorrect / structTotal : 1 }
        var colorAccuracy: Double { colorTotal > 0 ? Double(colorCorrect) / Double(colorTotal) : 1 }
        var msPerFrame: Double { frames > 0 ? seconds / Double(frames) * 1000 : 0 }

        func report() -> String {
            let names = [("en", "영어"), ("ko", "한국어"), ("es", "스페인어"), ("pt", "포르투갈어"),
                         ("ru", "러시아어"), ("zh", "중국어"), ("ja", "일본어")]
            var out = "  글자 정확도:"
            for (code, name) in names where charTotal[code] != nil {
                out += String(format: " %@ %.1f%%", name, accuracy(code) * 100)
            }
            out += String(format: "\n  전체 %.1f%% · 구조 문자([]:숫자) %.1f%% · 색 판별 %d/%d (%.1f%%) · 프레임당 %.0f ms",
                          overall * 100, structure * 100, colorCorrect, colorTotal, colorAccuracy * 100, msPerFrame)
            return out
        }
    }

    private static let palette: [(String, RGBColor)] = [
        ("say", SyntheticChat.Palette.say), ("yell", SyntheticChat.Palette.yell),
        ("guild", SyntheticChat.Palette.guild), ("party", SyntheticChat.Palette.party),
        ("raid", SyntheticChat.Palette.raid), ("whisper", SyntheticChat.Palette.whisper),
        ("channel", SyntheticChat.Palette.channel), ("system", SyntheticChat.Palette.system),
    ]

    static func classify(_ c: RGBColor) -> String {
        palette.min { a, b in distance(a.1, c) < distance(b.1, c) }?.0 ?? "say"
    }

    private static func distance(_ a: RGBColor, _ b: RGBColor) -> Double {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return dr * dr + dg * dg + db * db
    }

    static func evaluate(_ rendered: SyntheticChat.Rendered, recognizer: VisionTextRecognizer,
                         locale: ClientLocale, verbose: Bool) -> Score {
        var score = Score()
        let start = CFAbsoluteTimeGetCurrent()
        let frame: OCRFrame
        do {
            frame = try recognizer.recognizeSync(rendered.image, clientLocale: locale)
        } catch {
            frame = OCRFrame(lines: [], imageSize: .zero)
        }
        score.seconds = CFAbsoluteTimeGetCurrent() - start
        score.frames = 1

        for (truth, box) in zip(rendered.lines, rendered.boxes) {
            // The recognised line that covers this row of the picture.
            let match = frame.lines.max { a, b in
                verticalOverlap(a.box, box) < verticalOverlap(b.box, box)
            }.flatMap { verticalOverlap($0.box, box) > box.height * 0.4 ? $0 : nil }

            let want = comparable(truth.text)
            let got = comparable(match?.text ?? "")
            let distance = levenshtein(want, got)
            let length = Double(max(want.count, got.count))
            score.charTotal[truth.language, default: 0] += length
            score.charCorrect[truth.language, default: 0] += max(0, length - Double(distance))

            let wantS = want.filter(isStructural), gotS = got.filter(isStructural)
            let lengthS = Double(max(wantS.count, gotS.count))
            score.structTotal += lengthS
            score.structCorrect += max(0, lengthS - Double(levenshtein(wantS, gotS)))

            score.colorTotal += 1
            let label = match.map { classify($0.color) }
            if label == truth.channel { score.colorCorrect += 1 }

            if verbose, distance > 0 || label != truth.channel {
                print("    \(rendered.style.label)")
                print("      원본: \(truth.text)")
                print("      인식: \(match?.text ?? "(없음)")")
                if let m = match, label != truth.channel {
                    print(String(format: "      색: %@ 이어야 하는데 %@ (%.2f %.2f %.2f)", truth.channel,
                                 label ?? "?", m.color.r, m.color.g, m.color.b))
                }
            }
        }
        return score
    }

    private static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }

    private static func isStructural(_ c: Character) -> Bool {
        c == "[" || c == "]" || c == ":" || c.isNumber
    }

    /// Whitespace-insensitive, width-insensitive form: spacing and full-width punctuation are not
    /// what the translator cares about.
    private static func comparable(_ s: String) -> [Character] {
        Array(s.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace })
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
