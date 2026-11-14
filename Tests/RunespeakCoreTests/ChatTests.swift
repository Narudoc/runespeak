import XCTest
import CoreGraphics
@testable import RunespeakCore

// XCTest pulls in AppKit, which still exports a QuickDraw-era `RGBColor`.
private typealias RGBColor = RunespeakCore.RGBColor

// MARK: - Frame simulator

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private enum Palette {
    static let say = RGBColor(r: 1, g: 1, b: 1)
    static let yell = RGBColor(r: 1, g: 0.25, b: 0.25)
    static let guild = RGBColor(r: 0.25, g: 1, b: 0.25)
    static let officer = RGBColor(r: 0.25, g: 0.75, b: 0.25)
    static let party = RGBColor(r: 0.67, g: 0.67, b: 1)
    static let raid = RGBColor(r: 1, g: 0.5, b: 0)
    static let raidWarning = RGBColor(r: 1, g: 0.28, b: 0)
    static let whisper = RGBColor(r: 1, g: 0.5, b: 1)
    static let channel = RGBColor(r: 1, g: 0.75, b: 0.75)
    static let system = RGBColor(r: 1, g: 1, b: 0)
    static let emote = RGBColor(r: 1, g: 0.5, b: 0.25)
    static let loot = RGBColor(r: 0, g: 0.67, b: 0)
}

/// A scrolling chat window: logical messages are wrapped to screen lines, the last `visible`
/// lines are rendered bottom-aligned into OCR frames, optionally damaged by a jitter function.
private final class ChatSim {
    struct ScreenLine {
        var text: String
        var color: RGBColor
        var message: Int
        var first: Bool
    }

    let wrapColumns: Int
    let visible: Int
    let indent: Bool
    let charWidth: CGFloat = 8
    let rowHeight: CGFloat = 18
    let glyphHeight: CGFloat = 14
    private(set) var lines: [ScreenLine] = []
    private(set) var messages: [String] = []

    init(wrapColumns: Int = 60, visible: Int = 8, indent: Bool = false) {
        self.wrapColumns = wrapColumns; self.visible = visible; self.indent = indent
    }

    var imageSize: CGSize { CGSize(width: CGFloat(wrapColumns) * charWidth + 12, height: CGFloat(visible) * rowHeight) }

    static func columns(_ s: Substring) -> Int { TextFold.columns(s) }

    static func wrap(_ text: String, columns: Int, indentColumns: Int = 0) -> [String] {
        var out: [String] = []
        var current = ""
        func limit() -> Int { out.isEmpty ? columns : columns - indentColumns }
        for word in text.split(separator: " ") {
            var word = Substring(word)
            if current.isEmpty {
                // fall through to placement below
            } else if TextFold.columns(current) + 1 + TextFold.columns(word) <= limit() {
                current += " " + word
                continue
            } else {
                out.append(current); current = ""
            }
            // A word longer than the line (CJK without spaces) breaks between characters.
            while TextFold.columns(word) > limit() {
                var take = word.startIndex
                var used = 0
                while take < word.endIndex {
                    let w = TextFold.columns(word[take...].prefix(1))
                    if used + w > limit() { break }
                    used += w
                    take = word.index(after: take)
                }
                out.append(String(word[..<take]))
                word = word[take...]
            }
            current = String(word)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    @discardableResult
    func post(_ text: String, color: RGBColor = Palette.guild) -> Int {
        let index = messages.count
        messages.append(text)
        for (n, piece) in ChatSim.wrap(text, columns: wrapColumns, indentColumns: indent ? 2 : 0).enumerated() {
            lines.append(ScreenLine(text: piece, color: color, message: index, first: n == 0))
        }
        return index
    }

    /// Jitter: (index of the line in the log, its text) → damaged text, or nil when OCR misses the line.
    typealias Jitter = (Int, String) -> String?

    func frame(scrollBack: Int = 0, onlyLast: Int? = nil, pixelNoise: CGFloat = 0,
               confidence: ((Int) -> Double)? = nil, jitter: Jitter? = nil) -> OCRFrame {
        let end = max(0, lines.count - scrollBack)
        let start = max(0, end - visible)
        var out: [OCRLine] = []
        let shown = Array(start..<end)
        for (row, index) in shown.enumerated() {
            if let onlyLast, shown.count - row > onlyLast { continue }
            let line = lines[index]
            guard let text = jitter.map({ $0(index, line.text) }) ?? line.text else { continue }
            // Bottom-aligned, like the game.
            let fromBottom = shown.count - 1 - row
            let y = CGFloat(visible - 1 - fromBottom) * rowHeight + 2 + pixelNoise
            let x: CGFloat = 4 + ((indent && !line.first) ? 2 * charWidth : 0) + pixelNoise
            let width = CGFloat(TextFold.columns(text)) * charWidth
            out.append(OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: glyphHeight),
                               color: line.color, confidence: confidence?(index) ?? 1))
        }
        return OCRFrame(lines: out, imageSize: imageSize)
    }
}

private final class Run {
    let tracker: ChatTracker
    var emitted: [ChatMessage] = []
    var clock = Date(timeIntervalSince1970: 1_700_000_000)
    /// Number of the ingest (1-based) in which each message came out.
    var emittedAt: [Int] = []
    var frames = 0

    init(locale: ClientLocale = .enUS) { tracker = ChatTracker(clientLocale: locale) }

    @discardableResult
    func feed(_ frame: OCRFrame) -> [ChatMessage] {
        clock += 0.7
        frames += 1
        let out = tracker.ingest(frame, now: clock)
        emitted += out
        emittedAt += out.map { _ in frames }
        return out
    }

    var texts: [String] { emitted.map(\.rawText) }
}

private func guildLine(_ n: Int, _ body: String) -> String {
    let names = ["Thrall", "Jaina", "Sylvanas", "Anduin", "Velen", "Garrosh", "Tyrande", "Malfurion"]
    return "[Guild] [\(names[n % names.count])]: \(body)"
}

private let fillers = [
    "anyone up for a dungeon run tonight", "need one more healer for the raid", "selling flasks cheap in the city",
    "where is the summoning stone", "that boss fight was brutal honestly", "can someone craft me a belt",
    "invite me when the group is ready", "who has the key for the instance", "thanks for the run everyone",
    "looking for a tank with experience", "the auction house prices are crazy", "meet at the entrance in five",
    "do we have a warlock for summons", "rolling need on the trinket sorry", "what time does reset happen",
    "my bags are full again hold on",
]

private func sampleMessage(_ n: Int) -> String {
    guildLine(n, "\(fillers[n % fillers.count]) \(wordNumber(n))")
}

/// Distinct word per index, so that every message is unique without relying on digits (which
/// the jitter may damage).
private func wordNumber(_ n: Int) -> String {
    let syll = ["ka", "mo", "ri", "te", "su", "na", "hi", "ve", "lo", "du"]
    return String(n).map { syll[Int(String($0))!] }.joined()
}

/// Like XCTAssertEqual on the two streams, but reports where they first diverge.
private func assertSame(_ got: [String], _ want: [String], _ note: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if got == want { return }
    let i = zip(got, want).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(got.count, want.count)
    func at(_ a: [String], _ k: Int) -> String { k < a.count ? "\"\(a[k])\"" : "<end>" }
    XCTFail("\(note) emitted \(got.count), expected \(want.count); first difference at #\(i): got \(at(got, i)), then \(at(got, i + 1)); expected \(at(want, i)), then \(at(want, i + 1))",
            file: file, line: line)
}

// MARK: - Tracker tests

final class ChatTrackerTests: XCTestCase {

    private func flush(_ run: Run, _ sim: ChatSim, frames: Int = 3) {
        for _ in 0..<frames { run.feed(sim.frame()) }
    }

    func testSteadyScrollEmitsEachMessageOnceInOrder() {
        let sim = ChatSim()
        let run = Run()
        for n in 0..<60 {
            sim.post(sampleMessage(n))
            run.feed(sim.frame())
            run.feed(sim.frame())
        }
        flush(run, sim)
        assertSame(run.texts, sim.messages)
    }

    func testOneMessagePerFrameWithoutIdleFrames() {
        let sim = ChatSim(wrapColumns: 50, visible: 6)
        let run = Run()
        for n in 0..<80 {
            sim.post(sampleMessage(n))
            run.feed(sim.frame())
        }
        flush(run, sim)
        assertSame(run.texts, sim.messages)
    }

