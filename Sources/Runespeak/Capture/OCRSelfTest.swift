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
