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
    /// The messages as the app lists them: a message that stands in for earlier ones (see
    /// `ChatTracker.corrections`) has taken the place of the first of them.
    var emitted: [ChatMessage] = []
    var clock = Date(timeIntervalSince1970: 1_700_000_000)
    /// Number of the ingest (1-based) in which each message came out.
    var emittedAt: [Int] = []
    /// Everything the tracker handed out, in order, with the ingest it came out in.
    var everything: [(message: ChatMessage, frame: Int)] = []
    var frames = 0

    init(locale: ClientLocale = .enUS) { tracker = ChatTracker(clientLocale: locale) }

    @discardableResult
    func feed(_ frame: OCRFrame) -> [ChatMessage] {
        clock += 0.7
        frames += 1
        let out = tracker.ingest(frame, now: clock)
        let corrections = tracker.corrections
        for message in out {
            everything.append((message, frames))
            let places = (corrections[message.id] ?? []).compactMap { id in emitted.firstIndex { $0.id == id } }.sorted()
            guard let first = places.first else {
                emitted.append(message)
                emittedAt.append(frames)
                continue
            }
            emitted[first] = message
            emittedAt[first] = frames
            for index in places.dropFirst().reversed() {
                emitted.remove(at: index)
                emittedAt.remove(at: index)
            }
        }
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

// MARK: - Real window layout

/// Hand-placed OCR frames with the proportions of the real game window on a Retina display:
/// rows 42 px apart, header rows starting at x = 78, wrapped rows 18 px to their right (about
/// 0.44 line heights), chat text ending near x = 870 in a region 960 px wide.
private enum Layout {
    static let size = CGSize(width: 960, height: 520)
    static let headerX: CGFloat = 78
    static let wrappedX: CGFloat = 96
    static let pitch: CGFloat = 42

    static let nameplate = RGBColor(r: 0.04, g: 0.92, b: 0.04)
    static let tabGold = RGBColor(r: 1, g: 0.82, b: 0)
    static let className = RGBColor(r: 0.31, g: 0.77, b: 0.89)
    static let npcSay = RGBColor(r: 1, g: 1, b: 0.62)

    /// `row` counts from the top of the region; `x` nil puts the line on the header column
    /// when it starts with "[" and on the column of wrapped rows otherwise.
    static func line(_ row: Int, _ text: String, _ color: RGBColor = Palette.channel, x: CGFloat? = nil,
                     width: CGFloat? = nil, height: CGFloat = 40, confidence: Double = 1) -> OCRLine {
        let left = x ?? (text.hasPrefix("[") ? headerX : wrappedX)
        let w = width ?? min(CGFloat(TextFold.columns(text)) * 17, 870 - left)
        return OCRLine(text: text, box: CGRect(x: left, y: 20 + CGFloat(row) * pitch, width: w, height: height),
                       color: color, confidence: confidence)
    }

    static func frame(_ lines: [OCRLine]) -> OCRFrame { OCRFrame(lines: lines, imageSize: size) }

    static let advert = [
        "<The Example Guild> and we rule! Recruiting",
        "all for Leveling, Dungeoning, WPvP, and",
        "Raiding. We are currently building our 20 man",
        "Roster for December raids. Shoot us a message",
        "for an invite!",
    ]
    static let advertBody = "We're " + advert.joined(separator: " ")
}

final class ChatTrackerLayoutTests: XCTestCase {

    private func settle(_ run: Run, _ frame: OCRFrame, frames: Int = 4) {
        for _ in 0..<frames { run.feed(frame) }
    }

    /// Two settled chat lines, so the tracker knows the layout before the scene starts.
    private func preamble(from row: Int) -> [OCRLine] {
        [Layout.line(row, "[1. 공개 - 도시] [Hexbloom]: anyone selling linen cloth"),
         Layout.line(row + 1, "[1. 공개 - 도시] [Quillon]: lf enchanter pst")]
    }

    /// The report from the game: the header row carries only "We're" behind a class-coloured
    /// name, so its sampled colour is the name's, not the channel's. The five wrapped rows
    /// below must still belong to it, and the tab labels that fade in above must not be chat.
    func testWrappedMessageUnderClassColouredHeaderIsOneMessage() {
        let run = Run(locale: .koKR)
        settle(run, Layout.frame(preamble(from: 9)))
        // The message arrives (the window scrolls up by six rows) while the tab labels show.
        var lines = [Layout.line(0, "일반", Layout.tabGold, x: 102, width: 44, height: 26),
                     Layout.line(0, "Trade", Layout.tabGold, x: 340, width: 72, height: 22)]
        lines += preamble(from: 3)
        lines.append(Layout.line(5, "[1. 공개 - 도시] [Brann Oakheart]: We're", Layout.className))
        lines += Layout.advert.enumerated().map { Layout.line(6 + $0.offset, $0.element) }
        settle(run, Layout.frame(lines), frames: 2)
        // The mouse moves away: the tab labels are gone, the chat stays.
        settle(run, Layout.frame(Array(lines.dropFirst(2))))

        XCTAssertEqual(run.emitted.count, 3, "\(run.texts)")
        let advert = run.emitted.last
        XCTAssertEqual(advert?.channel, .publicChannel)
        XCTAssertEqual(advert?.sender, "Brann Oakheart")
        XCTAssertEqual(advert?.body, Layout.advertBody)
        XCTAssertFalse(run.texts.contains { $0.contains("일반") || $0.contains("Trade") }, "\(run.texts)")
    }

    /// A tab label fading in alone above settled chat is not a message either, and does not
    /// disturb the message that arrives while it shows.
    func testLoneTabLabelAboveTheChatIsNotChat() {
        let run = Run(locale: .koKR)
        settle(run, Layout.frame(preamble(from: 9)))
        let tab = Layout.line(0, "일반", Layout.tabGold, x: 102, width: 44, height: 26)
        settle(run, Layout.frame([tab] + preamble(from: 9)))
        var lines = [tab] + preamble(from: 7)
        lines.append(Layout.line(9, "[1. 공개 - 도시] [Tamsin Alder]: Dps Lf", RGBColor(r: 0.69, g: 0.82, b: 0.5)))
        lines.append(Layout.line(10, "Stocks"))
        settle(run, Layout.frame(lines))
        settle(run, Layout.frame(Array(lines.dropFirst())))

        XCTAssertEqual(run.emitted.map(\.body), ["anyone selling linen cloth", "lf enchanter pst", "Dps Lf Stocks"])
        XCTAssertEqual(run.emitted.last?.sender, "Tamsin Alder")
    }

    /// Names floating over characters behind the window: read as separate boxes far to the
    /// right of the chat rows they share a baseline with, or alone on a row. None of it is
    /// chat, and the room it seems to leave at the end of every row must not split messages.
    func testWorldTextBehindTheWindowIsIgnored() {
        let run = Run(locale: .koKR)
        let plate = [Layout.line(1, "가나다 라마", Layout.nameplate, x: 775, width: 184, height: 45, confidence: 0.3),
                     Layout.line(2, "<빵 장수>", Layout.nameplate, x: 790, width: 168, height: 45)]
        var lines = preamble(from: 0) + plate
        settle(run, Layout.frame(lines))
        // More text of the world, where no chat row is.
        let strays = [Layout.line(3, "의 하수인>", Layout.nameplate, x: 500, width: 150),
                      Layout.line(4, "wn Example Club>", Layout.nameplate, x: 640, width: 260)]
        settle(run, Layout.frame(lines + strays))

        // A notice, an NPC, an emote and a wrapped advert arrive below, each with a name of
        // the world on the same row.
        lines = preamble(from: 0)
        lines.append(Layout.line(2, "규칙을 지키며 즐겁게 플레이하시기 바랍니다.", Palette.system, x: Layout.headerX))
        lines.append(Layout.line(2, "가나다 라마", Layout.nameplate, x: 775, width: 184, height: 45))
        lines.append(Layout.line(3, "토박이 상인의 말: 신선한 빵 팔아요!", Layout.npcSay, x: Layout.headerX, width: 520))
        lines.append(Layout.line(3, "Mossy Example", Layout.nameplate, x: 700, width: 230))
        lines.append(Layout.line(4, "Hexbloom님이 손을 흔듭니다.", Palette.emote, x: Layout.headerX))
        lines.append(Layout.line(5, "[1. 공개 - 도시] [Brann Oakheart]: We're", width: 560))
        lines.append(Layout.line(5, "<빵 장수>", Layout.nameplate, x: 780, width: 178, height: 45))
        lines += Layout.advert.enumerated().map { Layout.line(6 + $0.offset, $0.element) }
        settle(run, Layout.frame(lines))

        XCTAssertEqual(run.emitted.map(\.body), [
            "anyone selling linen cloth", "lf enchanter pst",
            "규칙을 지키며 즐겁게 플레이하시기 바랍니다.", "신선한 빵 팔아요!", "Hexbloom님이 손을 흔듭니다.",
            Layout.advertBody,
        ])
        XCTAssertEqual(run.emitted.map(\.channel), [.publicChannel, .publicChannel, .system, .say, .emote, .publicChannel])
        XCTAssertEqual(run.emitted[3].sender, "토박이 상인")
    }

    /// The end of the header row was read badly (text of the world over it, closing bracket
    /// taken for a letter) and with little confidence: still one message, under the full name.
    func testPollutedHeaderRowKeepsItsWrappedRows() {
        let run = Run(locale: .koKR)
        settle(run, Layout.frame(preamble(from: 9)))
        var lines = preamble(from: 3)
        lines.append(Layout.line(5, "[1. 공개 - 도시] [Brann Oakheartl: Wet", Layout.nameplate, width: 800, confidence: 0.5))
        lines += Layout.advert.enumerated().map { Layout.line(6 + $0.offset, $0.element) }
        settle(run, Layout.frame(lines), frames: 8)

        XCTAssertEqual(run.emitted.count, 3, "\(run.texts)")
        XCTAssertEqual(run.emitted.last?.sender, "Brann Oakheart")
        XCTAssertEqual(run.emitted.last?.body, "Wet " + Layout.advert.joined(separator: " "))
    }

    /// Wrapped rows are told by where they start, so a system line on the message column right
    /// under a chat line stays a line of its own, and two notices in a row stay two.
    func testHeaderlessLinesOnTheMessageColumnStartMessages() {
        let run = Run(locale: .koKR)
        var lines = preamble(from: 0)
        lines.append(Layout.line(2, "[1. 공개 - 도시] [Brann Oakheart]: We're"))
        lines += Layout.advert.prefix(2).enumerated().map { Layout.line(3 + $0.offset, $0.element) }
        lines.append(Layout.line(5, "경험치 250을 획득했습니다.", Palette.system, x: Layout.headerX))
        lines.append(Layout.line(6, "전리품을 획득했습니다: 10골드", Palette.system, x: Layout.headerX))
        lines.append(Layout.line(7, "자세한 내용은 고객 지원 페이지에서 확인하시기", Palette.system, x: Layout.headerX))
        lines.append(Layout.line(8, "바랍니다.", Palette.system))
        settle(run, Layout.frame(lines))

        XCTAssertEqual(Array(run.emitted.map(\.body).dropFirst(2)), [
            "We're " + Layout.advert.prefix(2).joined(separator: " "),
            "경험치 250을 획득했습니다.", "전리품을 획득했습니다: 10골드",
            "자세한 내용은 고객 지원 페이지에서 확인하시기 바랍니다.",
        ])
    }

    /// Cold start: a one-row message that fills its row, then a notice in another colour on
    /// the message column. Nothing is known about the wrap indent yet; the colour of a header
    /// row with a whole sentence behind it is the message's, so the notice is its own line.
    func testColouredNoticeUnderAFullHeaderRowIsItsOwnLine() {
        let bnet = RGBColor(r: 0.51, g: 0.77, b: 1)
        for notice in [bnet, Palette.guild] {
            let run = Run(locale: .koKR)
            let lines = [Layout.line(8, "[1. 공개 - 도시] [Hexbloom]: selling linen cloth and wool cloth cheap", width: 792),
                         Layout.line(9, "Example#1234 (Vexa) 님이 접속했습니다.", notice, x: Layout.headerX)]
            settle(run, Layout.frame(lines))
            settle(run, Layout.frame([]), frames: 1)
            XCTAssertEqual(run.emitted.first?.body, "selling linen cloth and wool cloth cheap", "\(run.texts)")
            XCTAssertEqual(run.emitted.first?.sender, "Hexbloom")
            XCTAssertEqual(run.emitted.count, 2, "\(run.texts)")
        }
    }

    /// System lines under short chat lines are not wrapped rows: they must not teach the
    /// tracker that this window does not indent, which would switch the indent rules off.
    func testSystemLinesUnderChatLinesDoNotHideTheIndent() {
        let run = Run(locale: .koKR)
        var lines: [OCRLine] = []
        for (n, name) in ["Hexbloom", "Quillon", "Odalys", "Vexa"].enumerated() {
            lines.append(Layout.line(2 * n, "[1. 공개 - 도시] [\(name)]: hi"))
            lines.append(Layout.line(2 * n + 1, "\(name)님이 접속했습니다.", Palette.system, x: Layout.headerX))
        }
        settle(run, Layout.frame(lines), frames: 6)
        XCTAssertEqual(run.emitted.count, 8, "\(run.texts)")

        // The window scrolls by six rows: a wrapped advert under a class-coloured header.
        var next = Array(lines.dropFirst(6)).map { l -> OCRLine in
            var m = l; m.box = m.box.offsetBy(dx: 0, dy: -6 * Layout.pitch); return m
        }
        next.append(Layout.line(2, "[1. 공개 - 도시] [Tamsin]: We're", Layout.className))
        next += Layout.advert.enumerated().map { Layout.line(3 + $0.offset, $0.element) }
        settle(run, Layout.frame(next))
        XCTAssertEqual(run.emitted.count, 9, "\(run.texts)")
        XCTAssertEqual(run.emitted.last?.sender, "Tamsin")
        XCTAssertEqual(run.emitted.last?.body, Layout.advertBody)
    }

    /// A wrapped row whose box starts well right of the wrap column (a leading icon OCR did
    /// not read, a lost first character) is still a row of its message.
    func testWrappedRowStartingLateIsKept() {
        for offset in [0.6, 0.8, 1.0, 1.3] as [CGFloat] {
            let run = Run(locale: .koKR)
            settle(run, Layout.frame(preamble(from: 9)))
            var lines = preamble(from: 6)
            lines.append(Layout.line(8, "[1. 공개 - 도시] [Odalys]: LFM for the raid tonight we need", width: 792))
            lines.append(Layout.line(9, "two healers and one tank, summons are up at", x: Layout.wrappedX + offset * 40, width: 700))
            lines.append(Layout.line(10, "the stone, whisper for an invite"))
            settle(run, Layout.frame(lines))
            XCTAssertEqual(run.emitted.last?.body,
                           "LFM for the raid tonight we need two healers and one tank, summons are up at the stone, whisper for an invite",
                           "offset \(offset): \(run.texts)")
        }
    }

    /// Cold start with only a notice in the chat and the name over a character behind the
    /// window: no header row has shown where chat starts, and the name is still not chat.
    func testWorldTextBeforeAnyHeaderRowIsNotChat() {
        let plate = [Layout.line(5, "가나다 라마", Layout.nameplate, x: 775, width: 184, height: 45),
                     Layout.line(6, "<빵 장수>", Layout.nameplate, x: 790, width: 168, height: 45)]
        let notice = [Layout.line(9, "example.com/article/12345에서 게임 내", RGBColor(r: 0.09, g: 0.64, b: 0.92)),
                      Layout.line(10, "행동 규범을 참조하시길 바랍니다.", Palette.system)]
        let scenes: [[OCRLine]] = [plate + notice, [plate[0], notice[1]], plate, [plate[0]]]
        for (n, scene) in scenes.enumerated() {
            let run = Run(locale: .koKR)
            settle(run, Layout.frame(scene), frames: 6)
            settle(run, Layout.frame([]), frames: 2)
            XCTAssertFalse(run.texts.contains { $0.contains("가나다") || $0.contains("장수") }, "scene \(n): \(run.texts)")
            if n < 2 { XCTAssertTrue(run.texts.contains { $0.contains("행동 규범") }, "scene \(n): \(run.texts)") }
        }
    }

    /// Text of the world half a row off a header row garbles the name group for a few frames
    /// (both brackets read as letters). That is the same row read badly, not a new message.
    func testGarbledRereadOfAHeaderRowIsNotANewMessage() {
        for garbled in ["[1. 공개 - 도시] lamsin Alderl: Dps Lf", "[1. 공개 - 도시] amsin Alderl: DpS Lf",
                        "[1. 공개 - 도시] Damsin Alderj: Dps Lf"] {
            let run = Run(locale: .koKR)
            var lines = preamble(from: 7)
            lines.append(Layout.line(9, "[1. 공개 - 도시] [Tamsin Alder]: Dps Lf"))
            lines.append(Layout.line(10, "Stocks"))
            settle(run, Layout.frame(lines))
            var variant = lines
            variant[2] = Layout.line(9, garbled, confidence: 0.5)
            settle(run, Layout.frame(variant))
            settle(run, Layout.frame(lines), frames: 3)
            settle(run, Layout.frame([]), frames: 2)
            XCTAssertEqual(run.emitted.map(\.body), ["anyone selling linen cloth", "lf enchanter pst", "Dps Lf Stocks"], garbled)
            XCTAssertEqual(run.emitted.last?.sender, "Tamsin Alder", garbled)
        }
    }

    /// Rows as the recogniser delivers them for a chat window with its buttons at the left
    /// edge of the captured region: (text, colour, x, y, width, height).
    private func window(_ rows: [(String, RGBColor, CGFloat, CGFloat, CGFloat, CGFloat)]) -> OCRFrame {
        OCRFrame(lines: rows.map { OCRLine(text: $0.0, box: CGRect(x: $0.2, y: $0.3, width: $0.4, height: $0.5), color: $0.1, confidence: 1) },
                 imageSize: CGSize(width: 872, height: 546))
    }

    /// The report from a real capture: the box of one header row took in a piece of the
    /// button beside the window, so it starts 30 px left of the other header rows and is half
    /// a row taller. That one row must not be taken for the step by which the window indents
    /// its wrapped rows: with a step that large no wrapped row would count as indented, and
    /// every message would fall apart into its rows.
    func testHeaderRowWhoseBoxTookInAButtonDoesNotHideTheIndent() {
        let orange = Palette.emote, pink = Palette.channel
        let frame = window([
            ("Pella Fernwhistle가 신나게 춤을 춥니다.", orange, 25, 54, 600, 40),
            ("[1. 공개 - 도시] [Brann Oakheart]: any", pink, -1, 89, 729, 58),
            ("tips for leveling a warrior without dying so", pink, 44, 142, 764, 34),
            ("much in these caves please?", pink, 44, 180, 518, 39),
            ("Tall Birch이 Garrick Stone에게 감사해 합니", orange, 25, 221, 785, 40),
            ("다.", orange, 44, 264, 44, 36),
            ("Dolmer Pike가 Garrick Stone에게 감사해 합니", orange, 30, 306, 760, 36),
            ("다.", orange, 44, 348, 44, 36),
            ("토박이 상인의 말: 말이 나왔으니 말인데, 저분이 바로 그분이에요. 믿음직하고", Layout.npcSay, 28, 388, 780, 42),
            ("용감한 분이죠. 이름은 모르겠네요.", Layout.npcSay, 44, 430, 440, 38),
        ])
        let run = Run(locale: .koKR)
        settle(run, frame, frames: 6)
        XCTAssertEqual(run.emitted.map(\.body), [
            "Pella Fernwhistle가 신나게 춤을 춥니다.",
            "any tips for leveling a warrior without dying so much in these caves please?",
            "Tall Birch이 Garrick Stone에게 감사해 합니 다.",
            "Dolmer Pike가 Garrick Stone에게 감사해 합니 다.",
            "말이 나왔으니 말인데, 저분이 바로 그분이에요. 믿음직하고 용감한 분이죠. 이름은 모르겠네요.",
        ])
        XCTAssertEqual(run.emitted.map(\.channel), [.emote, .publicChannel, .emote, .emote, .say])
        XCTAssertEqual(run.emitted[1].sender, "Brann Oakheart")
    }

    /// A button beside the window read as the first glyph of a row: the box starts at the
    /// edge of the region, far left of the message column, and is a little taller. The row is
    /// chat all the same, without that glyph.
    func testRowBehindAGlyphOfTheButtonColumnIsKept() {
        let orange = Palette.emote, pink = Palette.channel
        for glyph in [")", "d", "•)"] {
            let frame = window([
                ("\(glyph) Pella Fernwhistle가 신나게 춤을 춥니다.", orange, 0, 76, 644, 48),
                ("[1. 공개 - 도시] [Brann Oakheart]: any", pink, 48, 115, 700, 39),
                ("tips for leveling a warrior without dying so", pink, 64, 160, 766, 38),
                ("much in these caves please?", pink, 64, 202, 516, 37),
                ("Tall Birch이 Garrick Stone에게 감사해 합니", orange, 48, 240, 780, 41),
                ("다.", orange, 64, 284, 44, 36),
                ("토박이 상인의 말: 신선한 빵 팔아요!", Layout.npcSay, 48, 326, 520, 42),
            ])
            let run = Run(locale: .koKR)
            settle(run, frame, frames: 6)
            XCTAssertEqual(run.emitted.map(\.body), [
                "Pella Fernwhistle가 신나게 춤을 춥니다.",
                "any tips for leveling a warrior without dying so much in these caves please?",
                "Tall Birch이 Garrick Stone에게 감사해 합니 다.",
                "신선한 빵 팔아요!",
            ], glyph)
            XCTAssertEqual(run.emitted.first?.sender, "Pella Fernwhistle", glyph)
        }
        // Text that starts left of the chat and does not reach into its columns is still not chat.
        let stray = window([
            ("A Mossy Example", Layout.nameplate, 0, 76, 30, 40),
            ("[1. 공개 - 도시] [Brann Oakheart]: any tips for leveling", pink, 248, 115, 500, 39),
            ("[1. 공개 - 도시] [Hexbloom]: anyone selling linen cloth", pink, 248, 157, 500, 39),
        ])
        let run = Run(locale: .koKR)
        settle(run, stray, frames: 6)
        XCTAssertEqual(run.emitted.map(\.sender), ["Brann Oakheart", "Hexbloom"], "\(run.texts)")
    }

    /// Cold start on a header row OCR read with little confidence (text of the world over its
    /// end), with a name of the world alone on another row: the recognised channel tag still
    /// tells where messages start, so the wrapped rows stay with their message.
    func testDoubtfulHeaderRowStillAnchorsItsWrappedRows() {
        let run = Run(locale: .koKR)
        var lines = [Layout.line(1, "가나다 라마", Layout.nameplate, x: 775, width: 184, height: 45)]
        lines.append(Layout.line(2, "[1. 공개 - 도시] [Brann Oakheartl: Wet", Layout.nameplate, width: 800, confidence: 0.3))
        lines += Layout.advert.enumerated().map { Layout.line(3 + $0.offset, $0.element) }
        settle(run, Layout.frame(lines), frames: 8)
        settle(run, Layout.frame([]), frames: 2)
        XCTAssertEqual(run.emitted.count, 1, "\(run.texts)")
        XCTAssertEqual(run.emitted.first?.sender, "Brann Oakheart")
        XCTAssertEqual(run.emitted.first?.body, "Wet " + Layout.advert.joined(separator: " "))
    }
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

    /// Names with a space (the report: "[1. 공개 - 스톰윈드] [First Last]: ...").
    func testNamesWithSpaces() {
        check([
            Case("[1. 공개 - 도시] [Brann Oakheart]: Dps Lf", .publicChannel, "1. 공개 - 도시", "Brann Oakheart", "Dps Lf"),
            Case("[길드] [Brann Oakheart]: hello", .guild, "길드", "Brann Oakheart", "hello"),
            Case("[파티] [Brann Oakheart]: omw", .party, "파티", "Brann Oakheart", "omw"),
            Case("[4. 파티찾기] [Brann of Oakheart]: LFG", .publicChannel, "4. 파티찾기", "Brann of Oakheart", "LFG"),
            Case("[Brann Oakheart]: hello", .say, nil, "Brann Oakheart", "hello"),
            Case("[Brann Oakheart]의 말: hello", .say, nil, "Brann Oakheart", "hello"),
            Case("[Brann Oakheart]의 귓속말: hello", .whisper, nil, "Brann Oakheart", "hello"),
            // The closing bracket read as a thin letter, or lost.
            Case("[1. 공개 - 도시] [Brann Oakheartl: We're", .publicChannel, "1. 공개 - 도시", "Brann Oakheart", "We're"),
            Case("[1. 공개 - 도시] [Brann Oakheartj: We're", .publicChannel, "1. 공개 - 도시", "Brann Oakheart", "We're"),
            Case("[1. 공개 - 도시] [Brann Oakheart: We're", .publicChannel, "1. 공개 - 도시", "Brann Oakheart", "We're"),
            Case("[1. 공개 - 도시] [Brann Oakheart] We're back", .publicChannel, "1. 공개 - 도시", "Brann Oakheart", "We're back"),
        ], locale: .koKR)
        check([
            Case("[1. General - Stormwind City] [Brann Oakheart]: Dps Lf", .publicChannel, "1. General - Stormwind City", "Brann Oakheart", "Dps Lf"),
            Case("[Guild] [Brann Oakheart]: hello", .guild, "Guild", "Brann Oakheart", "hello"),
            Case("[Brann Oakheart] says: hello", .say, nil, "Brann Oakheart", "hello"),
        ], locale: .enUS)
        // A sentence in brackets is not a name, and a tag never swallows a second group.
        let p = ChatLineParser.parse("[1. 공개 - 도시] [selling this and that today]: pst", locale: .koKR)
        XCTAssertNotEqual(p.channelLabel, "1. 공개 - 도시] [selling this and that")
        for text in ["[1. 공개 - 도시] [Brann Oakheart]: x", "[Guild] [Brann Oakheart]: x"] {
            let label = ChatLineParser.parse(text, locale: .koKR).channelLabel ?? ""
            XCTAssertFalse(label.contains("]") || label.contains("["), text)
        }
    }

    /// Retail's "Trade (Services)": parentheses inside a channel tag belong to its label.
    func testChannelTagsWithParentheses() {
        check([
            Case("[2. Trade (Services) - City] [Hexbloom-Realm]: WTS mythic boost cheap", .publicChannel,
                 "2. Trade (Services) - City", "Hexbloom", "WTS mythic boost cheap"),
            Case("[2. Trade (Services) - City] [Brann Oakheart]: WTS boost", .publicChannel,
                 "2. Trade (Services) - City", "Brann Oakheart", "WTS boost"),
        ], locale: .enUS)
        check([
            Case("[2. 거래 (서비스) - 도시] [Hexbloom]: 쐐기 버스 팝니다", .publicChannel, "2. 거래 (서비스) - 도시", "Hexbloom", "쐐기 버스 팝니다"),
            Case("[2. 거래 (서비스) - 도시] [Brann Oakheartl: WTS boost", .publicChannel, "2. 거래 (서비스) - 도시", "Brann Oakheart", "WTS boost"),
        ], locale: .koKR)
    }

    /// Header rows with text of the world over them: the tag's opening bracket read as a
    /// digit, or both brackets of a two-word name read as letters.
    func testDamagedHeadersWithSpacedNames() {
        check([
            Case("11. 공개 - 도시] [Brann Oakheartl: we back", .publicChannel, "11. 공개 - 도시", "Brann Oakheart", "we back"),
            Case("[1. 공개 - 도시] Dade Oakheartj: Dps Lf", .publicChannel, "1. 공개 - 도시", "Dade Oakheart", "Dps Lf"),
            Case("[길드] Brann Oakheartl: hello there", .guild, "길드", "Brann Oakheart", "hello there"),
        ], locale: .koKR)
        // Words that are not a name are not taken for one.
        for text in ["[2. 거래 - 도시] WTS Linen Clothl: 5s", "[1. 공개 - 도시] lade Oakheartl: Dps Lf",
                     "[1. 공개 - 도시] Brann Oakheart: Dps Lf", "Brann Oakheartl: Dps Lf"] {
            let p = ChatLineParser.parse(text, locale: .koKR)
            XCTAssertFalse(p.sender?.contains(" ") ?? false, "\(text) → \(p.sender ?? "nil")")
        }
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
            Case("[길드] [Pedrol: Lalguien para", .guild, "길드", "Pedro", "Lalguien para"),
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

    /// A header row whose name group lost both brackets parses without a sender, the name
    /// becoming part of the body. It is still the same row.
    func testHeaderWithLostNameGroupIsTheSameLine() {
        func ko(_ text: String) -> LineKey { LineKey(text: text, parsed: ChatLineParser.parse(text, locale: .koKR)) }
        let clean = ko("[1. 공개 - 도시] [Tamsin Alder]: Dps Lf")
        for garbled in ["[1. 공개 - 도시] lamsin Alderl: Dps Lf", "[1. 공개 - 도시] amsin Alderl: DpS Lf"] {
            XCTAssertNil(ChatLineParser.parse(garbled, locale: .koKR).sender, garbled)
            XCTAssertNotEqual(LineSimilarity.compare(ko(garbled), clean), .none, garbled)
        }
        XCTAssertEqual(LineSimilarity.compare(ko("[1. 공개 - 도시] lamsin Alderl: Dps Lf"),
                                              ko("[1. 공개 - 도시] [Quillon]: lf enchanter pst")), .none)
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

// MARK: - Text of the world over chat rows (names over characters behind the window)

/// Frame sequences as the recogniser delivers them while a character stands or walks behind
/// the chat window: the rows its name crosses read as something else for a few frames.
final class ChatTrackerOcclusionTests: XCTestCase {
    private static let plateBlue = RGBColor(r: 0.38, g: 0.38, b: 0.86)
    private static let header = "[1. 공개 - 도시] [Brann Oakheart]: any"
    private static let rows = ["tips for leveling a warrior without dying so", "much in these caves please?"]
    private static let body = "any " + rows.joined(separator: " ")

    private func preamble(from row: Int) -> [OCRLine] {
        [Layout.line(row, "[1. 공개 - 도시] [Hexbloom]: anyone selling linen cloth"),
         Layout.line(row + 1, "[1. 공개 - 도시] [Quillon]: lf enchanter pst")]
    }

    /// Settled chat, then a three-row message arrives; `headerRow` is what its first row
    /// reads as in each successive frame (nil: the row is not read at all).
    private func play(_ headerRows: [OCRLine?], run: Run = Run(locale: .koKR)) -> Run {
        for _ in 0..<4 { run.feed(Layout.frame(preamble(from: 9))) }
        for head in headerRows {
            var lines = preamble(from: 6)
            if let head { lines.append(head) }
            lines += Self.rows.enumerated().map { Layout.line(9 + $0.offset, $0.element) }
            run.feed(Layout.frame(lines))
        }
        return run
    }

    private func clean() -> OCRLine { Layout.line(8, Self.header) }
    private func newMessages(_ run: Run) -> [ChatMessage] { Array(run.emitted.dropFirst(2)) }

    /// The report from the game, frame by frame: a name where the header row is, then the
    /// channel tag with unreadable letters behind it, then the tag and half the speaker's name
    /// followed by the name of the character behind the window, and only then the row itself.
    /// One message must come out of it: the real one.
    func testHeaderRowCoveredWhileTheMessageArrivesIsReadOnce() {
        let covered: [OCRLine?] = [
            Layout.line(8, "Vexley Thornwood", Self.plateBlue, x: 150, width: 330, height: 44),
            Layout.line(8, "Vexley Thornwood", Self.plateBlue, x: 150, width: 330, height: 44),
            Layout.line(8, "[1. 공개 - 도시] tıpsfar levaling å woryWardens>", Self.plateBlue, confidence: 0.5),
            Layout.line(8, "[1. 공개 - 도시] tıpsfar levaling å woryWardens>", Self.plateBlue, confidence: 0.5),
            Layout.line(8, "[1. 공개 - 도시] [Brann Vexley Thornwood", Self.plateBlue),
            Layout.line(8, "[1. 공개 - 도시] [Brann Vexley Thornwood", Self.plateBlue),
        ]
        let run = play(covered + [clean(), clean(), clean()])
        let new = newMessages(run)
        XCTAssertEqual(new.map(\.body), [Self.body], "\(run.texts)")
        XCTAssertEqual(new.first?.sender, "Brann Oakheart")
        XCTAssertEqual(new.first?.channel, .publicChannel)
        XCTAssertFalse(run.texts.contains { $0.contains("Vexley") || $0.contains("Wardens") || $0.contains("tıpsfar") }, "\(run.texts)")
    }

    /// The same with the garbled reads changing every frame, as they do while the character
    /// walks: none of them may be reported in the meantime.
    func testChangingMisreadsOfAHeaderRowAreNeverReported() {
        let variants = ["[1. 공개Zat통유TILAmtreeus Oakheartj: any", "[1. 공개 - 도EotwakiAlusntreeheartl: any",
                        "[1. 공개 - 도시] [Bra&orosakrReuritstany", "[1. 공개 - 도시] [Brann OaVexley: Thornwood"]
        let run = play(variants.map { Layout.line(8, $0, Self.plateBlue, confidence: 0.5) })
        XCTAssertEqual(run.emitted.count, 2, "nothing but the two settled lines so far: \(run.texts)")
        _ = play([clean(), clean()], run: Run(locale: .koKR))   // sanity: the scene itself is sound
        for _ in 0..<3 {
            var lines = preamble(from: 6)
            lines.append(clean())
            lines += Self.rows.enumerated().map { Layout.line(9 + $0.offset, $0.element) }
            run.feed(Layout.frame(lines))
        }
        XCTAssertEqual(newMessages(run).map(\.body), [Self.body], "\(run.texts)")
        XCTAssertEqual(newMessages(run).first?.sender, "Brann Oakheart")
    }

    /// The character does not move: no clean read comes. After the bounded wait the wrapped
    /// rows, which are chat for certain, go out under their channel with no speaker; whatever
    /// stands behind the tag on the header row does not. A clean read much later is the same
    /// message and is not reported again.
    func testHeaderRowThatStaysCoveredGivesOnlyItsWrappedRows() {
        let broken = Layout.line(8, "[1. 공개 - 도시] [Brann Vexley Thornwood", Self.plateBlue)
        let run = play(Array(repeating: broken, count: 10))
        let new = newMessages(run)
        XCTAssertEqual(new.count, 1, "\(run.texts)")
        XCTAssertNil(new.first?.sender)
        XCTAssertEqual(new.first?.channel, .publicChannel)
        XCTAssertEqual(new.first?.channelLabel, "1. 공개 - 도시")
        XCTAssertEqual(new.first?.body, Self.rows.joined(separator: " "))
        XCTAssertFalse(run.texts.contains { $0.contains("Vexley") || $0.contains("Thornwood") }, "\(run.texts)")
        // Bounded: first seen in frame 5, out within the wait plus the usual one frame.
        XCTAssertLessThanOrEqual(run.emittedAt.last ?? .max, 4 + ChatTracker.maxDoubtFrames + 1)

        for _ in 0..<4 {
            var lines = preamble(from: 6)
            lines.append(clean())
            lines += Self.rows.enumerated().map { Layout.line(9 + $0.offset, $0.element) }
            run.feed(Layout.frame(lines))
        }
        XCTAssertEqual(newMessages(run).count, 1, "\(run.texts)")
    }

    /// A one-row message whose header never reads cleanly has nothing that is known to be
    /// chat. Nothing of the row is passed on while the wait lasts; when it is over, a notice
    /// says that a line could not be read (and nothing of what the row read as), so the newest
    /// line is not simply missing. When the row is finally read, the message takes the
    /// notice's place: one line in the list, the real one.
    func testCoveredOneRowMessageIsHeldUntilItReadsCleanly() {
        let run = Run(locale: .koKR)
        for _ in 0..<4 { run.feed(Layout.frame(preamble(from: 9))) }
        let scene = preamble(from: 8)
        let broken = Layout.line(10, "[1. 공개 - 도시] [Tamsin Vexley Thornwood", Self.plateBlue)
        for _ in 0..<ChatTracker.maxDoubtFrames { run.feed(Layout.frame(scene + [broken])) }
        XCTAssertEqual(run.emitted.count, 2, "nothing while the wait lasts: \(run.texts)")
        for _ in 0..<4 { run.feed(Layout.frame(scene + [broken])) }
        XCTAssertEqual(run.emitted.count, 3, "\(run.texts)")
        let notice = run.emitted[2]
        XCTAssertEqual(notice.body, ChatTracker.unreadableNotice)
        XCTAssertEqual(notice.channelLabel, "1. 공개 - 도시")
        XCTAssertNil(notice.sender)
        XCTAssertNil(notice.channel.group, "a notice is never sent for translation")
        XCTAssertLessThanOrEqual(run.emittedAt[2], 4 + ChatTracker.maxDoubtFrames + 1, "within the wait")
        XCTAssertFalse(run.everything.contains { $0.message.rawText.contains("Vexley") || $0.message.rawText.contains("Tamsin") })

        for _ in 0..<3 { run.feed(Layout.frame(scene + [Layout.line(10, "[1. 공개 - 도시] [Tamsin Alder]: wtb healing potions")])) }
        XCTAssertEqual(run.emitted.count, 3, "the message stands where the notice stood: \(run.texts)")
        XCTAssertEqual(run.emitted.last?.sender, "Tamsin Alder")
        XCTAssertEqual(run.emitted.last?.body, "wtb healing potions")
        XCTAssertEqual(run.emitted.last?.channel, .publicChannel)
        XCTAssertEqual(run.everything.count, 4, "the notice, then the message once")
    }

    /// A message that was read and reported, and is covered afterwards: whatever its rows
    /// read as while covered is the same message.
    func testReportedMessageCoveredLaterIsNotReportedAgain() {
        let run = play([clean(), clean(), clean()])
        XCTAssertEqual(newMessages(run).map(\.body), [Self.body])
        let covered = ["[1. 공개 - 도시] tıpsfar levaling å woryWardens>", "[1. 공개 - 도시] [Brann Vexley Thornwood",
                       "[1. 공개 - 도시] [Brann OaVexley: Thornwood", "Vexley Thornwood"]
        for text in covered {
            for _ in 0..<3 {
                var lines = preamble(from: 6)
                lines.append(Layout.line(8, text, Self.plateBlue, x: Layout.headerX, confidence: 0.5))
                lines.append(Layout.line(9, "tips for levtlingewarWatrbtpout dying so"))
                lines.append(Layout.line(10, Self.rows[1]))
                run.feed(Layout.frame(lines))
            }
        }
        for _ in 0..<4 {
            var lines = preamble(from: 6)
            lines.append(clean())
            lines += Self.rows.enumerated().map { Layout.line(9 + $0.offset, $0.element) }
            run.feed(Layout.frame(lines))
        }
        XCTAssertEqual(run.emitted.count, 3, "\(run.texts)")
    }

    /// A guild tag crossing a wrapped row makes it read differently in every frame. The
    /// message waits for a read to repeat and goes out with that one.
    func testWrappedRowThatReadsDifferentlyEachFrameSettlesOnTheRepeatedRead() {
        let run = Run(locale: .koKR)
        for _ in 0..<4 { run.feed(Layout.frame(preamble(from: 9))) }
        let garbled = ["tipslamtene fagralarrior without dying so", "tips for levtlingewarWatrbtpout dying so",
                       "tips for leveling a warraotemuWatsodaying so", Self.rows[0], Self.rows[0], Self.rows[0]]
        for row in garbled {
            var lines = preamble(from: 6)
            lines.append(clean())
            lines.append(Layout.line(9, row))
            lines.append(Layout.line(10, Self.rows[1]))
            run.feed(Layout.frame(lines))
        }
        XCTAssertEqual(newMessages(run).map(\.body), [Self.body], "\(run.texts)")
    }

    /// Names of the world alone on a row of the chat column are not lines of chat. A system
    /// notice in the very same blue is: on a Korean client it is a Korean sentence.
    func testNamesOfTheWorldOnAChatRowAreNotChat() {
        let run = Run(locale: .koKR)
        for _ in 0..<4 { run.feed(Layout.frame(preamble(from: 5))) }
        let plates = ["Vexley Thornwood", "Dolmer Pike <Example Crew>", "<EXAMPLE>", "ern Wardens>", "vexley Thornwood"]
        for (n, plate) in plates.enumerated() {
            let line = Layout.line(7 + n % 2, plate, Self.plateBlue, x: Layout.headerX + CGFloat(n * 7), height: 44)
            for _ in 0..<3 { run.feed(Layout.frame(preamble(from: 5) + [line])) }
        }
        XCTAssertEqual(run.emitted.count, 2, "\(run.texts)")
        let notice = Layout.line(7, "단검 숙련도가 5(으)로 올랐습니다.", Self.plateBlue, x: Layout.headerX)
        for _ in 0..<3 { run.feed(Layout.frame(preamble(from: 5) + [notice])) }
        XCTAssertEqual(run.emitted.last?.body, "단검 숙련도가 5(으)로 올랐습니다.")
        XCTAssertEqual(run.emitted.last?.channel, .system)
        XCTAssertEqual(run.emitted.count, 3, "\(run.texts)")
    }

    /// A name the shape rule cannot tell from a notice (an NPC's Korean name, in the green of
    /// loot text) where the header row is: the pink rows under it are not its wrapped rows,
    /// and they come out under the header once that is read.
    func testChatRowsDoNotJoinAHeadlessLineOfAnotherColour() {
        let npc = Layout.line(8, "가나다 라마", Layout.nameplate, x: Layout.headerX, height: 44)
        let run = play([npc, npc, npc, clean(), clean(), clean()])
        XCTAssertFalse(run.texts.contains { $0.contains("가나다") && $0.contains("tips") }, "\(run.texts)")
        let chat = newMessages(run).filter { $0.channel == .publicChannel }
        XCTAssertEqual(chat.map(\.body), [Self.body], "\(run.texts)")
        XCTAssertEqual(chat.first?.sender, "Brann Oakheart")
    }

    /// The first glyph of a name behind the window read into the front of a wrapped row: the
    /// box grows taller and starts left of the column of wrapped rows. Still a wrapped row.
    func testStrayGlyphInFrontOfAWrappedRowDoesNotSplitTheMessage() {
        let run = Run(locale: .koKR)
        for _ in 0..<4 { run.feed(Layout.frame(preamble(from: 9))) }
        var lines = preamble(from: 7)
        lines.append(Layout.line(9, "토박이 상인의 말: 말이 나왔으니 말인데, 저분이 바로 그분이에요.", Layout.npcSay, x: Layout.headerX))
        lines.append(Layout.line(10, "d 용감한 분이죠. 이름은 모르겠네요.", Layout.npcSay, x: 58, height: 56))
        for _ in 0..<4 { run.feed(Layout.frame(lines)) }
        XCTAssertEqual(run.emitted.count, 3, "\(run.texts)")
        XCTAssertEqual(run.emitted.last?.sender, "토박이 상인")
        XCTAssertEqual(run.emitted.last?.body, "말이 나왔으니 말인데, 저분이 바로 그분이에요. 용감한 분이죠. 이름은 모르겠네요.")
    }

    /// The tab labels read as one piece ("General Combat Trade" with small gaps) right above
    /// the tail of a message whose header has scrolled out: neither a message of their own nor
    /// the head of that tail.
    func testTabLabelsReadAsOnePieceAreNotChat() {
        let run = Run(locale: .koKR)
        var lines = [Layout.line(0, "일반 전투 Trade", Layout.tabGold, x: 102, width: 300, height: 26)]
        lines.append(Layout.line(1, "all for Leveling, Dungeoning, WPvP, and"))
        lines.append(Layout.line(2, "Raiding. Shoot us a message for an invite!"))
        lines += preamble(from: 3)
        for _ in 0..<5 { run.feed(Layout.frame(lines)) }
        XCTAssertEqual(run.emitted.map(\.body), ["anyone selling linen cloth", "lf enchanter pst"], "\(run.texts)")
    }

    /// While one message waits for a better read, what was said after it waits too, so the
    /// order on screen is the order reported.
    func testMessagesBelowAHeldOneKeepTheirOrder() {
        let run = Run(locale: .koKR)
        for _ in 0..<4 { run.feed(Layout.frame(preamble(from: 9))) }
        func scene(_ head: OCRLine) -> OCRFrame {
            var lines = preamble(from: 5)
            lines.append(head)
            lines += Self.rows.enumerated().map { Layout.line(8 + $0.offset, $0.element) }
            lines.append(Layout.line(10, "[1. 공개 - 도시] [Tamsin Alder]: wtb healing potions"))
            return Layout.frame(lines)
        }
        for _ in 0..<2 { run.feed(scene(Layout.line(7, "[1. 공개 - 도시] [Brann Vexley Thornwood", Self.plateBlue))) }
        for _ in 0..<3 { run.feed(scene(Layout.line(7, Self.header))) }
        XCTAssertEqual(newMessages(run).map(\.body), [Self.body, "wtb healing potions"], "\(run.texts)")
    }
}

// MARK: - Rows that stay hidden, and what is said again once they read

/// A chat window of eleven rows over a growing log of screen rows, bottom-aligned like the
/// game's, read through whatever stands over some of its rows.
private final class Scroll {
    struct Row {
        var text: String
        var color: RGBColor = Palette.channel
        /// nil: on the message column when the text starts with "[", else on the column of
        /// wrapped rows.
        var x: CGFloat?
    }
    static let rows = 11
    let run = Run(locale: .koKR)
    var log: [Row] = []

    init() {
        log = ["[1. 공개 - 도시] [Hexbloom]: anyone selling linen cloth", "[1. 공개 - 도시] [Quillon]: lf enchanter pst",
               "[1. 공개 - 도시] [Mirelda]: wts copper bars cheap"].map { Row(text: $0) }
    }

    func add(_ texts: String..., color: RGBColor = Palette.channel) { log += texts.map { Row(text: $0, color: color) } }

    /// One capture with the first `count` rows of the log on screen. `reading` gets a row's
    /// place in the log, its row on screen and the line it reads as, and returns what is read
    /// there instead (nil: nothing).
    func show(_ count: Int, frames: Int = 1, reading: (Int, Int, OCRLine) -> OCRLine? = { _, _, line in line }) {
        for _ in 0..<frames {
            var lines: [OCRLine] = []
            for index in max(0, count - Self.rows)..<count {
                let screen = Self.rows - (count - index)
                let row = log[index]
                if let line = reading(index, screen, Layout.line(screen, row.text, row.color, x: row.x)) { lines.append(line) }
            }
            run.feed(Layout.frame(lines))
        }
    }

    /// What the app lists after the three lines every scene starts with.
    var said: [ChatMessage] { Array(run.emitted.dropFirst(3)) }
    var frameSaid: [Int] { Array(run.emittedAt.dropFirst(3)) }
    /// True when anything that ever went out carries one of `words`.
    func everSaid(_ words: String...) -> Bool {
        run.everything.contains { item in words.contains { item.message.rawText.contains($0) || item.message.body.contains($0) } }
    }
}

final class ChatTrackerHiddenRowTests: XCTestCase {
    private static let plateBlue = RGBColor(r: 0.38, g: 0.38, b: 0.86)
    private static let message = ["[1. 공개 - 도시] [Brann Oakheart]: any", "tips for leveling a warrior without dying so",
                                  "much in these caves please?"]
    private static let body = "any tips for leveling a warrior without dying so much in these caves please?"

    private func speaker(_ n: Int) -> String {
        "[1. 공개 - 도시] [\(["Aldric", "Bryn", "Cato", "Dessa", "Ewan", "Fira"][n])]: message number \(["one", "two", "three", "four", "five", "six"][n]) here"
    }

    /// The report: a character stands still behind the newest row of a quiet chat. Every
    /// one-row message arrives under its name and reads as a damaged header for as long as it
    /// is the newest. Each is announced by a notice within the wait, and is read once the next
    /// message has pushed it clear; the last one stays a notice. No name of the world is ever
    /// passed on.
    func testOneRowMessagesUnderANameThatStaysAreAnnouncedThenRead() {
        let scroll = Scroll()
        scroll.show(3, frames: 4)
        (0..<3).forEach { scroll.add(speaker($0)) }
        let covered: (Int, Int, OCRLine) -> OCRLine? = { index, screen, line in
            guard screen == Scroll.rows - 1 else { return line }
            let name = ["Aldr", "Bry", "Cat"][index - 3]
            return Layout.line(screen, "[1. 공개 - 도시] [\(name) Vexley Thornwood", Self.plateBlue)
        }
        scroll.show(4, frames: 8, reading: covered)
        XCTAssertEqual(scroll.said.map(\.body), [ChatTracker.unreadableNotice])
        XCTAssertLessThanOrEqual(scroll.frameSaid.first ?? .max, 4 + ChatTracker.maxDoubtFrames + 1, "the wait is bounded")
        scroll.show(5, frames: 8, reading: covered)
        XCTAssertEqual(scroll.said.map(\.body), ["message number one here", ChatTracker.unreadableNotice])
        XCTAssertEqual(scroll.said.first?.sender, "Aldric")
        scroll.show(6, frames: 8, reading: covered)
        XCTAssertEqual(scroll.said.map(\.body), ["message number one here", "message number two here", ChatTracker.unreadableNotice])
        XCTAssertEqual(scroll.said.map(\.sender), ["Aldric", "Bryn", nil])
        XCTAssertFalse(scroll.everSaid("Vexley", "Thornwood"))
        // Whoever stood there walks off: the last message is read where it is.
        scroll.show(6, frames: 3)
        XCTAssertEqual(scroll.said.map(\.sender), ["Aldric", "Bryn", "Cato"])
        XCTAssertEqual(scroll.said.last?.body, "message number three here")
    }

    /// The header row of a wrapped message reads as nothing but the name over it. The rows
    /// below are chat for certain: they go out within the wait, under the channel their
    /// colour says, with no speaker. When the header row reads, the whole message takes
    /// their place.
    func testRowsUnderAHeaderRowThatReadsAsANameComeOutWithinTheWait() {
        // The header row reads as the name alone; the same with another message below; the
        // header row is not read at all (the name and the row cancel each other out).
        for (alone, unread) in [(true, false), (false, false), (true, true), (false, true)] {
            let note = "alone \(alone), unread \(unread)"
            let scroll = Scroll()
            scroll.show(3, frames: 4)
            scroll.add(Self.message[0], Self.message[1], Self.message[2])
            if !alone { scroll.add("[1. 공개 - 도시] [Tamsin Alder]: wtb healing potions") }
            let shown = scroll.log.count
            scroll.show(shown, frames: 9) { index, screen, line in
                guard index == 3 else { return line }
                return unread ? nil : Layout.line(screen, "Vexley Thornwood", Self.plateBlue, x: 150, width: 330, height: 44)
            }
            let rows = Self.message.dropFirst().joined(separator: " ")
            XCTAssertEqual(scroll.said.first?.body, rows, "\(note): \(scroll.run.texts)")
            XCTAssertNil(scroll.said.first?.sender, note)
            XCTAssertEqual(scroll.said.first?.channel, .publicChannel, note)
            XCTAssertLessThanOrEqual(scroll.frameSaid.first ?? .max, 4 + ChatTracker.maxDoubtFrames + 1, note)
            XCTAssertEqual(scroll.said.map(\.body), alone ? [rows] : [rows, "wtb healing potions"], note)
            XCTAssertFalse(scroll.everSaid("Vexley", "Thornwood"), note)

            scroll.show(shown, frames: 3)
            XCTAssertEqual(scroll.said.first?.body, Self.body, "\(note): \(scroll.run.texts)")
            XCTAssertEqual(scroll.said.first?.sender, "Brann Oakheart", note)
            XCTAssertEqual(scroll.said.first?.channelLabel, "1. 공개 - 도시", note)
            XCTAssertEqual(scroll.said.count, alone ? 1 : 2, "nothing is listed twice, \(note): \(scroll.run.texts)")
        }
    }

    /// The same with the header row reading as a different piece of garbage in every frame,
    /// in the colour of what is drawn over it: the wait still ends.
    func testHeaderRowThatReadsDifferentlyInEveryFrameDoesNotHoldItsRowsBack() {
        let garbage = ["[1. 공개Zat통유TILAmtreeus Oakheartj: any", "[1. 공개 - 도EotwakiAlusntreeheartl: any",
                       "[1. 공개 - 도시] [Bra&orosakrReuritstany", "[1. 공개 - 도시] [Brann OaVexley: Thornwood",
                       "[1. 공개 - 도시] wirhour atesib araifeyWardens>"]
        let scroll = Scroll()
        scroll.show(3, frames: 4)
        scroll.add(Self.message[0], Self.message[1], Self.message[2])
        var frame = 0
        scroll.show(6, frames: 10) { index, screen, line in
            guard index == 3 else { return line }
            frame += 1
            return Layout.line(screen, garbage[frame % garbage.count], Self.plateBlue, confidence: 0.5)
        }
        XCTAssertEqual(scroll.said.map(\.body), [Self.message.dropFirst().joined(separator: " ")], "\(scroll.run.texts)")
        XCTAssertLessThanOrEqual(scroll.frameSaid.first ?? .max, 4 + ChatTracker.maxDoubtFrames + 1)
        XCTAssertNil(scroll.said.first?.sender)
        XCTAssertFalse(scroll.everSaid("Vexley", "Thornwood", "wirhour", "Wardens"))
        scroll.show(6, frames: 3)
        XCTAssertEqual(scroll.said.map(\.body), [Self.body])
        XCTAssertEqual(scroll.said.first?.sender, "Brann Oakheart")
    }

    /// A wrapped row that never reads the same way twice running, for longer than the wait:
    /// none of its reads is the row. The message goes out with "…" in its place, which says
    /// that something is missing and nothing that was not said; the row is put in once it
    /// reads.
    func testRowThatKeepsChangingIsLeftOutAndPutInLater() {
        let garbled = ["tips for levelVexley Thornwoodut dying so", "tips for leveling a wVexley Thornwoodg so",
                       "tips Vexley Thornwoodwarrior without dying so", "tips for leveling a warrior witVexley Thornwo"]
        let scroll = Scroll()
        scroll.show(3, frames: 4)
        scroll.add(Self.message[0], Self.message[1], Self.message[2])
        var frame = 0
        scroll.show(6, frames: 12) { index, screen, line in
            guard index == 4 else { return line }
            frame += 1
            return Layout.line(screen, garbled[frame % garbled.count], confidence: 0.6)
        }
        XCTAssertEqual(scroll.said.map(\.body), ["any … much in these caves please?"], "\(scroll.run.texts)")
        XCTAssertEqual(scroll.said.first?.sender, "Brann Oakheart")
        XCTAssertLessThanOrEqual(scroll.frameSaid.first ?? .max, 4 + ChatTracker.maxDoubtFrames + 1)
        XCTAssertFalse(scroll.everSaid("Vexley", "Thornwo"))
        scroll.show(6, frames: 3)
        XCTAssertEqual(scroll.said.map(\.body), [Self.body], "\(scroll.run.texts)")
        XCTAssertEqual(scroll.run.everything.count, 5, "three lines, the message with the gap, the message whole")
    }

    /// A name that stays over a wrapped row from the moment its message arrives: the row
    /// reads the same wrong way in every frame, under a sound header, and nothing in the text
    /// tells. OCR does: it is unsure of such a row. The message goes out as it reads (there
    /// is nothing better), and when the name has moved on and OCR reads the row with full
    /// confidence, the message takes its place. Never the other way round: a row read with
    /// confidence is not replaced by a later read OCR is unsure of.
    func testMessageReadWithDoubtIsSaidAgainOnceItIsReadForSure() {
        let scroll = Scroll()
        scroll.show(3, frames: 4)
        scroll.add(Self.message[0], Self.message[1], Self.message[2])
        let covered: (Int, Int, OCRLine) -> OCRLine? = { index, screen, line in
            index == 4 ? Layout.line(screen, "tips for leveling a wVexley Thornwoodg so", confidence: 0.5) : line
        }
        scroll.show(6, frames: 6, reading: covered)
        XCTAssertEqual(scroll.said.map(\.body), ["any tips for leveling a wVexley Thornwoodg so much in these caves please?"],
                       "nothing tells that the row is not the row yet")
        scroll.show(6, frames: 3)
        XCTAssertEqual(scroll.said.map(\.body), [Self.body], "\(scroll.run.texts)")
        XCTAssertEqual(scroll.said.first?.sender, "Brann Oakheart")
        XCTAssertEqual(scroll.run.everything.count, 5)
        // The name comes back and stays: the sure read stands.
        scroll.show(6, frames: 12, reading: covered)
        scroll.show(6, frames: 3)
        XCTAssertEqual(scroll.said.map(\.body), [Self.body])
        XCTAssertEqual(scroll.run.everything.count, 5, "\(scroll.run.everything.map(\.message.rawText))")

        // A row OCR stays unsure of and that never reads differently is reported once.
        let steady = Scroll()
        steady.show(3, frames: 4)
        steady.add(Self.message[0], Self.message[1], Self.message[2])
        steady.show(6, frames: 12) { index, _, line in
            var line = line
            if index == 4 { line.confidence = 0.5 }
            return line
        }
        XCTAssertEqual(steady.said.map(\.body), [Self.body])
        XCTAssertEqual(steady.run.everything.count, 4)
    }

    /// Chat that scrolls five rows per capture past a name that stays on one row of the
    /// screen: the message that is new on that row reads as a damaged header (or as the name
    /// alone) and is read one capture later, further up. Every message comes out once and in
    /// the order it was said; the one left under the name when the chat stops is announced.
    func testFastChatPastANameThatStaysLosesNothing() {
        let names = ["Aldric", "Bryn", "Cato", "Dessa", "Ewan", "Fira", "Garth", "Hale", "Ivo", "Jora",
                     "Kell", "Lysa", "Maro", "Nell", "Orin", "Pia", "Quen", "Rolf", "Sela", "Tov"]
        let words = ["need healer for deadmines", "selling heavy leather stacks", "anyone doing stockade run",
                     "where is the mage trainer", "looking for guild that raids", "buying wool cloth all of it",
                     "can someone open lockbox", "port to darnassus paying", "warrior lfg scarlet monastery",
                     "how do i get to ironforge", "free water at the bank", "tank lf group any dungeon",
                     "enchanter here taking tips", "who stole my kill lol", "need one more for gnomer",
                     "summon please at the stone", "wts silk cloth twenty stacks", "is the boat bugged again",
                     "rogue lf lockpick practice", "last spot for uldaman go"]
        for nameOnly in [false, true] {
            let scroll = Scroll()
            scroll.show(3, frames: 4)
            for (name, said) in zip(names, words) { scroll.add("[1. 공개 - 도시] [\(name)]: \(said)") }
            let covered: (Int, Int, OCRLine) -> OCRLine? = { _, screen, line in
                guard screen == 6 else { return line }
                return nameOnly ? Layout.line(screen, "Vexley Thornwood", Self.plateBlue, x: 200, width: 330, height: 44)
                    : Layout.line(screen, "[1. 공개 - 도시] [Vexley Thornwood <Dawn Wardens>", Self.plateBlue)
            }
            for count in [8, 13, 18, 23] { scroll.show(count, reading: covered) }
            scroll.show(23, frames: 8, reading: covered)
            // Row 6 of the last capture holds the sixteenth message.
            var expected = words
            expected[15] = ChatTracker.unreadableNotice
            XCTAssertEqual(scroll.said.map(\.body), expected, "name only \(nameOnly)")
            XCTAssertFalse(scroll.everSaid("Vexley", "Wardens"))
        }
    }

    /// Brackets of a name that OCR reads as letters, or not at all, in every frame, with
    /// nothing drawn over the row: the message is not lost. Both brackets read as "I" is a
    /// header like any other; a bracket that is simply missing makes the header a doubtful
    /// one, which waits and is then taken at its word because it never read differently.
    func testNameBracketsThatAreNeverReadDoNotLoseTheMessage() {
        let forms: [(text: String, sender: String?, body: String)] = [
            ("[1. 공개 - 도시] ISable QuillfeatherI: selling two stacks of linen", "Sable Quillfeather", "selling two stacks of linen"),
            ("[1. 공개 - 도시] [Sable Quillfeather: selling two stacks of linen", "Sable Quillfeather", "selling two stacks of linen"),
            ("[1. 공개 - 도시] Sable Quillfeather: selling two stacks of linen", nil, "Sable Quillfeather: selling two stacks of linen"),
        ]
        for form in forms {
            let scroll = Scroll()
            scroll.show(3, frames: 4)
            scroll.add(form.text)
            scroll.show(4, frames: 8)
            XCTAssertEqual(scroll.said.map(\.body), [form.body], form.text)
            XCTAssertEqual(scroll.said.first?.sender, form.sender, form.text)
            XCTAssertEqual(scroll.said.first?.channel, .publicChannel, form.text)
            XCTAssertLessThanOrEqual(scroll.frameSaid.first ?? .max, 4 + ChatTracker.maxDoubtFrames + 1, form.text)
        }
        let p = ChatLineParser.parse(forms[0].text, locale: .koKR, color: Palette.channel)
        XCTAssertFalse(p.isDamagedHeader)
        XCTAssertEqual(p.sender, "Sable Quillfeather")
        // What a name of the world leaves behind the colon is not taken for speech, however
        // long it stays: only that a line was there is said.
        for text in ["[1. 공개 - 도시] [Brann Vexley: Thornwood", "[1. 공개 - 도시] Vexley Thornwood: Dawn Wardens"] {
            let scroll = Scroll()
            scroll.show(3, frames: 4)
            scroll.add(text)
            scroll.show(4, frames: 8)
            XCTAssertEqual(scroll.said.map(\.body), [ChatTracker.unreadableNotice], text)
        }
    }

    /// Words between two brackets that do not read like a name (what OCR makes of a name with
    /// another one drawn over it, and is unsure of) are not a speaker: the header row is a
    /// damaged one.
    func testWordsBetweenBracketsThatAreNoNameAreNotASpeaker() {
        let odd = "[1. 공개 - 도시] [A Wexlay thoruwcods]: any"
        XCTAssertTrue(ChatLineParser.parse(odd, locale: .koKR, color: Palette.channel).isDamagedHeader)
        // A first letter read in the wrong case is no such evidence, nor is a small word.
        for sound in ["[1. 공개 - 도시] [Brann Oakheart]: any", "[1. 공개 - 도시] [Brann oakheart]: any", "[4. 파티찾기] [Brann of Oakheart]: LFG",
                      "[길드] [달빛 나루]: 안녕하세요", "[Brann Oakheart]님의 외침: any"] {
            XCTAssertFalse(ChatLineParser.parse(sound, locale: .koKR, color: Palette.channel).isDamagedHeader, sound)
        }
        // Read with little confidence, words that are no name are not believed either, with
        // or without such a letter; read with confidence, the same header row is a header row.
        for name in ["A Wexlay thoruwcods", "Wexlay thoruwcods"] {
            let scroll = Scroll()
            scroll.show(3, frames: 4)
            scroll.add(Self.message[0], Self.message[1], Self.message[2])
            scroll.show(6, frames: 9) { index, screen, line in
                index == 3 ? Layout.line(screen, "[1. 공개 - 도시] [\(name)]: any", confidence: 0.3) : line
            }
            XCTAssertEqual(scroll.said.map(\.sender), [nil], "\(name): \(scroll.run.texts)")
            XCTAssertEqual(scroll.said.first?.body, Self.message.dropFirst().joined(separator: " "), name)
            XCTAssertFalse(scroll.everSaid("Wexlay", "thoruwcods"), name)
        }
        let scroll = Scroll()
        scroll.show(3, frames: 4)
        scroll.add("[1. 공개 - 도시] [Brann oakheart]: any", Self.message[1], Self.message[2])
        scroll.show(6, frames: 3)
        XCTAssertEqual(scroll.said.map(\.body), [Self.body], "a clean read is not held back: \(scroll.run.texts)")
        XCTAssertLessThanOrEqual(scroll.frameSaid.first ?? .max, 6)
        // A name that really has a one-letter word, read with full confidence the same way
        // for the whole wait, is a name after all: late, but neither lost nor without speaker.
        let rare = Scroll()
        rare.show(3, frames: 4)
        rare.add("[1. 공개 - 도시] [J Oakheart]: selling two stacks of linen")
        rare.show(4, frames: 8)
        XCTAssertEqual(rare.said.map(\.body), ["selling two stacks of linen"], "\(rare.run.texts)")
        XCTAssertEqual(rare.said.first?.sender, "J Oakheart")
    }

    /// A name of the world where a row in the MIDDLE of a wrapped message is: what is read
    /// above and below it goes out as two pieces at first (the piece below with no speaker,
    /// after the wait), and as one message, whole, once the row reads.
    func testHiddenMiddleRowIsPutBackIntoItsMessage() {
        let long = ["[1. 공개 - 도시] [Brann Oakheart]: selling the whole lot of leather and", "ore that i gathered this week, prices are low",
                    "because i need the gold for a mount, whisper me", "before the evening raid starts please"]
        let scroll = Scroll()
        scroll.show(3, frames: 4)
        scroll.add(long[0], long[1], long[2], long[3])
        scroll.show(7, frames: 9) { index, screen, line in
            index == 5 ? Layout.line(screen, "Vexley Thornwood", Self.plateBlue, x: 320, width: 330, height: 44) : line
        }
        XCTAssertEqual(scroll.said.map(\.body), ["selling the whole lot of leather and ore that i gathered this week, prices are low",
                                                 "before the evening raid starts please"], "\(scroll.run.texts)")
        XCTAssertFalse(scroll.everSaid("Vexley", "Thornwood"))
        scroll.show(7, frames: 3)
        XCTAssertEqual(scroll.said.map(\.body), [long.joined(separator: " ").replacingOccurrences(of: "[1. 공개 - 도시] [Brann Oakheart]: ", with: "")],
                       "\(scroll.run.texts)")
        XCTAssertEqual(scroll.said.first?.sender, "Brann Oakheart")
    }

    /// A row that is nothing but an item link in the green of the link, its brackets read as
    /// thin letters: no name of the world, and a row of its message.
    func testGreenLinkRowWithBracketsReadAsLettersStaysInItsMessage() {
        let green = RGBColor(r: 0.11, g: 1, b: 0)
        for link in ["IMoonsteel Broadswordl", "lMoonsteel BroadswordI", "[Moonsteel Broadsword]"] {
            let scroll = Scroll()
            scroll.show(3, frames: 4)
            scroll.add("[1. 공개 - 도시] [Brann Oakheart]: LOOKING TO BUY")
            scroll.log.append(Scroll.Row(text: link, color: green, x: Layout.wrappedX))
            scroll.show(5, frames: 4)
            XCTAssertEqual(scroll.said.map(\.body), ["LOOKING TO BUY [Moonsteel Broadsword]"], link)
        }
    }

    /// One line alone on the bottom row after the chat had faded, damaged at first and read
    /// cleanly then: one message. There is no second line on screen to tell that the window
    /// did not move.
    func testLoneLineReadAgainIsOneMessage() {
        let run = Run(locale: .koKR)
        let old = [Layout.line(9, "[1. 공개 - 도시] [Hexbloom]: anyone selling linen cloth"),
                   Layout.line(10, "[1. 공개 - 도시] [Quillon]: lf enchanter pst")]
        for _ in 0..<4 { run.feed(Layout.frame(old)) }
        for _ in 0..<6 { run.feed(Layout.frame([])) }
        for _ in 0..<3 { run.feed(Layout.frame([Layout.line(10, "[1. 공개 - 도시] [Tams Vexley Thornwood", Self.plateBlue)])) }
        for _ in 0..<4 { run.feed(Layout.frame([Layout.line(10, "[1. 공개 - 도시] [Tamsin Alder]: brand new words after the fade")])) }
        XCTAssertEqual(run.everything.count, 3, "\(run.everything.map(\.message.rawText))")
        XCTAssertEqual(run.emitted.last?.sender, "Tamsin Alder")
        XCTAssertEqual(run.emitted.last?.body, "brand new words after the fade")
    }

    /// Fast chat: the header row of a wrapped message is not read at all in the one capture
    /// that shows it (the name over it and the row cancel each other out), and the next
    /// capture has the message scrolled out of view. Its rows were read once, for sure, right
    /// below known chat: they go out without a speaker instead of being lost.
    func testRowsSeenOnceUnderAnUnreadHeaderRowAreNotLost() {
        let scroll = Scroll()
        scroll.show(3, frames: 4)
        scroll.add(Self.message[0], Self.message[1], Self.message[2])
        scroll.show(6) { index, _, line in index == 3 ? nil : line }
        // Eleven one-row messages at once: a window full, and the message is gone.
        (1..<6).forEach { scroll.add(speaker($0)) }
        (0..<6).forEach { scroll.add(speaker($0).replacingOccurrences(of: "message number", with: "another line number")) }
        scroll.show(17, frames: 6)
        let rows = Self.message.dropFirst().joined(separator: " ")
        XCTAssertEqual(scroll.said.first?.body, rows, "\(scroll.run.texts)")
        XCTAssertNil(scroll.said.first?.sender)
        XCTAssertEqual(scroll.said.first?.channel, .publicChannel)
        XCTAssertEqual(scroll.said.count, 12, "the rows and the eleven lines after them: \(scroll.run.texts)")

        // Read once and not for sure, such rows prove nothing: a one-off misread is not chat.
        let unsure = Scroll()
        unsure.show(3, frames: 4)
        unsure.add(Self.message[0], Self.message[1], Self.message[2])
        unsure.show(6) { index, _, line in
            var line = line
            line.confidence = 0.5
            return index == 3 ? nil : line
        }
        (1..<6).forEach { unsure.add(speaker($0)) }
        (0..<6).forEach { unsure.add(speaker($0).replacingOccurrences(of: "message number", with: "another line number")) }
        unsure.show(17, frames: 6)
        XCTAssertEqual(unsure.said.count, 11, "\(unsure.run.texts)")
        XCTAssertFalse(unsure.everSaid("caves"))
    }
}

final class ChatCorrectionTests: XCTestCase {
    private func entry(_ body: String) -> ChatEntry {
        ChatEntry(message: ChatMessage(channel: .publicChannel, channelLabel: "1. 공개 - 도시", sender: nil, body: body,
                                       rawText: body, color: Palette.channel, firstSeen: Date(timeIntervalSince1970: 0)),
                  state: .original)
    }

    /// A line that stands in for earlier ones takes the place of the first and removes the
    /// rest; any other line goes to the end.
    func testALineThatSaysEarlierOnesAgainTakesTheirPlace() {
        var list = ["one", "two", "three", "four"].map(entry)
        let ids = list.map(\.id)
        list.place(entry("five"))
        XCTAssertEqual(list.map(\.message.body), ["one", "two", "three", "four", "five"])
        list.place(entry("two, whole"), replacing: [ids[1]])
        XCTAssertEqual(list.map(\.message.body), ["one", "two, whole", "three", "four", "five"])
        list.place(entry("three and four"), replacing: [ids[3], ids[2]])
        XCTAssertEqual(list.map(\.message.body), ["one", "two, whole", "three and four", "five"])
        // Earlier lines the list no longer holds: the new one is simply new.
        list.place(entry("six"), replacing: [ids[1], UUID()])
        XCTAssertEqual(list.map(\.message.body), ["one", "two, whole", "three and four", "five", "six"])
    }

    /// The tracker names the message a second report replaces, and only for second reports.
    func testSecondReportsNameTheMessageTheyReplace() {
        let tracker = ChatTracker(clientLocale: .koKR)
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        var out: [ChatMessage] = []
        var replaced: [UUID: [UUID]] = [:]
        func feed(_ lines: [OCRLine]) {
            clock += 0.7
            let messages = tracker.ingest(Layout.frame(lines), now: clock)
            XCTAssertTrue(Set(tracker.corrections.keys).isSubset(of: Set(messages.map(\.id))))
            replaced.merge(tracker.corrections) { _, new in new }
            out += messages
        }
        let top = [Layout.line(8, "[1. 공개 - 도시] [Hexbloom]: anyone selling linen cloth"),
                   Layout.line(9, "[1. 공개 - 도시] [Quillon]: lf enchanter pst")]
        for _ in 0..<4 { feed(top) }
        XCTAssertTrue(replaced.isEmpty)
        let blue = RGBColor(r: 0.38, g: 0.38, b: 0.86)
        for _ in 0..<8 { feed(top + [Layout.line(10, "[1. 공개 - 도시] [Tamsin Vexley Thornwood", blue)]) }
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(replaced.isEmpty, "a first report replaces nothing")
        for _ in 0..<3 { feed(top + [Layout.line(10, "[1. 공개 - 도시] [Tamsin Alder]: wtb healing potions")]) }
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(replaced, [out[3].id: [out[2].id]])
        feed(top + [Layout.line(10, "[1. 공개 - 도시] [Tamsin Alder]: wtb healing potions")])
        XCTAssertTrue(tracker.corrections.isEmpty, "only the latest capture's second reports are listed")
    }
}

// MARK: - A name read into a row for sure, and gone a moment later

final class ChatTrackerShedNameTests: XCTestCase {
    private static let message = ["[1. 공개 - 도시] [Brann Oakheart]: any", "tips for leveling a warrior without dying so",
                                  "much in these caves please?"]
    private static let body = "any tips for leveling a warrior without dying so much in these caves please?"

    /// A name stands right behind the end of a row when its message arrives, and OCR reads
    /// the two as one row, sure of every glyph: nothing tells them apart, and the message
    /// goes out with the name. Names move on and chat stays: when the row has read without
    /// the name twice running, the message is said again without it, in the same place.
    func testNameBehindTheEndOfARowIsTakenBackOnceItIsGone() {
        for tail in ["Vexley Thornwoo", "<Dawn Wardens>", "Vexley Thornwood <Dawn Wardens>"] {
            for frames in [2, 3, 10] {
                let note = "\(tail), \(frames) frames"
                let withName: (Int, Int, OCRLine) -> OCRLine? = { index, screen, line in
                    index == 5 ? Layout.line(screen, Self.message[2] + " " + tail) : line
                }
                let scroll = Scroll()
                scroll.show(3, frames: 4)
                scroll.add(Self.message[0], Self.message[1], Self.message[2])
                scroll.show(6, frames: frames, reading: withName)
                XCTAssertEqual(scroll.said.map(\.body), [Self.body + " " + tail], note)
                // One capture without the name is a glimpse, not the row.
                scroll.show(6, frames: 1)
                XCTAssertEqual(scroll.run.everything.count, 4, note)
                scroll.show(6, frames: 2, reading: withName)
                XCTAssertEqual(scroll.run.everything.count, 4, note)

                scroll.show(6, frames: 2)
                XCTAssertEqual(scroll.said.map(\.body), [Self.body], "\(note): \(scroll.run.texts)")
                XCTAssertEqual(scroll.said.first?.sender, "Brann Oakheart", note)
                XCTAssertEqual(scroll.run.everything.count, 5, "three lines, the message with the name, the message: \(note)")
                // The name comes back and leaves again: what stands is not said a third time.
                scroll.show(6, frames: 4, reading: withName)
                scroll.show(6, frames: 3)
                XCTAssertEqual(scroll.said.map(\.body), [Self.body], note)
                XCTAssertEqual(scroll.run.everything.count, 5, note)
            }
        }
    }

    /// The same on a header row: the name stands behind its few words, or where they are
    /// (and all that is read behind the colon is the name).
    func testNameReadIntoAHeaderRowIsTakenBackOnceItIsGone() {
        for covered in ["[1. 공개 - 도시] [Brann Oakheart]: any Vexley Thornwood", "[1. 공개 - 도시] [Brann Oakheart]: any <Dawn Wardens>",
                        "[1. 공개 - 도시] [Brann Oakheart]: Vexley Thornwood"] {
            let scroll = Scroll()
            scroll.show(3, frames: 4)
            scroll.add(Self.message[0], Self.message[1], Self.message[2])
            scroll.show(6, frames: 3) { index, screen, line in index == 3 ? Layout.line(screen, covered) : line }
            XCTAssertEqual(scroll.said.count, 1, covered)
            XCTAssertTrue(scroll.everSaid("Vexley", "Wardens"), "read with full confidence, the name is not told from chat: \(covered)")
            scroll.show(6, frames: 3)
            XCTAssertEqual(scroll.said.map(\.body), [Self.body], "\(covered): \(scroll.run.texts)")
            XCTAssertEqual(scroll.said.first?.sender, "Brann Oakheart", covered)
            XCTAssertEqual(scroll.run.everything.count, 5, covered)
        }
    }

    /// A message that went out, and whose row reads later as the same header with other
    /// words behind the colon (a name drawn through them), used to be listed a second time,
    /// as something its speaker said. One row of the chat is one line: nothing new goes out,
    /// whether OCR is unsure of the later read or sure of it, and the row read again as it
    /// went out is no new line either.
    func testRowReadDifferentlyUnderTheSameSpeakerIsNotAnotherMessage() {
        let row = "[1. 공개 - 도시] [Brann Oakheart]: selling two stacks of linen"
        let later: [(String, Double)] = [
            ("[1. 공개 - 도시] [Brann Oakheart]: selling tVexley Thornwoodinen", 0.5),
            ("[1. 공개 - 도시] [Brann Oakheart]: selling tVexley Thornwoodinen", 1),
            ("[1. 공개 - 도시] [Brann Oakheart]: selling two", 1),
            ("[1. 공개 - 도시] [Brann Oakheart]: selling two stacks of linen Vexley Thornwood <Dawn Wardens>", 1),
        ]
        for (covered, confidence) in later {
            let scroll = Scroll()
            scroll.show(3, frames: 4)
            scroll.add(row)
            scroll.show(4, frames: 4)
            scroll.show(4, frames: 6) { index, screen, line in
                index == 3 ? Layout.line(screen, covered, confidence: confidence) : line
            }
            scroll.show(4, frames: 5)
            XCTAssertEqual(scroll.said.map(\.body), ["selling two stacks of linen"], "\(covered) at \(confidence)")
            XCTAssertEqual(scroll.run.everything.count, 4, "\(covered) at \(confidence): \(scroll.run.everything.map(\.message.rawText))")
        }
        // Covered from the moment it arrives, in a read OCR is unsure of: what went out is
        // replaced by the sure read, not joined by it.
        let early = Scroll()
        early.show(3, frames: 4)
        early.add(row)
        early.show(4, frames: 3) { index, screen, line in
            index == 3 ? Layout.line(screen, later[0].0, confidence: 0.5) : line
        }
        XCTAssertEqual(early.said.count, 1)
        early.show(4, frames: 4)
        XCTAssertEqual(early.said.map(\.body), ["selling two stacks of linen"], "\(early.run.texts)")
        XCTAssertEqual(early.run.everything.count, 5)

        // Somebody else on that row is another line (another chat tab with the same lines
        // around it), and so is the same speaker's row read whole after a first read that
        // stopped short: nothing tells that one from a line of its own.
        for other in ["[1. 공개 - 도시] [Tamsin Alder]: wtb healing potions", row] {
            let scroll = Scroll()
            scroll.show(3, frames: 4)
            scroll.add("[1. 공개 - 도시] [Brann Oakheart]: selling two")
            scroll.show(4, frames: 4)
            scroll.show(4, frames: 4) { index, screen, line in index == 3 ? Layout.line(screen, other) : line }
            XCTAssertEqual(scroll.said.map(\.body), ["selling two", other.components(separatedBy: "]: ")[1]], other)
        }
    }

    /// The same in a quiet chat, with one other line on screen or none at all (the others
    /// have faded): one line that stayed where it was, or the row being the only one before
    /// and after, is enough to know which row is read.
    func testRowReadDifferentlyInAQuietChatIsNotAnotherMessage() {
        let row = "[1. 공개 - 도시] [Brann Oakheart]: selling two stacks of linen"
        let garbled = "[1. 공개 - 도시] [Brann Oakheart]: selling tVexley Thornwoodinen"
        for neighbours in [0, 1] {
            for confidence in [0.5, 1.0] {
                let note = "\(neighbours) other line(s), read at \(confidence)"
                let others = neighbours == 1 ? [Layout.line(9, "[1. 공개 - 도시] [Hexbloom]: anyone selling linen cloth")] : []
                let run = Run(locale: .koKR)
                for _ in 0..<4 { run.feed(Layout.frame(others + [Layout.line(10, row)])) }
                XCTAssertEqual(run.emitted.count, neighbours + 1, note)
                for _ in 0..<6 { run.feed(Layout.frame(others + [Layout.line(10, garbled, confidence: confidence)])) }
                for _ in 0..<4 { run.feed(Layout.frame(others + [Layout.line(10, row)])) }
                XCTAssertEqual(run.everything.count, neighbours + 1, "\(note): \(run.everything.map(\.message.rawText))")
                XCTAssertEqual(run.emitted.last?.body, "selling two stacks of linen", note)
            }
        }
    }

    /// A row that really ends in words that could be a name, read a moment later with a
    /// glyph more or less in its last word, is the same row spelt differently and not a row
    /// that has lost a name: nothing is said again.
    func testSameRowSpeltDifferentlyIsNotARowWithoutAName() {
        let place = "[1. 공개 - 도시] [Brann Oakheart]: lets all go to Molten Core"
        for later in [place + ".", String(place.dropLast()), place + "I", place.replacingOccurrences(of: "Core", with: "Gore")] {
            let scroll = Scroll()
            scroll.show(3, frames: 4)
            scroll.add(place)
            scroll.show(4, frames: 3)
            scroll.show(4, frames: 4) { index, screen, line in index == 3 ? Layout.line(screen, later) : line }
            scroll.show(4, frames: 3)
            XCTAssertEqual(scroll.said.map(\.body), ["lets all go to Molten Core"], later)
            XCTAssertEqual(scroll.run.everything.count, 4, "\(later): \(scroll.run.everything.map(\.message.rawText))")
        }
        // The same for a row that says nothing but such words.
        let scroll = Scroll()
        scroll.show(3, frames: 4)
        scroll.add("[1. 공개 - 도시] [Brann Oakheart]: Molten Core")
        scroll.show(4, frames: 3)
        scroll.show(4, frames: 4) { index, screen, line in
            index == 3 ? Layout.line(screen, "[1. 공개 - 도시] [Brann Oakheart]: molten core") : line
        }
        scroll.show(4, frames: 3)
        XCTAssertEqual(scroll.said.map(\.body), ["Molten Core"])
        XCTAssertEqual(scroll.run.everything.count, 4)
    }

    /// Only this way round, and only for a while. A message that went out as it is and reads
    /// with a name behind one of its rows later stands. So does one that really ends in
    /// words that could be a name, and one whose last words are hidden long after it went
    /// out (a window of the game opened over the chat): those were more likely hidden than
    /// never there.
    func testWhatWentOutIsNotTouchedByANameThatComesLaterOrWordsHiddenLater() {
        let scroll = Scroll()
        scroll.show(3, frames: 4)
        scroll.add(Self.message[0], Self.message[1], Self.message[2])
        scroll.show(6, frames: 3)
        XCTAssertEqual(scroll.said.map(\.body), [Self.body])
        scroll.show(6, frames: 6) { index, screen, line in
            index == 5 ? Layout.line(screen, Self.message[2] + " Vexley Thornwoo") : line
        }
        scroll.show(6, frames: 4)
        XCTAssertEqual(scroll.said.map(\.body), [Self.body])
        XCTAssertEqual(scroll.run.everything.count, 4, "\(scroll.run.everything.map(\.message.rawText))")

        let place = "[1. 공개 - 도시] [Brann Oakheart]: lets all go to Molten Core"
        let late = Scroll()
        late.show(3, frames: 4)
        late.add(place)
        late.show(4, frames: ChatTracker.shedFrames + 3)
        XCTAssertEqual(late.said.map(\.body), ["lets all go to Molten Core"])
        late.show(4, frames: 5) { index, screen, line in
            index == 3 ? Layout.line(screen, "[1. 공개 - 도시] [Brann Oakheart]: lets all go to") : line
        }
        late.show(4, frames: 3)
        XCTAssertEqual(late.said.map(\.body), ["lets all go to Molten Core"])
        XCTAssertEqual(late.run.everything.count, 4, "\(late.run.everything.map(\.message.rawText))")
    }
}

// MARK: - Yells of a Korean client

final class KoreanYellTests: XCTestCase {
    private let red = RGBColor(r: 0.9, g: 0.3, b: 0.3)

    func testYellHeaderWithHonorific() {
        for (text, name, body) in [
            ("[Dorn Velmar]님의 외침: LF HEALER", "Dorn Velmar", "LF HEALER"),
            ("[Dornvel]님의 외침: NEED SUMMON TO IRONFORGE", "Dornvel", "NEED SUMMON TO IRONFORGE"),
            ("[Dornvel]의 외침: 여기요", "Dornvel", "여기요"),
            // Red brackets read as thin letters, on both sides of the name.
            ("IDorn VelmarI님의 외침: NEED SUMMON TO IRONFORGE", "Dorn Velmar", "NEED SUMMON TO IRONFORGE"),
            ("lDorn Velmarl님의 외침: NEED SUMMON", "Dorn Velmar", "NEED SUMMON"),
            ("1Dorn Velmar1님의 외침: NEED SUMMON", "Dorn Velmar", "NEED SUMMON"),
            ("[Dorn Velmarj님의 외침: NEED SUMMON", "Dorn Velmar", "NEED SUMMON"),
            // ... and a glyph or two of something else caught behind the closing one.
            ("IDorn VelmarIHg님의 외침: NEED SUMMON TO IRONFORGE", "Dorn Velmar", "NEED SUMMON TO IRONFORGE"),
            // The same seam with the opening bracket outside the captured region, as a real
            // capture cut a few pixels too far right reads it.
            ("Dorn Velmar|H9|님의 외침: LF HEALER", "Dorn Velmar", "LF HEALER"),
            ("[Dorn Velmar]H9님의 외침: LF HEALER", "Dorn Velmar", "LF HEALER"),
            ("Dornvel|Hg님의 외침: LF HEALER", "Dornvel", "LF HEALER"),
        ] {
            let p = ChatLineParser.parse(text, locale: .koKR, color: red)
            XCTAssertTrue(p.hasPrefix, text)
            XCTAssertEqual(p.channel, .yell, text)
            XCTAssertEqual(p.sender, name, text)
            XCTAssertEqual(p.body, body, text)
            XCTAssertFalse(p.isDamagedHeader, text)
        }
        // A wrapped row of a yell that is nothing but a link is no header.
        let link = ChatLineParser.parse("[Enchanting: Enchant Boots - Minor Stamina]", locale: .koKR, color: red)
        XCTAssertFalse(link.hasPrefix)
        XCTAssertNil(link.sender)
    }

    /// A yell is one message with its wrapped rows, the top row of the window included, and
    /// a link on a row of its own stays inside it.
    func testYellsAreReportedWithTheirWrappedRows() {
        let run = Run(locale: .koKR)
        var lines = [Layout.line(0, "[Dorn Velmar]님의 외침: LF HEALER", red)]
        lines.append(Layout.line(1, "[1. 공개 - 도시] [Hexbloom]: anyone selling linen cloth"))
        lines.append(Layout.line(2, "[Kessa Nightbloom]님의 외침: anyone need", red))
        lines.append(Layout.line(3, "[Enchanting: Enchant Boots - Minor Stamina]", red, x: Layout.wrappedX))
        lines.append(Layout.line(4, "for free? 9 left", red))
        lines.append(Layout.line(5, "[Orrin Lutho]님의 외침: that comma is doing", red))
        lines.append(Layout.line(6, "a lot of work", red))
        lines.append(Layout.line(7, "[Dorn Velmar]님의 외침: NEED SUMMON TO IRONFORGE", red))
        for _ in 0..<4 { run.feed(Layout.frame(lines)) }
        XCTAssertEqual(run.emitted.map(\.channel), [.yell, .publicChannel, .yell, .yell, .yell], "\(run.texts)")
        XCTAssertEqual(run.emitted.map(\.sender), ["Dorn Velmar", "Hexbloom", "Kessa Nightbloom", "Orrin Lutho", "Dorn Velmar"])
        XCTAssertEqual(run.emitted.map(\.body), [
            "LF HEALER", "anyone selling linen cloth",
            "anyone need [Enchanting: Enchant Boots - Minor Stamina] for free? 9 left",
            "that comma is doing a lot of work", "NEED SUMMON TO IRONFORGE",
        ])
    }

    /// A name over the middle of a yell header: not a header any more, in the yell colour.
    /// It is held like any damaged header row and replaced by the clean read.
    func testCoveredYellHeaderIsReplacedByTheCleanRead() {
        let run = Run(locale: .koKR)
        let top = [Layout.line(5, "[1. 공개 - 도시] [Hexbloom]: anyone selling linen cloth"),
                   Layout.line(6, "[1. 공개 - 도시] [Quillon]: lf enchanter pst")]
        for _ in 0..<4 { run.feed(Layout.frame(top)) }
        let covered = Layout.line(7, "[Dorn Velmar]남aRtrINPEDSUOIMON TO IRONFORGE", red, confidence: 0.5)
        XCTAssertTrue(ChatLineParser.parse(covered.text, locale: .koKR, color: red).isDamagedHeader)
        for _ in 0..<3 { run.feed(Layout.frame(top + [covered])) }
        XCTAssertEqual(run.emitted.count, 2, "\(run.texts)")
        for _ in 0..<3 { run.feed(Layout.frame(top + [Layout.line(7, "[Dorn Velmar]님의 외침: NEED SUMMON TO IRONFORGE", red)])) }
        XCTAssertEqual(run.emitted.count, 3, "\(run.texts)")
        XCTAssertEqual(run.emitted.last?.channel, .yell)
        XCTAssertEqual(run.emitted.last?.body, "NEED SUMMON TO IRONFORGE")
    }
}

// MARK: - Damaged headers and how a line is written out

final class DamagedHeaderTests: XCTestCase {
    private let pink = RGBColor(r: 1, g: 0.75, b: 0.75)

    func testWhatCountsAsADamagedHeader() {
        let damaged = [
            "[1. 공개 - 도시] tıpsfar levaling å woryWardens>",       // tag, then no name group at all
            "[1. 공개 - 도시] [Brann Vexley Thornwood",              // name group never closes, no colon
            "[1. 공개 - 도시] [Brann OaVexley: Thornwood",           // ... or a colon somewhere behind it
            "[1. 공개Zat통유TILAmtreeus Oakheartj: any",             // the tag itself is cut short
            "[Brann Oakheart]남aRtrINPEDSUOIMON TO IRONFORGE",             // bracketed name, then no particle
        ]
        for text in damaged {
            XCTAssertTrue(ChatLineParser.parse(text, locale: .koKR, color: pink).isDamagedHeader, text)
        }
        let sound = [
            "[1. 공개 - 도시] [Brann Oakheart]: any",
            "[1. 공개 - 도시] [Brann Oakheartl: any",                // closing bracket read as a letter
            "[길드] [Brann]: hello there",
            "[Brann Oakheart]님의 외침: hello",
            "advice on leveling without quests",
            "[21:04] 서버가 곧 재시작됩니다.",
        ]
        for text in sound {
            XCTAssertFalse(ChatLineParser.parse(text, locale: .koKR, color: pink).isDamagedHeader, text)
        }
        // Text of a system notice that starts with a link is no damaged header.
        let notice = ChatLineParser.parse("[Brann]님이 접속했습니다.", locale: .koKR, color: RGBColor(r: 1, g: 1, b: 0))
        XCTAssertFalse(notice.isDamagedHeader)
    }

    /// A row that opens with a bracketed name and is no header this parser knows may be a
    /// notice of the game ("[Name] is away: ..."). It waits like a damaged header row, and
    /// then goes out as it reads, as a line of no channel — which is never translated.
    func testUnknownNoticeBehindABracketedNameIsKeptUntranslated() {
        let run = Run(locale: .koKR)
        let top = [Layout.line(5, "[1. 공개 - 도시] [Hexbloom]: anyone selling linen cloth"),
                   Layout.line(6, "[1. 공개 - 도시] [Quillon]: lf enchanter pst")]
        for _ in 0..<4 { run.feed(Layout.frame(top)) }
        let notice = Layout.line(7, "[Dorn Velmar]님은 자리 비움 상태입니다: brb dinner", RGBColor(r: 1, g: 0.5, b: 1))
        for _ in 0..<8 { run.feed(Layout.frame(top + [notice])) }
        XCTAssertEqual(run.emitted.count, 3, "\(run.texts)")
        XCTAssertEqual(run.emitted.last?.rawText, notice.text)
        XCTAssertNil(run.emitted.last?.channel.group, "not a channel that is translated")
        XCTAssertNil(run.emitted.last?.sender)
    }

    /// A speaker whose name has two words is written once, whole, without brackets, after
    /// the channel tag — in the overlay, the main window and the history file alike.
    func testSpeakerWithTwoWordsIsWrittenOnceAndWhole() {
        func message(_ text: String, _ color: RGBColor) -> ChatMessage {
            let p = ChatLineParser.parse(text, locale: .koKR, color: color)
            return ChatMessage(channel: p.channel, channelLabel: p.channelLabel, sender: p.sender, body: p.body,
                               rawText: text, color: color, firstSeen: Date(timeIntervalSince1970: 0))
        }
        let channel = message("[1. 공개 - 도시] [Tamsin Alder]: Dps Lf Stocks", pink)
        XCTAssertEqual(channel.sender, "Tamsin Alder")
        XCTAssertEqual(channel.channelLabel, "1. 공개 - 도시")
        XCTAssertEqual(ChatDisplay.prefix(for: channel), "[1. 공개 - 도시] Tamsin Alder: ")
        XCTAssertEqual(ChatDisplay.senderPrefix(for: channel), "Tamsin Alder: ")

        // With the channel tag outside the captured region the first word is not a tag.
        let bare = message("[Tamsin Alder]: Dps Lf Stocks", pink)
        XCTAssertEqual(ChatDisplay.prefix(for: bare), "Tamsin Alder: ")
        // Closing bracket read as a letter, with and without a tag in front.
        for damaged in ["[1. 공개 - 도시] [Tamsin Alderl: Dps Lf Stocks", "[1. 공개 - 도시] [Tamsin Alderj: Dps Lf Stocks",
                        "[1. 공개 - 도시 [Tamsin Alder]: Dps Lf Stocks"] {
            XCTAssertEqual(ChatDisplay.prefix(for: message(damaged, pink)), "[1. 공개 - 도시] Tamsin Alder: ", damaged)
        }
        for damaged in ["[Tamsin Alderl: Dps Lf Stocks", "[Tamsin AlderJ: Dps Lf Stocks"] {
            let m = message(damaged, pink)
            XCTAssertNil(m.channelLabel, "\"Tamsin\" is not a channel tag: \(damaged)")
            XCTAssertNotEqual(m.sender, "Alder", damaged)
        }
        let yell = message("[Tamsin Alder]님의 외침: Dps Lf Stocks", RGBColor(r: 1, g: 0.25, b: 0.25))
        XCTAssertEqual(ChatDisplay.prefix(for: yell), "Tamsin Alder: ")
        let whisper = message("[Tamsin Alder]님의 귓속말: hi", RGBColor(r: 1, g: 0.5, b: 1))
        XCTAssertEqual(ChatDisplay.prefix(for: whisper), "[귓속말] Tamsin Alder: ")
        let system = message("서버가 곧 재시작됩니다.", RGBColor(r: 1, g: 1, b: 0))
        XCTAssertEqual(ChatDisplay.prefix(for: system), "")

        // An emote names its speaker in its own text: the whole name is the speaker, and it
        // is not written a second time in front of the line.
        let orange = RGBColor(r: 1, g: 0.5, b: 0.25)
        for (text, name) in [("Tamsin Alder가 신나게 춤을 춥니다.", "Tamsin Alder"),
                             ("Tamsin Alder이 Brann Oakheart에게 감사해 합니다.", "Tamsin Alder"),
                             ("Tamsin가 신나게 춤을 춥니다.", "Tamsin"),
                             ("Tamsin Alder waves at you.", "Tamsin"),
                             ("탐신님이 손을 흔듭니다.", "탐신")] {
            let emote = message(text, orange)
            XCTAssertEqual(emote.channel, .emote, text)
            XCTAssertEqual(emote.sender, name, text)
            XCTAssertEqual(ChatDisplay.prefix(for: emote), "", text)
        }
    }
}