    func testBottomMessageIsEmittedWithinTwoFrames() {
        let sim = ChatSim()
        let run = Run()
        for n in 0..<5 { sim.post(sampleMessage(n)) }
        flush(run, sim)
        XCTAssertEqual(run.texts.count, 5)
        sim.post("[Guild] [Thrall]: hello there friends")
        let first = run.feed(sim.frame())
        let second = run.feed(sim.frame())
        XCTAssertEqual((first + second).map(\.rawText), ["[Guild] [Thrall]: hello there friends"])
        // A message with another below it is complete and comes out at once.
        sim.post("[Guild] [Jaina]: first of two")
        sim.post("[Guild] [Velen]: second of two")
        XCTAssertEqual(run.feed(sim.frame()).map(\.rawText), ["[Guild] [Jaina]: first of two"])
        XCTAssertEqual(run.feed(sim.frame()).map(\.rawText), ["[Guild] [Velen]: second of two"])
    }

    func testBurstsOfSeveralMessagesPerFrame() {
        var rng = SplitMix64(seed: 7)
        let sim = ChatSim(wrapColumns: 64, visible: 10)
        let run = Run()
        var n = 0
        for _ in 0..<120 {
            // Up to 7 single-line messages between frames leaves at least 3 known lines visible.
            let burst = Int.random(in: 0...7, using: &rng)
            for _ in 0..<burst { sim.post(guildLine(n, "burst \(wordNumber(n))")); n += 1 }
            run.feed(sim.frame())
        }
        flush(run, sim)
        assertSame(run.texts, sim.messages)
    }

    func testBurstLargerThanWindowNeverDuplicates() {
        let sim = ChatSim(wrapColumns: 64, visible: 5)
        let run = Run()
        for n in 0..<4 { sim.post(guildLine(n, "early \(wordNumber(n))")) }
        flush(run, sim)
        for n in 4..<16 { sim.post(guildLine(n, "flood \(wordNumber(n))")) }
        flush(run, sim)
        sim.post(guildLine(16, "after the flood"))
        flush(run, sim)
        // Lines that scrolled past between two captures are gone for good; everything that was
        // ever on screen comes out once, in order.
        let expected = Array(sim.messages[0..<4]) + Array(sim.messages[11...])
        assertSame(run.texts, expected)
    }

    func testWrappedMessagesAreMerged() {
        let sim = ChatSim(wrapColumns: 38, visible: 9)
        let run = Run()
        let texts = [
            "[Guild] [Thrall]: short one",
            "[Party] [Jaina]: this is a rather long message that will certainly wrap onto two or even three screen lines",
            "[Raid] [Velen]: ok",
            "[2. Trade - Stormwind City] [Anduin]: WTS [Thunderfury, Blessed Blade of the Windseeker] best price whisper me now",
            "[Guild] [Sylvanas]: another long line here to make sure consecutive wrapped messages are kept apart properly",
            "You receive loot: [Linen Cloth]x2.",
            "[Guild] [Thrall]: done",
        ]
        let colors = [Palette.guild, Palette.party, Palette.raid, Palette.channel, Palette.guild, Palette.loot, Palette.guild]
        for (t, c) in zip(texts, colors) {
            sim.post(t, color: c)
            run.feed(sim.frame())
        }
        flush(run, sim)
        assertSame(run.texts, texts)
        XCTAssertEqual(run.emitted.map(\.channel), [.guild, .party, .raid, .publicChannel, .guild, .system, .guild])
        XCTAssertEqual(run.emitted[1].body, "this is a rather long message that will certainly wrap onto two or even three screen lines")
        XCTAssertEqual(run.emitted[3].sender, "Anduin")
        XCTAssertEqual(run.emitted[3].channelLabel, "2. Trade - Stormwind City")
    }

    func testWrappedKoreanAndIndentedContinuations() {
        for indent in [false, true] {
            let sim = ChatSim(wrapColumns: 40, visible: 10, indent: indent)
            let run = Run(locale: .koKR)
            let texts = [
                "[길드] [나루]: 오늘 저녁에 공격대 가실 분 계신가요 탱커 한 분이랑 힐러 두 분 구합니다",
                "[파티] [Thrall]: can you guys wait a minute i need to repair my gear and buy some reagents first",
                "[길드] [달빛]: 네 갑니다",
                "전리품을 획득했습니다: [리넨 옷감]",
                "[공격대] [Jaina]: pull in five seconds everyone get ready and stack on the marker please",
                "[길드] [나루]: ㅇㅋ",
            ]
            let colors = [Palette.guild, Palette.party, Palette.guild, Palette.loot, Palette.raid, Palette.guild]
            for (t, c) in zip(texts, colors) {
                sim.post(t, color: c)
                run.feed(sim.frame())
            }
            flush(run, sim)
            assertSame(run.texts, texts, "indent=\(indent)")
            XCTAssertEqual(run.emitted.map(\.channel), [.guild, .party, .guild, .system, .raid, .guild])
            XCTAssertEqual(run.emitted.first?.sender, "나루")
        }
    }

    func testSystemLineAfterFullLineIsNotMergedWhenColourDiffers() {
        let sim = ChatSim(wrapColumns: 40, visible: 8)
        let run = Run()
        // Exactly fills the line, so only colour tells the loot line apart from a continuation.
        let full = "[Guild] [Thrall]: " + String(repeating: "a", count: 22)
        XCTAssertEqual(TextFold.columns(full), 40)
        sim.post(full, color: Palette.guild)
        sim.post("You receive loot: [Linen Cloth].", color: Palette.loot)
        sim.post("[Guild] [Jaina]: ok", color: Palette.guild)
        run.feed(sim.frame())
        flush(run, sim)
        assertSame(run.texts, sim.messages)
    }

    func testChineseWrapIsJoinedWithoutSpace() {
        let sim = ChatSim(wrapColumns: 36, visible: 8)
        let run = Run()
        let text = "[Guild] [Thrall]: 今天晚上有没有人一起去打团队副本我们还缺一个坦克和两个治疗"
        sim.post(text)
        sim.post("[Guild] [Jaina]: ok")
        flush(run, sim)
        assertSame(run.texts, sim.messages)
    }

    func testHalfArrivedWrappedMessageIsNotSplit() {
        let sim = ChatSim(wrapColumns: 40, visible: 8)
        let run = Run()
        for n in 0..<3 { sim.post(sampleMessage(n)) }
        flush(run, sim)
        let long = "[Guild] [Velen]: this message is long enough to wrap and its second line is missed at first"
        sim.post(long)
        let lastLine = sim.lines.count - 1
        // OCR misses the wrapped tail in the first frame that shows the message.
        run.feed(sim.frame { index, text in index == lastLine ? nil : text })
        run.feed(sim.frame())
        flush(run, sim)
        assertSame(run.texts, sim.messages)
    }

    // Confusable glyphs, dropped punctuation, damaged brackets.
    fileprivate static func ocrNoise(_ text: String, rng: inout SplitMix64, strength: Double) -> String {
        guard Double.random(in: 0..<1, using: &rng) < strength else { return text }
        var chars = Array(text)
        let edits = Int.random(in: 1...2, using: &rng)
        for _ in 0..<edits {
            guard !chars.isEmpty else { break }
            let i = Int.random(in: 0..<chars.count, using: &rng)
            switch chars[i] {
            case "l": chars[i] = "I"
            case "I": chars[i] = "l"
            case "o": chars[i] = "0"
            case "e": chars[i] = "c"
            case "[": chars[i] = "("
            case "]": chars[i] = ")"
            case ":": chars[i] = ";"
            case ".", ",", "'": chars.remove(at: i)
            case " ": if Bool.random(using: &rng) { chars.remove(at: i) }
            case "m": chars.replaceSubrange(i...i, with: ["r", "n"])
            case "a": chars[i] = "o"
            default: break
            }
        }
        return String(chars)
    }

    /// Emitted text matches the expected stream message for message, allowing OCR damage.
    private func assertStream(_ run: Run, _ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run.emitted.count, expected.count, "emitted \(run.texts)", file: file, line: line)
        for (got, want) in zip(run.texts, expected) {
            let a = TextFold.skeleton(got), b = TextFold.skeleton(want)
            let d = TextFold.distance(a, b, limit: max(3, b.count / 4))
            XCTAssertNotNil(d, "got \"\(got)\" want \"\(want)\"", file: file, line: line)
        }
    }

    func testOCRJitterDoesNotReEmit() {
        for seed in 1...12 {
            var rng = SplitMix64(seed: UInt64(seed))
            let sim = ChatSim(wrapColumns: 46, visible: 9)
            let run = Run()
            for n in 0..<50 {
                if n % 3 != 2 { sim.post(sampleMessage(n)) }
                for _ in 0..<2 {
                    let noise = CGFloat(Int.random(in: -1...1, using: &rng))
                    run.feed(sim.frame(pixelNoise: noise) { _, text in
                        ChatTrackerTests.ocrNoise(text, rng: &rng, strength: 0.35)
                    })
                }
            }
            flush(run, sim)
            assertStream(run, sim.messages)
        }
    }

    func testDroppedLinesDoNotCauseDuplicatesOrLosses() {
        for seed in 1...12 {
            var rng = SplitMix64(seed: UInt64(seed) &* 977)
            let sim = ChatSim(wrapColumns: 46, visible: 9)
            let run = Run()
            for n in 0..<50 {
                if n % 4 != 3 { sim.post(sampleMessage(n)) }
                for _ in 0..<2 {
                    run.feed(sim.frame { _, text in
                        Double.random(in: 0..<1, using: &rng) < 0.08 ? nil : text
                    })
                }
            }
            flush(run, sim)
            XCTAssertEqual(run.texts.count, Set(run.texts).count, "duplicate in seed \(seed)")
            XCTAssertEqual(Set(run.texts), Set(sim.messages), "seed \(seed)")
        }
    }

    func testLineMissedOnFirstAppearanceIsRecovered() {
        let sim = ChatSim()
        let run = Run()
        for n in 0..<4 { sim.post(sampleMessage(n)) }
        flush(run, sim)
        sim.post("[Guild] [Jaina]: the line that OCR misses at first")
        let missed = sim.lines.count - 1
        sim.post("[Guild] [Velen]: the line below it")
        run.feed(sim.frame { index, text in index == missed ? nil : text })
        flush(run, sim, frames: 4)
        XCTAssertEqual(run.texts.count, sim.messages.count)
        XCTAssertEqual(Set(run.texts), Set(sim.messages))
    }

    func testFadeToEmptyAndBack() {
        let sim = ChatSim()
        let run = Run()
        for n in 0..<12 {
            sim.post(sampleMessage(n))
            run.feed(sim.frame())
        }
        flush(run, sim)
        let before = run.texts
        XCTAssertEqual(before, sim.messages)
        // Lines fade from the top, then everything is gone, then the mouse brings it all back.
        for keep in stride(from: 6, through: 1, by: -2) { run.feed(sim.frame(onlyLast: keep)) }
        for _ in 0..<5 { run.feed(OCRFrame(lines: [], imageSize: sim.imageSize)) }
        flush(run, sim, frames: 4)
        assertSame(run.texts, before)
        // New chat after the fade: only the newest line is visible.
        sim.post(sampleMessage(12))
        run.feed(sim.frame(onlyLast: 1))
        run.feed(sim.frame(onlyLast: 1))
        run.feed(OCRFrame(lines: [], imageSize: sim.imageSize))
        flush(run, sim)
        assertSame(run.texts, sim.messages)
    }

    func testPendingBottomMessageSurvivesImmediateFade() {
        let sim = ChatSim()
        let run = Run()
        for n in 0..<3 { sim.post(sampleMessage(n)) }
        flush(run, sim)
        sim.post(sampleMessage(3))
        run.feed(sim.frame())
        run.feed(OCRFrame(lines: [], imageSize: sim.imageSize))
        assertSame(run.texts, sim.messages)
        flush(run, sim)
        assertSame(run.texts, sim.messages)
    }

    func testScrollBackAndReturn() {
        let sim = ChatSim(wrapColumns: 44, visible: 7)
        let run = Run()
        for n in 0..<40 {
            sim.post(sampleMessage(n))
            run.feed(sim.frame())
        }
        flush(run, sim)
        assertSame(run.texts, sim.messages)
        for back in [1, 3, 9, 20, 35, 20, 4, 0, 50, 2, 0] {
            run.feed(sim.frame(scrollBack: back))
            run.feed(sim.frame(scrollBack: back))
        }
        assertSame(run.texts, sim.messages)
        // Messages that arrive while scrolled back show up when the user returns to the bottom.
        sim.post(sampleMessage(40))
        sim.post(sampleMessage(41))
        run.feed(sim.frame(scrollBack: 12))
        run.feed(sim.frame(scrollBack: 12))
        XCTAssertEqual(run.texts.count, 40)
        flush(run, sim)
        assertSame(run.texts, sim.messages)
    }

    func testScrollBackRightAfterArrivalStillEmits() {
        let sim = ChatSim()
        let run = Run()
        for n in 0..<20 {
            sim.post(sampleMessage(n))
            run.feed(sim.frame())
        }
        flush(run, sim)
        sim.post(sampleMessage(20))
        run.feed(sim.frame())
        // The user scrolls up before the held line was confirmed.
        run.feed(sim.frame(scrollBack: 3))
        run.feed(sim.frame(scrollBack: 3))
        flush(run, sim)
        assertSame(run.texts, sim.messages)
    }

    func testIdenticalConsecutiveMessagesAreBothEmitted() {
        let sim = ChatSim()
        let run = Run()
        for n in 0..<5 { sim.post(sampleMessage(n)) }
        flush(run, sim)
        // Same frame.
        sim.post("[Party] [Thrall]: gg", color: Palette.party)
        sim.post("[Party] [Thrall]: gg", color: Palette.party)
        flush(run, sim)
        XCTAssertEqual(run.texts.suffix(2), ["[Party] [Thrall]: gg", "[Party] [Thrall]: gg"])
        XCTAssertEqual(run.texts.count, 7)
        // Different frames.
        sim.post("[Party] [Jaina]: gg", color: Palette.party)
        run.feed(sim.frame())
        run.feed(sim.frame())
        sim.post("[Party] [Jaina]: gg", color: Palette.party)
        run.feed(sim.frame())
        sim.post("[Party] [Jaina]: gg", color: Palette.party)
        flush(run, sim)
        assertSame(run.texts, sim.messages)
        // A different speaker with the same body is a different message.
        sim.post("[Party] [Velen]: gg", color: Palette.party)
        sim.post("[Party] [Veten]: gg", color: Palette.party)
        flush(run, sim)
        assertSame(run.texts, sim.messages)
    }

    func testCountdownLinesAreAllEmitted() {
        let sim = ChatSim()
        let run = Run()
        for n in stride(from: 5, through: 1, by: -1) {
            sim.post("[Raid Warning] [Thrall]: Pull in \(n)", color: Palette.raidWarning)
            run.feed(sim.frame())
        }
        flush(run, sim)
        assertSame(run.texts, sim.messages)
        XCTAssertTrue(run.emitted.allSatisfy { $0.channel == .raidWarning })
    }

    func testTabSwitchToDifferentContentAndBack() {
        let a = ChatSim(wrapColumns: 50, visible: 8)
        let b = ChatSim(wrapColumns: 50, visible: 8)
        let run = Run()
        for n in 0..<14 {
            a.post(sampleMessage(n))
            run.feed(a.frame())
        }
        run.feed(a.frame())
        assertSame(run.texts, a.messages)
        for n in 0..<6 { b.post("[2. Trade - City] [Garrosh]: WTS item \(wordNumber(n)) cheap", color: Palette.channel) }
        run.feed(b.frame()); run.feed(b.frame()); run.feed(b.frame())
        XCTAssertEqual(run.texts, a.messages + b.messages)
        XCTAssertEqual(run.emitted.last?.channel, .publicChannel)
        // Back to the first tab: nothing is new.
        run.feed(a.frame()); run.feed(a.frame())
        XCTAssertEqual(run.texts.count, 20)
        // New chat on the first tab while it is visible.
        a.post(sampleMessage(14))
        run.feed(a.frame()); run.feed(a.frame())
        XCTAssertEqual(run.texts.last, a.messages.last)
        XCTAssertEqual(run.texts.count, 21)
        // Second tab again, where two lines arrived meanwhile.
        b.post("[2. Trade - City] [Velen]: LF enchanter", color: Palette.channel)
        b.post("[2. Trade - City] [Jaina]: WTB arcane crystal", color: Palette.channel)
        run.feed(b.frame()); run.feed(b.frame()); run.feed(b.frame())
        XCTAssertEqual(Array(run.texts.suffix(2)), Array(b.messages.suffix(2)))
        XCTAssertEqual(run.texts.count, 23)
        for _ in 0..<3 { run.feed(a.frame()); run.feed(b.frame()) }
        run.feed(a.frame()); run.feed(a.frame())
        XCTAssertEqual(run.texts.count, 23)
        XCTAssertEqual(run.texts.count, Set(run.texts).count)
    }

    func testTabThatRepeatsMessagesOfAnotherTab() {
        // "General" shows everything, "Guild" only guild chat: the same lines, differently interleaved.
        let all = ChatSim(wrapColumns: 50, visible: 10)
        let guild = ChatSim(wrapColumns: 50, visible: 10)
        let run = Run()
        func post(_ text: String, guildChat: Bool) {
            all.post(text, color: guildChat ? Palette.guild : Palette.channel)
            if guildChat { guild.post(text, color: Palette.guild) }
        }
        for n in 0..<12 {
            post(sampleMessage(n), guildChat: true)
            post("[1. General - Durotar] [Garrosh]: noise \(wordNumber(n))", guildChat: false)
            run.feed(all.frame())
        }
        run.feed(all.frame())
        assertSame(run.texts, all.messages)
        run.feed(guild.frame()); run.feed(guild.frame()); run.feed(guild.frame())
        assertSame(run.texts, all.messages, "guild tab repeats known messages")
        post(guildLine(3, "fresh guild line"), guildChat: true)
        run.feed(guild.frame()); run.feed(guild.frame()); run.feed(guild.frame())
        XCTAssertEqual(run.texts.count, all.messages.count)
        XCTAssertEqual(run.texts.last, all.messages.last)
        run.feed(all.frame()); run.feed(all.frame()); run.feed(all.frame())
        XCTAssertEqual(run.texts.count, all.messages.count)
    }

    func testColdStartDropsOrphanContinuationAndEmitsRest() {
        let sim = ChatSim(wrapColumns: 40, visible: 4)
        let run = Run()
        sim.post("[Guild] [Thrall]: a long message whose first line has already scrolled out of the visible window before start")
        sim.post("[Guild] [Jaina]: visible one")
        sim.post("[Guild] [Velen]: visible two")
        XCTAssertFalse(sim.lines[sim.lines.count - 4].first, "top visible line must be a continuation")
        flush(run, sim, frames: 4)
        XCTAssertEqual(run.texts, ["[Guild] [Jaina]: visible one", "[Guild] [Velen]: visible two"])
    }

    func testGarbledRereadOfBottomLineIsNotEmitted() {
        let sim = ChatSim()
        let run = Run()
        for n in 0..<6 {
            sim.post(sampleMessage(n))
            run.feed(sim.frame())
        }
        flush(run, sim)
        let bottom = sim.lines.count - 1
        var flip = false
        // Every other frame reads the bottom line as something unrecognisable.
        for _ in 0..<6 {
            flip.toggle()
            let garble = flip
            run.feed(sim.frame { index, text in
                index == bottom && garble ? "[Gul1d) (Thra11J; xq zzv wpk rrt bnm qqj" : text
            })
        }
        flush(run, sim)
        assertSame(run.texts, sim.messages)
    }

    func testLineThatFlipsBetweenTwoReadingsIsOneMessage() {
        // Real OCR reads "gg" as "88" in every other frame; the row is still the same line.
        let sim = ChatSim()
        let run = Run()
        for n in 0..<6 {
            sim.post(sampleMessage(n))
            run.feed(sim.frame())
        }
        sim.post("[Guild] [Thrall]: gg")
        let first = sim.lines.count - 1
        sim.post("[Guild] [Thrall]: gg")
        let second = sim.lines.count - 1
        var tick = 0
        func noisy(scrollBack: Int = 0) -> OCRFrame {
            tick += 1
            let t = tick
            return sim.frame(scrollBack: scrollBack) { index, text in
                (index == first && t % 2 == 0) || (index == second && t % 3 == 0) ? "[Guild] [Thrall]: 88" : text
            }
        }
        for n in 6..<14 {
            run.feed(noisy()); run.feed(noisy())
            sim.post(sampleMessage(n))
        }
        // Scrolling back to the pair, where the previous frame cannot vouch for positions.
        for back in [3, 4, 3, 5, 4, 0, 4] { run.feed(noisy(scrollBack: back)); run.feed(noisy(scrollBack: back)) }
        flush(run, sim)
        XCTAssertEqual(run.texts.count, sim.messages.count, "\(run.texts)")
        XCTAssertEqual(run.texts.filter { $0.hasSuffix(": gg") || $0.hasSuffix(": 88") }.count, 2)
    }

    func testDistrustedFirstReadIsReplacedByTheStableOne() {
        let sim = ChatSim()
        let run = Run()
        for n in 0..<5 {
            sim.post(sampleMessage(n))
            run.feed(sim.frame())
        }
        let text = "[Guild] [Anduin]: 有人一起打副本吗 我是治疗"
        sim.post(text)
        let target = sim.lines.count - 1
        var age = 0
        // OCR is unsure about this line throughout, and wrong about it in the first two frames.
        func capture() {
            age += 1
            let garbled = age <= 2
            run.feed(sim.frame(confidence: { $0 == target ? 0.3 : 1 }) { index, t in
                index == target && garbled ? "[Guild]LMA]: AJI-T?EJI xx" : t
            })
        }
        capture()
        sim.post(sampleMessage(5))
        capture(); capture()
        sim.post(sampleMessage(6))
        for _ in 0..<8 { capture() }
        XCTAssertEqual(run.texts.count, sim.messages.count, "\(run.texts)")
        XCTAssertTrue(run.texts.contains(text))
        XCTAssertFalse(run.texts.contains { $0.contains("AJI") })
    }

    func testSingleGarbageFrameIsIgnored() {
        let sim = ChatSim()
        let run = Run()
        for n in 0..<6 {
            sim.post(sampleMessage(n))
            run.feed(sim.frame())
        }
        flush(run, sim)
        // The world map covers the chat for one capture.
        let junk = ["Eastern Kingdoms", "Zone Map", "Show Quest Objectives", "Elwynn Forest"].enumerated().map { i, t in
            OCRLine(text: t, box: CGRect(x: 30, y: CGFloat(20 + i * 30), width: 160, height: 14), color: Palette.say, confidence: 0.9)
        }
        run.feed(OCRFrame(lines: junk, imageSize: sim.imageSize))
        flush(run, sim)
        assertSame(run.texts, sim.messages)
    }

    func testRewrapAfterWindowResizeDoesNotReEmit() {
        let wide = ChatSim(wrapColumns: 70, visible: 8)
        let narrow = ChatSim(wrapColumns: 34, visible: 14)
        let run = Run()
        for n in 0..<6 {
            wide.post(sampleMessage(n)); narrow.post(sampleMessage(n))
        }
        run.feed(wide.frame()); run.feed(wide.frame()); run.feed(wide.frame())
        assertSame(run.texts, wide.messages)
        run.feed(narrow.frame()); run.feed(narrow.frame()); run.feed(narrow.frame())
        assertSame(run.texts, wide.messages)
        narrow.post(sampleMessage(6))
        run.feed(narrow.frame()); run.feed(narrow.frame())
        assertSame(run.texts, narrow.messages)
    }

    func testResetForgetsEverything() {
        let sim = ChatSim()
        let run = Run()
        for n in 0..<5 { sim.post(sampleMessage(n)) }
        flush(run, sim)
        XCTAssertEqual(run.texts.count, 5)
        run.tracker.reset()
        flush(run, sim)
        XCTAssertEqual(run.texts.count, 10)
    }

    func testFramesWithoutGeometryStillTrack() {
        let run = Run()
        var log: [String] = []
        func frame() -> OCRFrame {
            OCRFrame(lines: log.suffix(6).map { OCRLine(text: $0, box: .zero, color: Palette.guild, confidence: 1) },
                     imageSize: .zero)
        }
        for n in 0..<20 {
            log.append(sampleMessage(n))
            run.feed(frame())
        }
        run.feed(frame()); run.feed(frame())
        assertSame(run.texts, log)
    }

    func testSplitBoxesOnOneRowAreOneLine() {
        let run = Run()
        let size = CGSize(width: 500, height: 100)
        func frame(split: Bool) -> OCRFrame {
            var lines = [OCRLine(text: "[Guild] [Thrall]: first line here", box: CGRect(x: 4, y: 40, width: 260, height: 14),
                                 color: Palette.guild, confidence: 1)]
            if split {
                lines.append(OCRLine(text: "[Guild] [Jaina]: left half", box: CGRect(x: 4, y: 58, width: 200, height: 14), color: Palette.guild, confidence: 1))
                lines.append(OCRLine(text: "and right half", box: CGRect(x: 230, y: 59, width: 110, height: 14), color: Palette.guild, confidence: 1))
            } else {
                lines.append(OCRLine(text: "[Guild] [Jaina]: left half and right half", box: CGRect(x: 4, y: 58, width: 336, height: 14), color: Palette.guild, confidence: 1))
            }
            return OCRFrame(lines: lines, imageSize: size)
        }
        for split in [true, false, true, true, false] { run.feed(frame(split: split)) }
        XCTAssertEqual(run.texts, ["[Guild] [Thrall]: first line here", "[Guild] [Jaina]: left half and right half"])
    }

    func testFirstSeenAndIdentity() {
        let sim = ChatSim()
        let run = Run()
        sim.post("[Guild] [Thrall]: one")
        run.feed(sim.frame())
        let t1 = run.clock
        sim.post("[Guild] [Jaina]: two")
        run.feed(sim.frame())
        flush(run, sim)
        XCTAssertEqual(run.emitted.count, 2)
        XCTAssertEqual(run.emitted[0].firstSeen, t1)
        XCTAssertNotEqual(run.emitted[0].id, run.emitted[1].id)
        XCTAssertEqual(run.emitted[0].color, Palette.guild)
    }

    func testLongSessionStaysBoundedAndFast() {
        var rng = SplitMix64(seed: 99)
        let sim = ChatSim(wrapColumns: 48, visible: 12)
        let run = Run()
        let started = Date()
        var unseen = 0
        for n in 0..<1500 {
            sim.post(sampleMessage(n), color: n % 5 == 0 ? Palette.party : Palette.guild)
            unseen += 1
            // Never let more chat pile up than the window can show next to a known line.
            if unseen >= 4 || Int.random(in: 0..<3, using: &rng) > 0 { run.feed(sim.frame()); unseen = 0 }
        }
        flush(run, sim)
        assertSame(run.texts, sim.messages)
        let perFrame = Date().timeIntervalSince(started) / Double(run.frames)
        XCTAssertLessThan(perFrame, 0.2, "average ingest time (debug build)")
    }

    func testMixedRandomScenario() {
        // Everything at once: bursts, wraps, jitter, drops, fades and scroll-back.
        for seed in 1...10 {
            var rng = SplitMix64(seed: UInt64(seed) &* 31337)
            let sim = ChatSim(wrapColumns: 44, visible: 11)
            let run = Run()
            var n = 0
            // Screen lines posted since the bottom of the log was last captured.
            var unseenLines = 0
            for step in 0..<150 {
                let burst = [0, 0, 1, 1, 1, 2, 3][Int.random(in: 0..<7, using: &rng)]
                for _ in 0..<burst {
                    let long = Int.random(in: 0..<4, using: &rng) == 0
                    let body = long ? "\(fillers[n % 16]) and also \(fillers[(n + 5) % 16]) \(wordNumber(n))" : "\(fillers[n % 16]) \(wordNumber(n))"
                    let text = guildLine(n, body)
                    let rows = ChatSim.wrap(text, columns: sim.wrapColumns).count
                    // More than the window can show next to known lines would be lost by design.
                    if unseenLines + rows > sim.visible - 3 { break }
                    sim.post(text)
                    unseenLines += rows
                    n += 1
                }
                let mode = Int.random(in: 0..<20, using: &rng)
                if mode == 0 {
                    run.feed(OCRFrame(lines: [], imageSize: sim.imageSize))
                } else if mode == 1 && step > 20 && unseenLines == 0 {
                    let back = Int.random(in: 1...15, using: &rng)
                    run.feed(sim.frame(scrollBack: back))
                    run.feed(sim.frame(scrollBack: back))
                } else {
                    run.feed(sim.frame { _, text in
                        ChatTrackerTests.ocrNoise(text, rng: &rng, strength: 0.15)
                    })
                    unseenLines = 0
                }
            }
            flush(run, sim, frames: 4)
            assertStream(run, sim.messages)
        }
    }
}

// MARK: - Repeats (reposted adverts, the same words again after a fade)

final class ChatTrackerRepeatTests: XCTestCase {
    private func empty(_ sim: ChatSim) -> OCRFrame { OCRFrame(lines: [], imageSize: sim.imageSize) }

    /// The game shows a line for about two minutes; then the window is empty.
    private func fade(_ run: Run, _ sim: ChatSim) {
        run.clock += 200
        for _ in 0..<5 { run.feed(empty(sim)) }
    }

    func testRepostedAdvertDoesNotSwallowTheLinesBetween() {
        let advert = "[4. 파티찾기] [Garrosh]: LFM Molten Core tonight 8pm server time, need 2 healers and 3 ranged dps, must have fire resist gear and know the fights, soft reserve one item, whisper me with class and spec for invite"
        let words = ["apple", "river", "candle", "window", "forest", "silver", "dragon", "harbor", "meadow", "copper",
                     "lantern", "orchid", "thunder", "pebble", "saddle", "marble", "feather", "garden", "anchor", "bridge"]
        for visible in [6, 8, 10, 12, 16] {
            for between in [1, 2] {
                var rng = SplitMix64(seed: 4242)
                let sim = ChatSim(wrapColumns: 60, visible: visible)
                let run = Run(locale: .koKR)
                func other(_ k: Int) -> String {
                    let w = (0..<5).map { _ in words[Int(rng.next() % 20)] }.joined(separator: " ")
                    return "[4. 파티찾기] [Player\(["A", "B", "C", "D", "E", "F", "G"][k % 7])\(["x", "y", "z", "q"][k % 4])]: \(w) \(k)"
                }
                func post(_ text: String) {
                    sim.post(text, color: Palette.channel)
                    run.feed(sim.frame()); run.feed(sim.frame())
                }
                for k in 0..<6 { post(other(100 + k)) }
                for round in 0..<15 {
                    post(advert)
                    for j in 0..<between { post(other(round * 10 + j)) }
                }
                for _ in 0..<8 { run.feed(sim.frame()) }
                assertSame(run.texts, sim.messages, "visible \(visible), \(between) between:")
            }
        }
    }

    func testRepostedAdvertWithNoisyOCR() {
        let advert = "[4. 파티찾기] [Garrosh]: LFM Molten Core tonight 8pm server time, need 2 healers and 3 ranged dps, must have fire resist gear and know the fights"
        var rng = SplitMix64(seed: 77)
        let sim = ChatSim(wrapColumns: 60, visible: 8)
        let run = Run(locale: .koKR)
        func post(_ text: String) {
            sim.post(text, color: Palette.channel)
            for _ in 0..<2 {
                run.feed(sim.frame { _, text in ChatTrackerTests.ocrNoise(text, rng: &rng, strength: 0.1) })
            }
        }
        for n in 0..<6 { post("[4. 파티찾기] [Velen]: \(fillers[n]) \(wordNumber(n))") }
        for round in 0..<10 {
            post(advert)
            post("[4. 파티찾기] [Jaina]: \(fillers[(round + 6) % 16]) \(wordNumber(50 + round))")
        }
        for _ in 0..<6 { run.feed(sim.frame()) }
        let others = sim.messages.filter { $0 != advert }
        for text in others {
            XCTAssertEqual(run.emitted.filter { LineSimilarity.compare(LineKey(text: $0.rawText, parsed: ChatLineParser.parse($0.rawText, locale: .koKR, color: nil)),
                                                                       LineKey(text: text, parsed: ChatLineParser.parse(text, locale: .koKR, color: nil))).isStrict }.count,
                           1, text)
        }
    }

    func testSameWordsAgainAfterFadeAreANewMessage() {
        // Said much earlier in the session.
        do {
            let sim = ChatSim(); let run = Run()
            sim.post("[Guild] [Thrall]: inv pls"); run.feed(sim.frame())
            for n in 0..<12 { sim.post(sampleMessage(n)); run.feed(sim.frame()) }
            for _ in 0..<3 { run.feed(sim.frame()) }
            fade(run, sim)
            sim.post("[Guild] [Thrall]: inv pls")
            for _ in 0..<4 { run.feed(sim.frame(onlyLast: 1)) }
            assertSame(run.texts, sim.messages, "earlier line repeated:")
        }
        // The very last thing that was said.
        do {
            let sim = ChatSim(); let run = Run()
            for n in 0..<12 { sim.post(sampleMessage(n)); run.feed(sim.frame()) }
            sim.post("[Guild] [Thrall]: gg"); for _ in 0..<3 { run.feed(sim.frame()) }
            fade(run, sim)
            sim.post("[Guild] [Thrall]: gg")
            for _ in 0..<4 { run.feed(sim.frame(onlyLast: 1)) }
            assertSame(run.texts, sim.messages, "last line repeated:")
            // A unique line under it, then the mouse brings the whole window back: nothing more.
            sim.post(sampleMessage(40))
            run.feed(sim.frame(onlyLast: 2)); run.feed(sim.frame(onlyLast: 2))
            for _ in 0..<3 { run.feed(sim.frame()) }
            assertSame(run.texts, sim.messages, "after the window returned:")
        }
        // Nearly the same words.
        do {
            let sim = ChatSim(); let run = Run()
            sim.post("[Guild] [Thrall]: anyone for strat live? need 2 more"); run.feed(sim.frame())
            for n in 0..<20 { sim.post(sampleMessage(n)); run.feed(sim.frame()) }
            for _ in 0..<3 { run.feed(sim.frame()) }
            fade(run, sim)
            sim.post("[Guild] [Thrall]: anyone for strat live? need 1 more")
            for _ in 0..<4 { run.feed(sim.frame(onlyLast: 1)) }
            assertSame(run.texts, sim.messages, "similar line:")
        }
        // A whisper window that has only ever shown this one line.
        do {
            let sim = ChatSim(); let run = Run()
            sim.post("[Jaina] whispers: ?", color: Palette.whisper)
            for _ in 0..<3 { run.feed(sim.frame()) }
            fade(run, sim)
            sim.post("[Jaina] whispers: ?", color: Palette.whisper)
            for _ in 0..<4 { run.feed(sim.frame(onlyLast: 1)) }
            XCTAssertEqual(run.texts.count, 2, "single-line whisper window")
        }
    }

    func testWindowReturningAfterFadeIsNotNewChat() {
        let sim = ChatSim(); let run = Run()
        for n in 0..<12 { sim.post(sampleMessage(n)); run.feed(sim.frame()) }
        for _ in 0..<3 { run.feed(sim.frame()) }
        fade(run, sim)
        // The mouse moves over the chat: one frame catches part of the fade-in, then all is back.
        run.feed(sim.frame(onlyLast: 3))
        for _ in 0..<4 { run.feed(sim.frame()) }
        assertSame(run.texts, sim.messages)
        // A window covered for a moment (map, loading screen) while two recent lines were showing.
        sim.post(sampleMessage(12)); sim.post(sampleMessage(13))
        run.feed(sim.frame(onlyLast: 2)); run.feed(sim.frame(onlyLast: 2))
        for _ in 0..<5 { run.feed(empty(sim)) }
        for _ in 0..<3 { run.feed(sim.frame(onlyLast: 2)) }
        assertSame(run.texts, sim.messages)
    }
}

// MARK: - Parser tests

final class ChatLineParserTests: XCTestCase {

    private struct Case {
        var text: String
        var channel: ChatChannel
        var label: String?
        var sender: String?
        var body: String
        var color: RGBColor?
        init(_ text: String, _ channel: ChatChannel, _ label: String?, _ sender: String?, _ body: String, color: RGBColor? = nil) {
            self.text = text; self.channel = channel; self.label = label; self.sender = sender; self.body = body; self.color = color
        }
    }

    private func check(_ cases: [Case], locale: ClientLocale, file: StaticString = #filePath, line: UInt = #line) {
        for c in cases {
            let p = ChatLineParser.parse(c.text, locale: locale, color: c.color)
            XCTAssertEqual(p.channel, c.channel, "channel of \"\(c.text)\"", file: file, line: line)
            XCTAssertEqual(p.channelLabel, c.label, "label of \"\(c.text)\"", file: file, line: line)
            XCTAssertEqual(p.sender, c.sender, "sender of \"\(c.text)\"", file: file, line: line)
            XCTAssertEqual(p.body, c.body, "body of \"\(c.text)\"", file: file, line: line)
            XCTAssertTrue(p.hasPrefix, "prefix of \"\(c.text)\"", file: file, line: line)
        }
    }

    func testEnglishFormats() {
        check([
            Case("[Guild] [Thrall]: lf1m tank", .guild, "Guild", "Thrall", "lf1m tank"),
            Case("[Officer] [Jaina]: promote him", .officer, "Officer", "Jaina", "promote him"),
            Case("[Party] [Velen]: ready?", .party, "Party", "Velen", "ready?"),
            Case("[Party Leader] [Velen]: pulling", .party, "Party Leader", "Velen", "pulling"),
            Case("[Raid] [Anduin]: buff pls", .raid, "Raid", "Anduin", "buff pls"),
            Case("[Raid Leader] [Anduin]: stack", .raid, "Raid Leader", "Anduin", "stack"),
            Case("[Raid Warning] [Anduin]: MOVE OUT", .raidWarning, "Raid Warning", "Anduin", "MOVE OUT"),
            Case("[Instance] [Garrosh]: hi all", .instance, "Instance", "Garrosh", "hi all"),
            Case("[Instance Leader] [Garrosh]: skip this", .instance, "Instance Leader", "Garrosh", "skip this"),
            Case("[Thrall] says: hello there", .say, nil, "Thrall", "hello there"),
            Case("[Thrall] yells: FOR THE HORDE", .yell, nil, "Thrall", "FOR THE HORDE"),
            Case("[Jaina] whispers: you there?", .whisper, nil, "Jaina", "you there?"),
            Case("To [Jaina]: yes, one sec", .whisper, "To", "Jaina", "yes, one sec"),
            Case("[John Smith] whispers: hi bnet", .whisper, nil, "John Smith", "hi bnet"),
            Case("To [John Smith]: hi bnet", .whisper, "To", "John Smith", "hi bnet"),
            Case("[1. General - Elwynn Forest] [Hogger]: any groups?", .publicChannel, "1. General - Elwynn Forest", "Hogger", "any groups?"),
            Case("[2. Trade - City] [Gazlowe]: WTS [Arcanite Bar] 30g", .publicChannel, "2. Trade - City", "Gazlowe", "WTS [Arcanite Bar] 30g"),
            Case("[4. LookingForGroup] [Rexxar]: LFM UBRS need healer", .publicChannel, "4. LookingForGroup", "Rexxar", "LFM UBRS need healer"),
            Case("[Guild] [Thrall-Area52]: realm name", .guild, "Guild", "Thrall", "realm name"),
            Case("[Guild] [Ñandú-Ragnaros]: hola a todos", .guild, "Guild", "Ñandú", "hola a todos"),
            Case("[Party] [Артас-Гордунни]: привет", .party, "Party", "Артас", "привет"),
            Case("[Guild] <AFK>[Thrall]: back soon", .guild, "Guild", "Thrall", "back soon"),
            Case("Hogger says: Grrrr... fresh meat!", .say, nil, "Hogger", "Grrrr... fresh meat!"),
            Case("Marshal Dughan yells: To arms!", .yell, nil, "Marshal Dughan", "To arms!"),
            Case("[G] [Thrall]: addon style tag", .guild, "G", "Thrall", "addon style tag"),
        ], locale: .enUS)
    }

    func testKoreanFormats() {
        check([
            Case("[길드] [나루]: 안녕하세요", .guild, "길드", "나루", "안녕하세요"),
            Case("[길드관리자] [나루]: 공지 확인", .officer, "길드관리자", "나루", "공지 확인"),
            Case("[파티] [Thrall]: need mana", .party, "파티", "Thrall", "need mana"),
            Case("[파티장] [Thrall]: go go", .party, "파티장", "Thrall", "go go"),
            Case("[공격대] [Jaina]: on my way", .raid, "공격대", "Jaina", "on my way"),
            Case("[공격대장] [Jaina]: wait for cd", .raid, "공격대장", "Jaina", "wait for cd"),
            Case("[공격대 경보] [Jaina]: 산개!", .raidWarning, "공격대 경보", "Jaina", "산개!"),
            Case("[인스턴스] [Velen]: hi", .instance, "인스턴스", "Velen", "hi"),
            Case("[Velen]의 말: hello", .say, nil, "Velen", "hello"),
            Case("[달빛]의 말: 반갑습니다", .say, nil, "달빛", "반갑습니다"),
            Case("[Velen]: hello", .say, nil, "Velen", "hello"),
            Case("[Velen]의 외침: HELP", .yell, nil, "Velen", "HELP"),
            Case("[Velen]의 귓속말: inv pls", .whisper, nil, "Velen", "inv pls"),
            Case("[Velen]에게 귓속말: sure", .whisper, "귓속말 보냄", "Velen", "sure"),
            Case("[Velen]님에게: sure thing", .whisper, "귓속말 보냄", "Velen", "sure thing"),
            Case("[1. 공개 - 엘윈 숲] [나루]: 파티 구해요", .publicChannel, "1. 공개 - 엘윈 숲", "나루", "파티 구해요"),
            Case("[2. 거래 - 도시] [Gazlowe]: WTS cheap mats", .publicChannel, "2. 거래 - 도시", "Gazlowe", "WTS cheap mats"),
            Case("[4. 파티찾기] [Rexxar]: LF2M strat", .publicChannel, "4. 파티찾기", "Rexxar", "LF2M strat"),
            Case("[길드] [Thrall-아즈샤라]: 서버 이름", .guild, "길드", "Thrall", "서버 이름"),
            Case("호거의 말: 크르르...", .say, nil, "호거", "크르르..."),
        ], locale: .koKR)
    }

    func testTimestamps() {
        for (text, stamp) in [("[21:04] [Guild] [Thrall]: hi", "21:04"), ("[21:04:33] [Guild] [Thrall]: hi", "21:04:33"),
                              ("21:04:33 [Guild] [Thrall]: hi", "21:04:33"), ("21:04 [Guild] [Thrall]: hi", "21:04"),
                              ("[9:04 PM] [Guild] [Thrall]: hi", "9:04 PM"), ("[오후 9:04] [Guild] [Thrall]: hi", "오후 9:04")] {
            let p = ChatLineParser.parse(text, locale: .enUS)
            XCTAssertEqual(p.timestamp, stamp, text)
            XCTAssertEqual(p.channel, .guild, text)
            XCTAssertEqual(p.sender, "Thrall", text)
            XCTAssertEqual(p.body, "hi", text)
        }
        let k = ChatLineParser.parse("[21:04] [Velen]의 귓속말: 안녕", locale: .koKR)
        XCTAssertEqual(k.channel, .whisper); XCTAssertEqual(k.sender, "Velen"); XCTAssertEqual(k.timestamp, "21:04")
        // A system line with a timestamp is still headerless, but the timestamp is reported.
        let s = ChatLineParser.parse("[21:04:10] You receive loot: [Linen Cloth].", locale: .enUS, color: Palette.loot)
        XCTAssertEqual(s.timestamp, "21:04:10"); XCTAssertEqual(s.channel, .system); XCTAssertFalse(s.hasPrefix)
        // A bare time inside a wrapped sentence is not a timestamp.
        let w = ChatLineParser.parse("20:30 server time, be there", locale: .enUS)
        XCTAssertNil(w.timestamp); XCTAssertFalse(w.hasPrefix)
        XCTAssertNil(ChatLineParser.parse("[1. General] [Thrall]: hi", locale: .enUS).timestamp)
    }

    func testOCRDamage() {
        check([
            Case("(Guild) (Thrall): hello", .guild, "Guild", "Thrall", "hello"),
            Case("IGuild] [Thrall]: hello", .guild, "Guild", "Thrall", "hello"),
            Case("[GuildJ [Thrall]: hello", .guild, "Guild", "Thrall", "hello"),
            Case("[Guild] IThrall]: hello", .guild, "Guild", "Thrall", "hello"),
            Case("[Guild] [ThrallJ: hello", .guild, "Guild", "Thrall", "hello"),
            Case("[Guild][Thrall]:hello", .guild, "Guild", "Thrall", "hello"),
            Case("[Guild] [Thrall] : hello", .guild, "Guild", "Thrall", "hello"),
            Case("[Guild] [Thrall]; hello", .guild, "Guild", "Thrall", "hello"),
            Case("[Guild] [Thrall] hello there", .guild, "Guild", "Thrall", "hello there"),
            Case("[Gui1d] [Thrall]: hello", .guild, "Guild", "Thrall", "hello"),
            Case("[Guiid] [Thrall]: hello", .guild, "Guild", "Thrall", "hello"),
            Case("[Guild [Thrall]: hello", .guild, "Guild", "Thrall", "hello"),
            Case("［Guild］ ［Thrall］： hello", .guild, "Guild", "Thrall", "hello"),
            Case("[Raid Waming] [Thrall]: run", .raidWarning, "Raid Warning", "Thrall", "run"),
            Case("[Party Leader) (Thrall}: ok", .party, "Party Leader", "Thrall", "ok"),
            Case("[Illidan] says: you are not prepared", .say, nil, "Illidan", "you are not prepared"),
            Case("[Guild] [Illidan]: prepared", .guild, "Guild", "Illidan", "prepared"),
            Case("(Thrall) whispers: hi", .whisper, nil, "Thrall", "hi"),
            Case("[l. General - Elwynn Forest] [Thrall]: hi", .publicChannel, "l. General - Elwynn Forest", "Thrall", "hi"),
            Case("(2. Trade - City) [Thrall]: wts", .publicChannel, "2. Trade - City", "Thrall", "wts"),
            Case("To (Jaina): omw", .whisper, "To", "Jaina", "omw"),
            // Reads taken from real OCR output.
            Case("¿ [Varian] whispers: can u tank BRD?", .whisper, nil, "Varian", "can u tank BRD?"),
            Case("[Guild [Thrall] need 1 more dps", .guild, "Guild", "Thrall", "need 1 more dps"),
            Case("PParty][Anduin] omw 2 min", .party, "Party", "Anduin", "omw 2 min"),
            Case("[Guild] CJainal: WTS stuff", .guild, "Guild", "Jaina", "WTS stuff"),
            Case("[Raid] [Sywvanasj: MT on skull", .raid, "Raid", "Sywvanas", "MT on skull"),
            Case("[Raia] [Sylvanas]: MT on skull", .raid, "Raid", "Sylvanas", "MT on skull"),
            Case("[Guild]: [Thrall]: hello", .guild, "Guild", "Thrall", "hello"),
        ], locale: .enUS)
        check([
            Case("(길드) (나루): 안녕", .guild, "길드", "나루", "안녕"),
            Case("I길드] [나루]: 안녕", .guild, "길드", "나루", "안녕"),
            Case("[길드] I나루]: 안녕", .guild, "길드", "나루", "안녕"),
            Case("[길드][나루]:안녕", .guild, "길드", "나루", "안녕"),
            Case("【길드】 【나루】： 안녕", .guild, "길드", "나루", "안녕"),
            Case("[공격대경보] [Jaina]: 산개", .raidWarning, "공격대 경보", "Jaina", "산개"),
            Case("[공격대 겅보] [Jaina]: 산개", .raidWarning, "공격대 경보", "Jaina", "산개"),
            Case("[Velen]의말: hello", .say, nil, "Velen", "hello"),
            Case("[Velen] 의 귓속말: hello", .whisper, nil, "Velen", "hello"),
            Case("(Velen)의 귓속말 : hello", .whisper, nil, "Velen", "hello"),
            Case("[Velen]의 귓숙말: hello", .whisper, nil, "Velen", "hello"),
            Case("[길드] [Velen] hello", .guild, "길드", "Velen", "hello"),
            // Reads taken from real OCR output.
            Case("[킬드] [小明]: 有人一起打副本吗", .guild, "길드", "小明", "有人一起打副本吗"),
            Case("[일드] [Thrall]: need 1 more dps", .guild, "길드", "Thrall", "need 1 more dps"),
            Case("[파트] [Anduin]: omw", .party, "파티", "Anduin", "omw"),
            Case("[길드] tPedroj: Laguien para mazmorras?", .guild, "길드", "Pedro", "Laguien para mazmorras?"),
            Case("[길드] [Pedrol: Lalguien para", .guild, "길드", "Pedrol", "Lalguien para"),
            Case("[길드]「小明」有人一起打副本吗", .guild, "길드", "小明", "有人一起打副本吗"),
            Case("[. 일반] [Joao]: alguem pode", .publicChannel, ". 일반", "Joao", "alguem pode"),
            Case("[Varian]님의 치속말: can u tank", .whisper, nil, "Varian", "can u tank"),
        ], locale: .koKR)
    }

    func testColourIsOnlyASecondarySignal() {
        // Unreadable tag: colour decides.
        var p = ChatLineParser.parse("[Gxzqd] [Thrall]: hello", locale: .enUS, color: Palette.guild)
        XCTAssertEqual(p.channel, .guild); XCTAssertEqual(p.sender, "Thrall"); XCTAssertEqual(p.body, "hello")
        p = ChatLineParser.parse("[Pxqqy] [Thrall]: hello", locale: .enUS, color: Palette.party)
        XCTAssertEqual(p.channel, .party)
        // Unreadable tag with a damaged name, as real OCR produces on a busy background.
        p = ChatLineParser.parse("Г2Е] [Иван]: привет всем", locale: .koKR, color: Palette.guild)
        XCTAssertEqual(p.channel, .guild); XCTAssertEqual(p.sender, "Иван"); XCTAssertEqual(p.body, "привет всем")
        p = ChatLineParser.parse("[三] [さくら]: こんにちは", locale: .koKR, color: Palette.guild)
        XCTAssertEqual(p.channel, .guild); XCTAssertEqual(p.sender, "さくら")
        // A speech header too damaged to read: colour tells yell from say.
        p = ChatLineParser.parse("[Garroshje]의 의점: LF2M UBRS", locale: .koKR, color: Palette.yell)
        XCTAssertEqual(p.channel, .yell); XCTAssertEqual(p.sender, "Garroshje"); XCTAssertEqual(p.body, "LF2M UBRS")
        p = ChatLineParser.parse("[???] [Thrall]: hello", locale: .enUS, color: nil)
        XCTAssertEqual(p.channel, .unknown); XCTAssertEqual(p.sender, "Thrall")
        // Readable tag: colour is ignored.
        p = ChatLineParser.parse("[Guild] [Thrall]: hello", locale: .enUS, color: Palette.raid)
        XCTAssertEqual(p.channel, .guild)
        p = ChatLineParser.parse("[Thrall] yells: hello", locale: .enUS, color: Palette.guild)
        XCTAssertEqual(p.channel, .yell)
        // Bare "[Name]:" is /say unless the colour clearly says otherwise.
        p = ChatLineParser.parse("[Thrall]: hello", locale: .koKR, color: Palette.say)
        XCTAssertEqual(p.channel, .say)
        p = ChatLineParser.parse("[Thrall]: hello", locale: .koKR, color: Palette.whisper)
        XCTAssertEqual(p.channel, .whisper)
        // No speaker at all.
        p = ChatLineParser.parse("You receive loot: [Linen Cloth]x2.", locale: .enUS, color: Palette.loot)
        XCTAssertEqual(p.channel, .system); XCTAssertNil(p.sender); XCTAssertFalse(p.hasPrefix)
        p = ChatLineParser.parse("Experience gained: 120.", locale: .enUS, color: RGBColor(r: 0.44, g: 0.44, b: 1))
        XCTAssertEqual(p.channel, .system)
        p = ChatLineParser.parse("Thrall has come online.", locale: .enUS, color: Palette.system)
        XCTAssertEqual(p.channel, .system); XCTAssertNil(p.sender)
        p = ChatLineParser.parse("Thrall waves at you.", locale: .enUS, color: Palette.emote)
        XCTAssertEqual(p.channel, .emote); XCTAssertEqual(p.sender, "Thrall"); XCTAssertEqual(p.body, "Thrall waves at you.")
        p = ChatLineParser.parse("나루님이 손을 흔듭니다.", locale: .koKR, color: Palette.emote)
        XCTAssertEqual(p.channel, .emote); XCTAssertEqual(p.sender, "나루")
        p = ChatLineParser.parse("and then we wipe again lol", locale: .enUS, color: Palette.guild)
        XCTAssertEqual(p.channel, .unknown); XCTAssertFalse(p.hasPrefix)
    }

    func testThingsThatAreNotHeaders() {
        for text in ["[Thunderfury, Blessed Blade of the Windseeker] anyone?", "Guild meeting at 8: be there",
                     "note: bring pots", "LF2M: tank and healer", "he said (lol) ok", "[Linen Cloth]x2 and [Wool Cloth]",
                     "to be honest: no", "(sorry) afk a sec", "I think so: yes", "ps: thanks"] {
            let p = ChatLineParser.parse(text, locale: .enUS)
            XCTAssertFalse(p.hasPrefix, text)
            XCTAssertEqual(p.body, text)
        }
        // A wrapped sentence that reads like "Name says:" is given away by its colour.
        XCTAssertFalse(ChatLineParser.parse("He says: no way", locale: .enUS, color: Palette.guild).hasPrefix)
        XCTAssertTrue(ChatLineParser.parse("Hogger says: no way", locale: .enUS, color: Palette.say).hasPrefix)
    }

    func testColourTable() {
        XCTAssertEqual(ChatColors.channel(for: Palette.say), .say)
        XCTAssertEqual(ChatColors.channel(for: Palette.yell), .yell)
        XCTAssertEqual(ChatColors.channel(for: Palette.party), .party)
        XCTAssertEqual(ChatColors.channel(for: Palette.raid), .raid)
        XCTAssertEqual(ChatColors.channel(for: Palette.raidWarning), .raidWarning)
        XCTAssertEqual(ChatColors.channel(for: Palette.guild), .guild)
        XCTAssertEqual(ChatColors.channel(for: Palette.officer), .officer)
        XCTAssertEqual(ChatColors.channel(for: Palette.whisper), .whisper)
        XCTAssertEqual(ChatColors.channel(for: Palette.channel), .publicChannel)
        XCTAssertEqual(ChatColors.channel(for: Palette.system), .system)
        XCTAssertEqual(ChatColors.channel(for: Palette.emote), .emote)
        XCTAssertEqual(ChatColors.channel(for: Palette.loot), .system)
        // Slightly off, as sampled from anti-aliased glyphs.
        XCTAssertEqual(ChatColors.channel(for: RGBColor(r: 0.3, g: 0.93, b: 0.28)), .guild)
        XCTAssertEqual(ChatColors.channel(for: RGBColor(r: 0.9, g: 0.47, b: 0.88)), .whisper)
        XCTAssertNil(ChatColors.channel(for: RGBColor(r: 0.05, g: 0.05, b: 0.05)))
        XCTAssertNil(ChatColors.channel(for: RGBColor(r: 0.64, g: 0.21, b: 0.93)))   // epic item link
    }
}

// MARK: - Similarity tests

final class LineSimilarityTests: XCTestCase {
    private func key(_ text: String) -> LineKey {
        LineKey(text: text, parsed: ChatLineParser.parse(text, locale: .enUS))
    }

    func testSameLineReadDifferently() {
        XCTAssertTrue(LineSimilarity.compare(key("[Guild] [Thrall]: hello everyone"), key("[Guild] [Thrall]: hello everyone")).isStrict)
        XCTAssertTrue(LineSimilarity.compare(key("[Guild] [Thrall]: hello everyone"), key("(Guild) [ThraIl]: he1lo everyone")).isStrict)
        XCTAssertTrue(LineSimilarity.compare(key("[Guild] [Thrall]: it's fine, ok."), key("[Guild] [Thrall]: its fine ok")).isStrict)
        XCTAssertTrue(LineSimilarity.compare(key("[Guild] [Thrall]: 안녕하세요 반갑습니다"), key("[Guild] [Thrall]: 안넝하세요 반갑습니다")).isStrict)
        XCTAssertTrue(LineSimilarity.compare(key("and the rest of the wrapped line"), key("and the rest of the wrapped Iine")).isStrict)
    }

    func testDifferentLines() {
        XCTAssertEqual(LineSimilarity.compare(key("[Party] [Ann]: ok"), key("[Party] [Bob]: ok")), .none)
        XCTAssertEqual(LineSimilarity.compare(key("[Party] [Thrall]: gg"), key("[Party] [Thrall]: go")), .none)
        XCTAssertEqual(LineSimilarity.compare(key("[Party] [Thrall]: ?"), key("[Party] [Thrall]: ??")), .none)
        XCTAssertEqual(LineSimilarity.compare(key("[Party] [Thrall]: ..."), key("[Party] [Thrall]: ^^")), .none)
        XCTAssertEqual(LineSimilarity.compare(key("[Party] [Thrall]: ok"), key("[Raid] [Thrall]: ok")), .none)
        XCTAssertFalse(LineSimilarity.compare(key("[Raid] [Thrall]: Pull in 5"), key("[Raid] [Thrall]: Pull in 4")).isStrict)
        XCTAssertEqual(LineSimilarity.compare(key("[Guild] [Thrall]: selling flasks"), key("[Guild] [Thrall]: where is the stone")), .none)
    }
}

// MARK: - LanguageGate tests

final class LanguageGateTests: XCTestCase {

    func testKoreanReaderNeedsTranslation() {
        for text in [
            "lf1m tank for ubrs pst", "can you invite me please", "hello", "thanks for the run guys",
            "WTS [Arcanite Bar] 30g each", "hola, alguien para mazmorra?", "alguém quer fazer masmorra hoje?",
            "привет всем, кто идет в рейд", "有人一起打副本吗", "今晩レイド行きますか", "こんにちは",
            "inv", "omw", "ㅇㅇ lf tank for ubrs pst", "need 탱커 and healer for scholo run now",
            "wait for me", "don't pull yet", "LFM MC need 2 healers", "Γειά σου φίλε",
            "ty for the run", "gg that was close",
        ] {
            XCTAssertTrue(LanguageGate.needsTranslation(text, reader: .korean), text)
        }
    }

    func testKoreanReaderDoesNotNeedTranslation() {
        for text in [
            "안녕하세요", "오늘 MC 가실분 DPS 2명", "ICC 25 heroic 가실분", "ㅋㅋ", "ㅋㅋㅋㅋㅋㅋ", "ㄱㄱ", "ㅇㅇ", "ㅎㅇ",
            "gg", "GG", "ggwp", "gz", "lol", "looool", "LMAO", "haha", "hahahaha", "xD", "XD", ":D", ":P", "^^", "T_T",
            "o.o", ">.<", "?", "???", "!!!", "1", "123", "+1", "10/10", "50g", "...", "",
            "[Thunderfury, Blessed Blade of the Windseeker]", "[Arcanite Bar]x20", "[우레폭풍 - 바람추적자의 성검]",
            "{star} {skull}", "ok", "kk", "k", "o7", "zzz", "hmm", "¯\\_(ツ)_/¯", "탱커 구합니다 UBRS", "버프 plz",
            "https://discord.gg/abcdef", "y", "n", "w", "ㅋㅋ gg", "수고하셨습니다 gg",
        ] {
            XCTAssertFalse(LanguageGate.needsTranslation(text, reader: .korean), text)
        }
    }

    func testEnglishReader() {
        for text in ["안녕하세요", "탱커 구합니다 UBRS", "ㅋㅋ", "ㄱㄱ", "привет всем", "有人吗", "こんにちは", "네", "gg 수고", "好"] {
            XCTAssertTrue(LanguageGate.needsTranslation(text, reader: .english), text)
        }
        for text in ["hello there", "gg", "lol", "hola amigos", "alguém quer fazer masmorra?", "1", "?", "",
                     "[Thunderfury, Blessed Blade of the Windseeker]", "[우레폭풍 - 바람추적자의 성검]", "WTS [Arcanite Bar]",
                     ":D", "ㅋ", "¯\\_(ツ)_/¯"] {
            XCTAssertFalse(LanguageGate.needsTranslation(text, reader: .english), text)
        }
    }
}
