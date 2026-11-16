import XCTest
import CoreGraphics
@testable import RunespeakCore

// What a second look at the capture side turned up: a row that is nothing but a bracket, chat
// that names the labels of the game's chat menu, a window with an opaque background, a window
// whose rows are replaced by rows much like them, a message whose last words somebody else had
// said before, numbers typed into short lines, and names
// that differ by one thin letter. All frames are hand-built; all names are invented.

// XCTest pulls in AppKit, which still exports a QuickDraw-era `RGBColor`.
private typealias RGBColor = RunespeakCore.RGBColor

private enum Ink {
    static let pink = RGBColor(r: 0.99, g: 0.76, b: 0.77)       // numbered public channel
    static let guild = RGBColor(r: 0.33, g: 0.95, b: 0.33)
    static let white = RGBColor(r: 1, g: 1, b: 1)
    static let notice = RGBColor(r: 1, g: 1, b: 0)               // quest link
    static let orange = RGBColor(r: 1, g: 0.5, b: 0.25)         // quest link (the colour of an emote)
    static let reputation = RGBColor(r: 0.5, g: 0.5, b: 1)
    static let uncommon = RGBColor(r: 0.12, g: 1, b: 0)
}

/// The window of `CaptureFixTests`: rows 41.6 px apart, messages at x = 76, wrapped rows 16 px
/// to their right, ten rows.
private enum Screen {
    struct Row {
        var text: String
        var colour: RGBColor
        var wrapped = false
        var confidence = 1.0

        init(_ text: String, _ colour: RGBColor, wrapped: Bool = false, confidence: Double = 1) {
            self.text = text; self.colour = colour; self.wrapped = wrapped; self.confidence = confidence
        }
    }

    static let size = CGSize(width: 1056, height: 432)
    static let pitch: CGFloat = 41.6
    static let visible = 10
    static let messageX: CGFloat = 76
    static let wrappedX: CGFloat = 92
    static let rightEdge: CGFloat = 1010

    static func width(_ c: Character) -> CGFloat {
        if c == " " { return 9 }
        if TextFold.columns(String(c)) == 2 { return 33 }
        if c.isLetter { return c.isUppercase ? 20 : 15 }
        return 10
    }
    static func width(_ text: String) -> CGFloat { text.reduce(0) { $0 + width($1) } }

    static func line(_ row: Row, slot: Int) -> OCRLine {
        let x = row.wrapped ? wrappedX : messageX
        return OCRLine(text: row.text, box: CGRect(x: x, y: 11 + CGFloat(slot) * pitch, width: min(width(row.text), rightEdge - x), height: 36),
                       color: row.colour, confidence: row.confidence)
    }

    /// The window after `count` rows of `log` have arrived: the newest ten, bottom-aligned.
    static func frame(_ log: [Row], shown count: Int, opaque: Bool = false) -> OCRFrame {
        let rows = Array(log[max(0, count - visible)..<count])
        let first = visible - rows.count
        return OCRFrame(lines: rows.enumerated().map { line($0.element, slot: first + $0.offset) }, imageSize: size, opaqueBackground: opaque)
    }

    /// The same window with an opaque panel of the interface over the columns `panel` of the
    /// rows from `firstSlot` on, one label of `labels` to a row: left of the panel what is
    /// left of the row, then the label, then what shows to the right of the panel (as one
    /// line when the label reaches it, as two when a gap is left).
    static func frame(_ log: [Row], shown count: Int, under labels: [String], panel: ClosedRange<CGFloat>, firstSlot: Int,
                      opaque: Bool) -> OCRFrame {
        let rows = Array(log[max(0, count - visible)..<count])
        let base = visible - rows.count
        var out: [OCRLine] = []
        for (n, row) in rows.enumerated() {
            let slot = base + n
            let index = slot - firstSlot
            guard index >= 0, index < labels.count else { out.append(line(row, slot: slot)); continue }
            let label = labels[index]
            let y = 11 + CGFloat(slot) * pitch
            let startX = row.wrapped ? wrappedX : messageX
            var left = "", right = "", pen = startX
            for c in row.text {
                let w = width(c)
                if pen + w <= panel.lowerBound + 6 { left.append(c) } else if pen + w / 2 >= panel.upperBound { right.append(c) }
                pen += w
            }
            left = left.trimmingCharacters(in: .whitespaces)
            right = right.trimmingCharacters(in: .whitespaces)
            let labelEnd = panel.lowerBound + 20 + CGFloat(TextFold.columns(label)) * 12.5
            if left.isEmpty {
                out.append(OCRLine(text: label, box: CGRect(x: panel.lowerBound + 18, y: y + 2, width: labelEnd - panel.lowerBound - 18, height: 34),
                                   color: Ink.white, confidence: 0.67))
                if !right.isEmpty {
                    out.append(OCRLine(text: right, box: CGRect(x: panel.upperBound - 4, y: y, width: width(right), height: 38), color: row.colour, confidence: 1))
                }
            } else if !right.isEmpty, panel.upperBound - labelEnd <= 68 {
                out.append(OCRLine(text: left + " " + label + " " + right,
                                   box: CGRect(x: startX - 2, y: y, width: panel.upperBound - startX + width(right), height: 38),
                                   color: row.colour, confidence: 0.9))
            } else {
                out.append(OCRLine(text: left + " " + label, box: CGRect(x: startX - 2, y: y + 1, width: labelEnd - startX, height: 36),
                                   color: row.colour, confidence: 0.67))
                if !right.isEmpty {
                    out.append(OCRLine(text: right, box: CGRect(x: panel.upperBound - 4, y: y, width: width(right), height: 38), color: row.colour, confidence: 1))
                }
            }
        }
        return OCRFrame(lines: out.sorted { $0.box.minY < $1.box.minY }, imageSize: size, opaqueBackground: opaque)
    }
}

private typealias Row = Screen.Row

/// Feeds frames to a tracker and keeps the list of lines as the app shows it.
private final class Feed {
    let tracker: ChatTracker
    var clock = Date(timeIntervalSince1970: 1_700_000_000)
    var listed: [ChatMessage] = []
    var everything: [ChatMessage] = []

    init(locale: ClientLocale = .koKR) { tracker = ChatTracker(clientLocale: locale) }

    @discardableResult
    func feed(_ frame: OCRFrame, times: Int = 1, step: TimeInterval = 0.7) -> [ChatMessage] {
        var all: [ChatMessage] = []
        for _ in 0..<times {
            clock += step
            let out = tracker.ingest(frame, now: clock)
            let corrections = tracker.corrections
            for message in out {
                everything.append(message)
                var entries = listed.map { ChatEntry(message: $0, state: .original) }
                entries.place(ChatEntry(message: message, state: .original), replacing: corrections[message.id] ?? [])
                listed = entries.map(\.message)
            }
            all += out
        }
        return all
    }

    /// Rows arrive one capture apart; the last view is then read until everything has settled.
    func play(_ log: [Row], from start: Int = 1, settle: Int = 8, opaque: Bool = false) {
        for count in start...log.count { feed(Screen.frame(log, shown: count, opaque: opaque)) }
        feed(Screen.frame(log, shown: log.count, opaque: opaque), times: settle)
    }

    var texts: [String] { listed.map(\.rawText) }
    var bodies: [String] { listed.map(\.body) }
}

private let opening: [Row] = [
    Row("[1. 공개 - 저습지] [Tovin Marsh]: anyone selling linen cloth for the tailors here", Ink.pink),
    Row("or some wool", Ink.pink, wrapped: true),
    Row("[길드] [Sena Dawnpetal]: 다들 어디세요", Ink.guild),
]

/// Twenty messages of one and two rows, public and guild, each with its number in it.
private func chatter() -> (rows: [Row], said: [String]) {
    let names = ["Bram Oakwind", "Lena Emberfall", "Tovin Marsh", "Mira Fenn", "Hank Brill", "Odalys Fenn", "Petra Voss", "Garrik Thane"]
    let guildies = ["Sena Dawnpetal", "Dalla Reed", "Lu Mi"]
    let short = ["hold the line at the ford", "see you at the north gate", "anyone up for the crab quest", "thanks for the escort mate",
                 "selling copper bars two silver each", "where is the griffon master here", "need one more for the cave run",
                 "they went around the hill again", "who has the key for the cellar", "boat is leaving in a minute"]
    let long = [("pushed them all the way back to", "the bridge and they ran"), ("never trust a goblin when he", "offers you a discount"),
                ("looking for a healer and a tank", "for the crypt tonight"), ("if you see the red banner run", "straight to the docks")]
    let korean = ["다들 어디세요", "저녁 먹고 올게요", "이거 필요하신 분?", "다녀왔어요", "오늘 몇시에 모여요", "조금만 기다려 주세요"]
    var rows: [Row] = [], said: [String] = []
    for i in 0..<20 {
        switch i % 5 {
        case 0, 3:
            let text = "[1. 공개 - 저습지] [\(names[(i * 3 + 1) % names.count])]: \(short[(i * 8) % short.count]) \(i)"
            rows.append(Row(text, Ink.pink)); said.append(text)
        case 1, 4:
            let text = "[길드] [\(guildies[i % guildies.count])]: \(korean[(i * 5 + 2) % korean.count]) \(i)"
            rows.append(Row(text, Ink.guild)); said.append(text)
        default:
            let head = "[1. 공개 - 저습지] [\(names[(i * 5 + 2) % names.count])]: \(long[(2 * i) % long.count].0)"
            let rest = "\(long[(2 * i) % long.count].1) \(i)"
            rows.append(Row(head, Ink.pink)); rows.append(Row(rest, Ink.pink, wrapped: true))
            said.append(head + " " + rest)
        }
    }
    return (rows, said)
}

// MARK: - A row that is nothing but a bracket

final class LoneBracketTests: XCTestCase {

    /// A bracket standing alone on a row (the stub of a tag under a menu, a stroke of the
    /// window frame) used to end the app: a range that began behind the end of the text.
    func testRowThatIsOnlyABracketIsParsed() {
        for text in ["[", "(", "{", " [", "[ ", "【", "<", "]", "[]", "[1", "[a", "(:", "21:04 [", "[ [", "[["] {
            for locale in [ClientLocale.koKR, .enUS] {
                let parsed = ChatLineParser.parse(text, locale: locale, color: Ink.white)
                XCTAssertNil(parsed.sender, "\(text)")
                XCTAssertFalse(parsed.hasPrefix && !parsed.isDamagedHeader, "\(text) is no sound header")
            }
        }
    }

    /// The same for a stray mark with nothing but blanks behind it (a row handed over
    /// untrimmed): the bracket it might stand in front of was looked for past the end.
    func testStrayMarkFollowedByBlanksIsParsed() {
        for text in [".  ", ". \t ", "-  ", "·   ", "|  ", ":  ", "*    ", " .  ", "…  ", ".  [", ". [길드] [Sena Dawnpetal]: 넵"] {
            for locale in [ClientLocale.koKR, .enUS] {
                for colour in [Ink.white, Ink.pink, Ink.guild] {
                    let parsed = ChatLineParser.parse(text, locale: locale, color: colour)
                    if !text.contains("Sena") { XCTAssertNil(parsed.sender, "\(text)") }
                }
            }
        }
        // A mark in front of a header is still skipped.
        XCTAssertEqual(ChatLineParser.parse(". [길드] [Sena Dawnpetal]: 넵", locale: .koKR, color: Ink.guild).sender, "Sena Dawnpetal")
    }

    func testBracketOnARowOfItsOwnDoesNotStopTheChat() {
        var log = opening
        log.append(Row("[길드] [Dalla Reed]: 저녁 먹고 올게요", Ink.guild))
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: 3), times: 3)
        for bracket in ["[", "(", "{"] {
            var frame = Screen.frame(log, shown: 4)
            frame.lines.append(OCRLine(text: bracket, box: CGRect(x: 600, y: 11 + 9 * Screen.pitch, width: 12, height: 36), color: Ink.white, confidence: 0.5))
            frame.lines.insert(OCRLine(text: bracket, box: CGRect(x: 76, y: 11 + 5 * Screen.pitch, width: 12, height: 36), color: Ink.white, confidence: 0.5),
                               at: 0)
            feed.feed(frame, times: 3)
        }
        feed.feed(Screen.frame(log, shown: 4), times: 6)
        XCTAssertEqual(feed.bodies, ["anyone selling linen cloth for the tailors here or some wool", "다들 어디세요", "저녁 먹고 올게요"])
    }
}

// MARK: - Chat that names the labels of the chat menu

final class MenuLabelsInChatTests: XCTestCase {

    /// Three guild members explain where the settings are, each naming one entry of the menu,
    /// in the order the menu lists them. That is chat: every line comes out, and so does what
    /// is said after them while they are still on screen.
    func testLinesThatNameLabelsInMenuOrderAreChat() {
        var log = opening
        log.append(Row("[길드] [Sena Dawnpetal]: 창 이름 변경 어디서 해요", Ink.guild))
        log.append(Row("[길드] [Dalla Reed]: 새 대화창 생성 밑에 있어요", Ink.guild))
        log.append(Row("[길드] [Lu Mi]: 글자 크기도 거기서 바꿔요", Ink.guild))
        log.append(Row("[길드] [Sena Dawnpetal]: 아 감사합니다", Ink.guild))
        log.append(Row("[1. 공개 - 저습지] [Bram Oakwind]: anyone selling copper bars", Ink.pink))
        log.append(Row("[길드] [Dalla Reed]: 넵 수고하세요", Ink.guild))
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: opening.count), times: 3)
        feed.play(log, from: opening.count + 1)
        XCTAssertEqual(feed.listed.count, 8, "\(feed.texts)")
        XCTAssertEqual(Array(feed.bodies.suffix(6)), ["창 이름 변경 어디서 해요", "새 대화창 생성 밑에 있어요", "글자 크기도 거기서 바꿔요", "아 감사합니다",
                                                     "anyone selling copper bars", "넵 수고하세요"])
        // The same window seen cold (the app was started while they were on screen).
        let cold = Feed()
        cold.feed(Screen.frame(log, shown: log.count), times: 6)
        XCTAssertEqual(cold.listed.count, 8, "\(cold.texts)")
    }

    /// One long message that names three entries on its three rows, and wrapped rows that
    /// begin with the words of a label or are nothing else.
    func testWrappedRowsThatBeginWithALabelStayInTheirMessage() {
        var log = opening
        log.append(Row("[길드] [Sena Dawnpetal]: 채팅창 탭 우클릭하고 편집 모드 말고 그 밑에", Ink.guild))
        log.append(Row("창 이름 변경 옆에 있는 메뉴 누르면 글자 크기", Ink.guild, wrapped: true))
        log.append(Row("나오고 그 밑에 배경 설정 있어요", Ink.guild, wrapped: true))
        log.append(Row("[길드] [Dalla Reed]: 채팅 탭 우클릭 하면 나오는 메뉴 맨 아래에 있는", Ink.guild))
        log.append(Row("설정", Ink.guild, wrapped: true))
        log.append(Row("[길드] [Lu Mi]: 글씨 키우려면 같은 메뉴에 있는", Ink.guild))
        log.append(Row("글자 크기 누르세요", Ink.guild, wrapped: true))
        log.append(Row("[1. 공개 - 저습지] [Bram Oakwind]: anyone selling copper bars", Ink.pink))
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: opening.count), times: 3)
        feed.play(log, from: opening.count + 1, settle: 12)
        XCTAssertEqual(Array(feed.bodies.dropFirst(2)), [
            "채팅창 탭 우클릭하고 편집 모드 말고 그 밑에 창 이름 변경 옆에 있는 메뉴 누르면 글자 크기 나오고 그 밑에 배경 설정 있어요",
            "채팅 탭 우클릭 하면 나오는 메뉴 맨 아래에 있는 설정",
            "글씨 키우려면 같은 메뉴에 있는 글자 크기 누르세요",
            "anyone selling copper bars",
        ])
    }

    func testEnglishClientKeepsWrappedRowsThatBeginWithALabel() {
        var log = [Row("[1. General - Wetlands] [Tovin Marsh]: anyone selling linen cloth for the tailors here", Ink.pink),
                   Row("or some wool", Ink.pink, wrapped: true),
                   Row("[Guild] [Sena Dawnpetal]: hello all", Ink.guild)]
        log.append(Row("[Guild] [Dalla Reed]: does anyone know how to make the chat", Ink.guild))
        log.append(Row("font size bigger in this client", Ink.guild, wrapped: true))
        log.append(Row("[Guild] [Sena Dawnpetal]: right click the tab then look at the bottom for", Ink.guild))
        log.append(Row("settings", Ink.guild, wrapped: true))
        log.append(Row("[Guild] [Lu Mi]: ok", Ink.guild))
        let feed = Feed(locale: .enUS)
        feed.feed(Screen.frame(log, shown: 3), times: 3)
        feed.play(log, from: 4, settle: 12)
        XCTAssertTrue(feed.bodies.contains("does anyone know how to make the chat font size bigger in this client"), "\(feed.bodies)")
        XCTAssertTrue(feed.bodies.contains("right click the tab then look at the bottom for settings"), "\(feed.bodies)")
    }

    /// Rows that went out as chat stay chat, whatever they name. Two of them are about the
    /// settings; then comes a line with a third entry in it whose header OCR damaged (the
    /// bracket behind the name was not read). That is still talk, and what is said afterwards
    /// comes out.
    func testChatThatWentOutIsNotCountedTowardsAMenu() {
        var log = opening
        log.append(Row("[길드] [Sena Dawnpetal]: 창 이름 변경 어디서 해요", Ink.guild))
        log.append(Row("[길드] [Dalla Reed]: 글자 크기 밑에 있어요", Ink.guild))
        let feed = Feed()
        feed.play(log)
        XCTAssertEqual(feed.listed.count, 4)
        let damaged = Row("[길드] [Lu Mi: 배경 설정도 거기 있어요", Ink.guild, confidence: 0.5)
        XCTAssertTrue(ChatMenu.sightings(in: [Screen.line(damaged, slot: 0)], locale: .koKR).first?.strong ?? false,
                      "by itself such a row cannot be told from a row under the menu")
        log.append(damaged)
        log.append(Row("[1. 공개 - 저습지] [Bram Oakwind]: anyone selling copper bars", Ink.pink))
        log.append(Row("[길드] [Sena Dawnpetal]: 감사합니다", Ink.guild))
        feed.play(log, from: 6, settle: 10)
        XCTAssertTrue(feed.bodies.contains("anyone selling copper bars"), "\(feed.texts)")
        XCTAssertTrue(feed.bodies.contains("감사합니다"), "\(feed.texts)")
    }

    /// A window seen cold, with nothing in it known: two lines that name entries of the menu
    /// and a wrapped row that is nothing but the word "설정". The wrapped row stands where
    /// wrapped rows stand, in the colour of its message: chat, and no menu.
    func testWrappedRowThatIsOnlyALabelDoesNotMakeAMenuOfTalk() {
        var log = opening
        log.append(Row("[길드] [Sena Dawnpetal]: 창 이름 변경 어디서 해요", Ink.guild))
        log.append(Row("[길드] [Lu Mi]: 글자 크기는 그 밑에 있고요", Ink.guild))
        log.append(Row("[길드] [Dalla Reed]: 채팅 탭 우클릭 하면 나오는 메뉴 맨 아래에 있는", Ink.guild))
        log.append(Row("설정", Ink.guild, wrapped: true))
        log.append(Row("[길드] [Sena Dawnpetal]: 감사합니다", Ink.guild))
        let cold = Feed()
        cold.feed(Screen.frame(log, shown: log.count), times: 6)
        XCTAssertEqual(cold.listed.count, 6, "\(cold.texts)")
        XCTAssertTrue(cold.bodies.contains("채팅 탭 우클릭 하면 나오는 메뉴 맨 아래에 있는 설정"), "\(cold.texts)")
        // The same word alone on a row where no wrapped row can be (white, off the columns): a label.
        var frame = Screen.frame(log, shown: log.count)
        frame.lines[6] = OCRLine(text: "설정", box: CGRect(x: 138, y: frame.lines[6].box.minY + 2, width: 60, height: 34), color: Ink.white, confidence: 0.67)
        let other = Feed()
        other.feed(frame, times: 6)
        XCTAssertFalse(other.everything.contains { $0.body.hasSuffix("설정") }, "\(other.texts)")
    }

    /// What tells the menu from talk about it: a label in a row that cannot be chat.
    func testOnlyRowsThatCannotBeChatSayTheMenuIsOpen() {
        func lines(_ texts: [String], _ colour: RGBColor = Ink.guild) -> [OCRLine] {
            texts.enumerated().map { Screen.line(Row($0.element, colour), slot: $0.offset) }
        }
        // Sound headers with the labels behind them, in menu order: chat.
        XCTAssertFalse(ChatMenu.isOpen(over: lines(["[길드] [Sena Dawnpetal]: 편집 모드 누르지 말고", "[길드] [Sena Dawnpetal]: 창 이름 변경 누르고",
                                                     "[길드] [Sena Dawnpetal]: 글자 크기 누르세요", "[길드] [Sena Dawnpetal]: 배경 설정도 있어요"]), locale: .koKR))
        // The same labels where the tags were: the menu.
        XCTAssertTrue(ChatMenu.isOpen(over: lines(["[길 편집 모드 Dawnpetal]: 다들 어디세요", "[길 창 이름 변경 Reed]: 저녁 먹고 올게요"]), locale: .koKR))
        // One row that cannot be chat and two that may be: three labels in order.
        XCTAssertTrue(ChatMenu.isOpen(over: lines(["[길 편집 모드 Dawnpetal]: 다들 어디세요", "the bri 창 이름 변경", "글자 크기 unless we hold it"]), locale: .koKR))
        XCTAssertFalse(ChatMenu.isOpen(over: lines(["the bri 창 이름 변경", "글자 크기 unless we hold it", "배경 설정 for the crab"]), locale: .koKR),
                       "no row that cannot be chat")
        let found = ChatMenu.sightings(in: lines(["설정", "[길드] [Lu Mi]: 설정", "[1. 필터 설정습지] [Bram Oakwind]: NEVER", "글자 크기 누르세요"]), locale: .koKR)
        XCTAssertEqual(found.map(\.label.text), ["설정", "필터 설정", "글자 크기"])
        XCTAssertEqual(found.map(\.strong), [true, true, false])
        XCTAssertEqual(found.map(\.leads), [true, false, true])
    }

    /// The menu itself is still told when rows of chat about it are on screen: it opens over
    /// rows that went out as chat, and its labels stand where their tags were.
    func testMenuOpeningOverTalkAboutTheMenuIsStillTheMenu() {
        var log = opening
        log.append(Row("[길드] [Sena Dawnpetal]: 글자 크기 어디서 바꿔요", Ink.guild))
        log.append(Row("[1. 공개 - 저습지] [Bram Oakwind]: hold the line at the ford", Ink.pink))
        log.append(Row("[1. 공개 - 저습지] [Lena Emberfall]: see you at the north gate", Ink.pink))
        log.append(Row("[길드] [Dalla Reed]: 저녁 먹고 올게요", Ink.guild))
        let feed = Feed()
        feed.play(log)
        let before = feed.everything.count
        XCTAssertEqual(before, 6)
        log.append(Row("[1. 공개 - 저습지] [Mira Fenn]: who has the key for the cellar", Ink.pink))
        let labels = ["편집 모드", "상호작용 비활성화", "창 이름 변경", "새 대화창 생성", "디스플레이 설정", "글자 크기", "배경 설정", "필터 설정"]
        feed.feed(Screen.frame(log, shown: log.count, under: labels, panel: 120...346, firstSlot: 2, opaque: false), times: 6)
        XCTAssertEqual(feed.everything.count, before, "nothing while the menu is open: \(feed.everything.dropFirst(before).map(\.rawText))")
        feed.feed(Screen.frame(log, shown: log.count), times: 8)
        XCTAssertEqual(feed.listed.count, 7, "\(feed.texts)")
        XCTAssertEqual(feed.listed.last?.body, "who has the key for the cellar")
        XCTAssertFalse(feed.everything.contains { m in labels.contains { $0.count >= 4 && m.rawText.contains($0) && !m.rawText.contains("어디서 바꿔요") } })
    }
}

// MARK: - A chat window with an opaque background

final class OpaqueWindowTests: XCTestCase {
    func testFramesAreNotOpaqueUnlessTheRecogniserSaysSo() {
        XCTAssertFalse(OCRFrame(lines: [], imageSize: .zero).opaqueBackground)
        XCTAssertTrue(OCRFrame(lines: [], imageSize: .zero, opaqueBackground: true).opaqueBackground)
    }

    /// The tracker reads a window with an opaque background like any other. Of what the
    /// interface draws over the chat only the chat menu is known (`ChatMenu`). Another panel
    /// (the menu of a player's name, with labels `ChatMenu` has never heard of) does not stop
    /// the chat: no capture is left out for it, and what arrives below it comes out at once.
    func testPanelOverAnOpaqueWindowDoesNotStopTheChat() {
        let labels = ["귓속말", "초대", "대상 지정"]
        let rows = chatter().rows
        func boundary(_ n: Int) -> Int {
            var k = min(n, rows.count)
            while k < rows.count, rows[k].wrapped { k += 1 }
            return k
        }
        /// What each capture gave: the window, then the panel over its three top rows while
        /// six more rows of chat arrive, then the window without the panel.
        func run(opaque: Bool) -> (captures: [[String]], underPanel: Int) {
            let feed = Feed()
            var captures: [[String]] = []
            func take(_ frame: OCRFrame, times: Int) {
                for _ in 0..<times { captures.append(feed.feed(frame).map { "\($0.isFragment ? "…" : "")\($0.rawText)" }) }
            }
            let before = boundary(12)
            take(Screen.frame(rows, shown: before, opaque: opaque), times: 5)
            let known = feed.everything.count
            var shown = before
            for step in 1...3 {
                shown = boundary(before + 2 * step)
                take(Screen.frame(rows, shown: shown, under: labels, panel: 250...470, firstSlot: 0, opaque: opaque), times: 4)
            }
            let underPanel = feed.everything.count - known
            take(Screen.frame(rows, shown: shown, opaque: opaque), times: 10)
            return (captures, underPanel)
        }
        let opaque = run(opaque: true), translucent = run(opaque: false)
        XCTAssertGreaterThan(opaque.underPanel, 0, "new chat is reported while other rows have a panel over them")
        XCTAssertEqual(opaque.captures, translucent.captures, "capture by capture the same lines, whatever the background")
    }
}

// MARK: - A window whose rows are replaced by rows much like them

final class RowsReplacedByTheirLikeTests: XCTestCase {
    /// The notices of a quest handed in, as a Korean client prints them (invented factions).
    private func handIn(_ quest: String, experience: Int, _ gains: [(String, Int)]) -> [Row] {
        [Row("퀘스트를 완료했습니다: \(quest)", Ink.notice), Row("경험치를 획득했습니다: \(experience) XP", Ink.notice)]
            + gains.map { Row("\($0.0)에 대한 평판이 \($0.1)만큼 상승했습니다.", Ink.reputation) }
    }

    /// Two quests handed in a few seconds apart: the notices of the second arrive between two
    /// captures and stand where those of the first stood, the same sentences with another
    /// faction or another number in them. That is the chat scrolling. Nothing is skipped,
    /// every notice comes out, and so does what the guild says afterwards, one capture later.
    func testNoticesOfASecondHandInAllComeOut() {
        for seed in 0..<6 {
            var log = Array(chatter().rows.dropFirst(seed).prefix(11))
            while log.first?.wrapped == true { log.removeFirst() }
            let feed = Feed()
            feed.play(log, opaque: true)
            let chat = feed.everything.count
            let first = handIn("강가의 약초", experience: 1500, [("모래바람 상단", 25), ("은빛 등불회", 250), ("갈대숲 부족", 25), ("바위턱 일족", 25)])
            let second = handIn("오래된 서약", experience: 1600, [("모래바람 상단", 25), ("은빛 등불회", 25), ("갈대숲 부족", 150), ("강철톱니 조합", 25)])
            log += first
            feed.feed(Screen.frame(log, shown: log.count, opaque: true), times: 8)
            log += second
            feed.feed(Screen.frame(log, shown: log.count, opaque: true), times: 8)
            XCTAssertEqual(feed.everything.count, chat + first.count + second.count, "seed \(seed): every notice once: \(feed.texts.suffix(13))")
            for n in 1...4 {
                let line = "[길드] [Dalla Reed]: 저 \(n)번째로 말하는데 들리나요"
                log.append(Row(line, Ink.guild))
                feed.feed(Screen.frame(log, shown: log.count, opaque: true), times: 3)
                XCTAssertEqual(feed.texts.last, line, "seed \(seed): guild line \(n) is out three captures after it appeared")
            }
        }
    }

    /// A seller's lines said again: the two rows of the old view that are still on screen
    /// say the window moved up eight rows, and the same two lines, posted again, stand where
    /// they stood and say it did not move at all. Going by the second reading, the seller's
    /// other lines at the top would have other words in them (same speaker, same beginning and
    /// end). The window moved: every line of the talk comes out, and so does what is said next.
    func testLinesSaidAgainDoNotHoldUpTheirNeighbours() {
        func seller(_ wares: String) -> Row { Row("[길드] [Garrik Thane]: selling \(wares) tonight, whisper me for prices", Ink.guild) }
        let talkers = ["Dalla Reed", "Lu Mi", "Sena Dawnpetal", "Petra Voss", "Hank Brill", "Odalys Fenn", "Mira Fenn", "Tovin Marsh",
                       "Bram Oakwind", "Lena Emberfall", "Dorn Flint", "Fenna Pim"]
        let talk = ["다들 어디세요", "저녁 먹고 올게요", "이거 필요하신 분 계세요", "방금 다녀왔어요", "오늘 몇시에 모여요", "조금만 기다려 주세요",
                    "지금 접속했습니다", "퀘스트 같이 하실 분", "가방이 꽉 찼네요", "은행 좀 들렀다 갈게요", "내일은 못 올 것 같아요", "수고하셨습니다 여러분"]
        func other(_ n: Int) -> Row { Row("[길드] [\(talkers[n - 1])]: \(talk[n - 1])", Ink.guild) }
        var log = [seller("copper bars and linen cloth"), seller("heavy leather and wool cloth")] + (1...6).map(other)
            + [seller("mageweave bags and silk bandages"), seller("iron ore and coarse stone")]
        let feed = Feed()
        feed.play(log, opaque: true)
        XCTAssertEqual(feed.everything.count, 10)
        // Eight rows at once: six lines of talk, and the last two of the seller's again.
        log += (7...12).map(other) + [seller("mageweave bags and silk bandages"), seller("iron ore and coarse stone")]
        feed.feed(Screen.frame(log, shown: log.count, opaque: true), times: 2)
        log.append(Row("[길드] [Lu Mi]: 지금 갑니다", Ink.guild))
        feed.feed(Screen.frame(log, shown: log.count, opaque: true), times: 6)
        XCTAssertEqual(feed.bodies.last, "지금 갑니다", "\(feed.texts.suffix(4))")
        XCTAssertEqual(talk.filter { feed.bodies.contains($0) }.count, 12, "every line of the talk came out: \(feed.bodies)")
    }

    /// A whole window of one kind of notice replaced by more of the kind between two captures
    /// (a guild coming online, a pack of creatures dying at once): no row of the old view is
    /// left to tell how far the window moved, and every row reads as the one that stood there
    /// with another name in it. The chat goes on: what the guild says next is out at once.
    func testWindowFullOfOneKindOfNoticeReplacedAtOnceKeepsTheChatGoing() {
        let names = ["Tovin", "Garrik", "Mira", "Petra", "Bram", "Hank", "Odalys", "Lena", "Dorn", "Fenna", "Exa", "Sena", "Dalla", "Jorun", "Nels"]
        func online(_ n: Int) -> Row { Row("\(names[n % names.count])님이 접속했습니다.", Ink.notice) }
        func kill(_ n: Int) -> Row {
            Row("\(["늪지 추적자", "갈대숲 약탈자", "수렁 배회자"][n % 3])이(가) 죽었습니다. \(85 + 5 * (n * 7 % 10))의 경험치를 획득했습니다.", Ink.notice)
        }
        for (kind, row) in [("online", online), ("kill", kill)] as [(String, (Int) -> Row)] {
            for burst in [8, 10, 14] {
                var log = (0..<10).map(row)
                let feed = Feed()
                feed.feed(Screen.frame(log, shown: log.count, opaque: true), times: 8)
                log += (10..<(10 + burst)).map(row)
                feed.feed(Screen.frame(log, shown: log.count, opaque: true), times: 5)
                log.append(Row("[길드] [Lu Mi]: 지금 갑니다", Ink.guild))
                feed.feed(Screen.frame(log, shown: log.count, opaque: true), times: 3)
                XCTAssertEqual(feed.bodies.last, "지금 갑니다", "\(kind), \(burst) at once")
            }
        }
        // Twenty members with nothing in common but the sentence: no row of the new window
        // reads like any row of the old one, and each stands where another's notice stood.
        // In a window that has shown chat before (the columns are known and each notice is a
        // message of its own), in one that never has (cold: the rows are told by their
        // colour), and for a notice in the colour of a player channel.
        let members = ["Brannok Ironvale", "Ysolde Marrowind", "Quillon Ashgrove", "Thessaly Underhill", "Corvane Blackmere", "Wilhelmina Frost",
                       "Jorund Stoneback", "Emberlyn Dusk", "Hargrim Coalbeard", "Seraphine Lowmoor", "Ulvar Greystag", "Nimue Farrow",
                       "Dorrigan Vexmoor", "Alstane Pyke", "Merewyn Holloway", "Kaspian Thornfield", "Odette Ravensworth", "Fenwick Galeborn",
                       "Zephyrine Mossgate", "Rudiger Ashdown"]
        for (name, colour, warm) in [("warm", Ink.notice, true), ("cold", Ink.notice, false), ("guild colour", Ink.guild, true)] {
            var log: [Row] = warm ? opening : []
            let feed = Feed()
            if warm { feed.play(log, opaque: true) }
            log += members.prefix(10).map { Row("\($0)님이 길드에 가입했습니다.", colour) }
            if warm { feed.play(log, from: opening.count + 1, opaque: true) } else { feed.feed(Screen.frame(log, shown: log.count, opaque: true), times: 8) }
            if warm { XCTAssertEqual(feed.everything.count, 12, name) }
            log += members.suffix(10).map { Row("\($0)님이 길드에 가입했습니다.", colour) }
            feed.feed(Screen.frame(log, shown: log.count, opaque: true), times: 3)
            log.append(Row("[길드] [Lu Mi]: 다들 환영합니다", Ink.guild))
            feed.feed(Screen.frame(log, shown: log.count, opaque: true), times: 4)
            XCTAssertEqual(feed.bodies.last, "다들 환영합니다", "\(name): \(feed.texts.suffix(3))")
        }
    }
}

// MARK: - Messages that resemble earlier ones

final class ResemblingMessagesTests: XCTestCase {

    /// A message whose wrapped row says what the end of an earlier message said, from another
    /// speaker, with its header row unreadable for the whole wait: the rows are no news by
    /// themselves, but the message is not lost. When the header row reads, it goes out whole.
    func testMessageThatEndsLikeAnEarlierOneIsNotLost() {
        var log = opening
        log.append(Row("[1. 공개 - 저습지] [Dorn Flint]: can someone tell me where the inn is", Ink.pink))
        log.append(Row("in this town please", Ink.pink, wrapped: true))
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: opening.count), times: 3)
        feed.play(log, from: opening.count + 1)
        log.append(Row("[1. 공개 - 저습지] iMira Fennj is there a flight master somewhere", Ink.pink, confidence: 0.5))
        log.append(Row("in this town please", Ink.pink, wrapped: true))
        feed.feed(Screen.frame(log, shown: log.count), times: 10)
        XCTAssertFalse(feed.everything.contains { $0.isFragment }, "the rows alone say nothing new: \(feed.texts)")
        log[log.count - 2] = Row("[1. 공개 - 저습지] [Mira Fenn]: is there a flight master somewhere", Ink.pink)
        log.append(Row("[길드] [Sena Dawnpetal]: 넵", Ink.guild))
        feed.feed(Screen.frame(log, shown: log.count), times: 10)
        XCTAssertTrue(feed.listed.contains { $0.sender == "Mira Fenn" && $0.body == "is there a flight master somewhere in this town please" },
                      "\(feed.texts)")
        XCTAssertEqual(feed.listed.filter { $0.body.hasSuffix("in this town please") }.count, 2)
        XCTAssertEqual(feed.listed.filter { $0.sender == "Dorn Flint" }.count, 1, "the earlier message is not said again")
    }

    /// Rows of an old message read again without their header are still no news, and a clean
    /// read of that header row does not say the old message a second time.
    func testOldMessageReadAgainWithoutItsHeaderIsNotSaidTwice() {
        var log = opening
        log.append(Row("[1. 공개 - 저습지] [Dorn Flint]: can someone tell me where the inn is", Ink.pink))
        log.append(Row("in this town please", Ink.pink, wrapped: true))
        log.append(Row("[길드] [Sena Dawnpetal]: 넵", Ink.guild))
        let feed = Feed()
        feed.play(log)
        XCTAssertEqual(feed.everything.count, 4)
        var damaged = log
        damaged[3] = Row("[1. 공개 - 저습지] iDorn Flintj can someone tell me where the inn is", Ink.pink, confidence: 0.5)
        feed.feed(Screen.frame(damaged, shown: damaged.count), times: 10)
        feed.feed(Screen.frame(log, shown: log.count), times: 10)
        XCTAssertEqual(feed.everything.count, 4, "\(feed.everything.map(\.rawText))")
    }

    /// The same speaker with another number in the same words is another message, also for
    /// lines that did not arrive as new chat below the newest line.
    func testOtherNumbersAreAnotherMessage() {
        func key(_ text: String) -> LineKey { LineKey(text: text, parsed: ChatLineParser.parse(text, locale: .koKR, color: Ink.pink)) }
        XCTAssertFalse(LineSimilarity.isReRead(key("[길드] [Dalla Reed]: 오늘 몇시에 모여요 16"), of: key("[길드] [Dalla Reed]: 오늘 몇시에 모여요 4")))
        XCTAssertFalse(LineSimilarity.isReRead(key("[1. 공개 - 저습지] [Bram Oakwind]: LF2M deadmines"),
                                               of: key("[1. 공개 - 저습지] [Bram Oakwind]: LF3M deadmines")))
        XCTAssertFalse(LineSimilarity.isReRead(key("[길드] [Lu Mi]: 이거 필요하신 분? 24"), of: key("[길드] [Lu Mi]: 이거 필요하신 분? 6")))
        // What an overlay does to a row is still a re-read: letters change, numbers stay.
        XCTAssertTrue(LineSimilarity.isReRead(key("[7. 안내판] [Bram Oakwind]: NEVER TRUST 설정 WHEN HE OFFERS 2 DISCOUNTS IN A ROW"),
                                              of: key("[1. 공개 - 저습지] [Bram Oakwind]: NEVER TRUST A GOBLIN WHEN HE OFFERS 2 DISCOUNTS IN A ROW")))
        XCTAssertTrue(LineSimilarity.isReRead(key("[7. 안내판] [Bram Oakwind]: LF2M deadmines need"),
                                              of: key("[1. 공개 - 저습지] [Bram Oakwind]: LF2M deadmines need a healer")), "its first part")
    }

    /// The same in the tracker. Late in a long evening the window comes back showing lines
    /// it has not seen (another tab, a scroll): none of them arrives as new chat below the
    /// newest line. One is from a speaker who said nearly the same hours ago, with another
    /// time in it. It is another message and comes out.
    func testNearRepeatThatArrivesOutsideTheLiveFlow() {
        let names = ["Bram Oakwind", "Lena Emberfall", "Tovin Marsh", "Mira Fenn", "Hank Brill", "Odalys Fenn", "Petra Voss", "Garrik Thane"]
        let first = ["hold", "watch", "clear", "skip", "pull", "mark", "kite", "burn", "camp", "scout", "guard", "rush", "check", "avoid", "split",
                     "stack", "flank", "tag", "drag", "nuke"]
        let second = ["the ford", "north gate", "crab cave", "old mill", "red banner", "griffon roost", "cellar door", "east docks", "hill fort",
                      "silver mine", "stone bridge", "marsh road", "watch tower", "fish market", "lumber camp", "goblin stall", "dark crypt",
                      "broken wall", "river bend", "bandit hut", "herb patch", "ogre mound", "spider nest"]
        func line(_ n: Int) -> Row {
            Row("[1. 공개 - 저습지] [\(names[n % names.count])]: \(first[n % first.count]) \(second[(n / first.count + n) % second.count]) now \(n)", Ink.pink)
        }
        var log: [Row] = []
        for n in 0..<430 { log.append(n == 60 ? Row("[길드] [Dalla Reed]: 오늘 몇시에 모여요 4", Ink.guild) : line(n)) }
        let feed = Feed()
        feed.play(log)
        XCTAssertEqual(feed.everything.count, 430)
        XCTAssertEqual(feed.bodies.filter { $0.hasPrefix("오늘 몇시에 모여요") }, ["오늘 몇시에 모여요 4"])

        var other: [Row] = (500..<509).map(line)
        other.append(Row("[길드] [Dalla Reed]: 오늘 몇시에 모여요 16", Ink.guild))
        feed.feed(Screen.frame(other, shown: other.count), times: 8)
        XCTAssertEqual(feed.everything.count, 440, "\(feed.everything.suffix(10).map(\.rawText))")
        XCTAssertEqual(feed.bodies.filter { $0.hasPrefix("오늘 몇시에 모여요") }, ["오늘 몇시에 모여요 4", "오늘 몇시에 모여요 16"])
        // Read once more the same way, it is not said again.
        feed.feed(Screen.frame(other, shown: other.count), times: 4)
        XCTAssertEqual(feed.everything.count, 440)
    }
}

// MARK: - The rest of a link whose closing bracket was not read

final class LinkRestTests: XCTestCase {

    /// "[Staff of" at the end of the header row, and on the wrapped row the rest of the link
    /// with its bracket read as a letter, in the link's own colour (the yellow and orange of
    /// quest links are the colours of notices and emotes, the green of an item that of loot):
    /// one message, whatever is behind the link.
    func testRestOfALinkInItsOwnColourStaysInTheMessage() {
        for (name, colour) in [("yellow", Ink.notice), ("orange", Ink.orange), ("green", Ink.uncommon), ("message", Ink.pink)] {
            for rest in ["the Silver Moonl pst me", "the Silver Moonl", "Silver MoonI 5g"] {
                var log = opening
                log.append(Row("[2. 거래 - 도시] [Exa Stormcaller]: WTS cheap tonight [Staff of", Ink.pink))
                log.append(Row(rest, colour, wrapped: true))
                log.append(Row("[1. 공개 - 저습지] [Fenna Pim]: what about tomorrow", Ink.pink))
                for cold in [false, true] {
                    let feed = Feed()
                    if cold {
                        feed.feed(Screen.frame(log, shown: log.count), times: 6)
                    } else {
                        feed.feed(Screen.frame(log, shown: opening.count), times: 3)
                        feed.play(log, from: opening.count + 1)
                    }
                    XCTAssertEqual(Array(feed.bodies.dropFirst(2)), ["WTS cheap tonight [Staff of " + rest, "what about tomorrow"],
                                   "\(name), \(rest)\(cold ? ", cold" : "")")
                }
            }
        }
    }

    /// A notice of the game on the MESSAGE column below such a row is still a line of its own.
    func testNoticeOnTheMessageColumnBelowAnOpenLinkIsItsOwnLine() {
        var log = opening
        log.append(Row("[길드] [Lu Mi]: 이거 드실 분 [거친 돌", Ink.guild))
        log.append(Row("[리넨 붕대]를 만들었습니다.", RGBColor(r: 0, g: 0.67, b: 0)))
        log.append(Row("[길드] [Sena Dawnpetal]: 넵", Ink.guild))
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: opening.count), times: 3)
        feed.play(log, from: opening.count + 1)
        XCTAssertEqual(Array(feed.bodies.dropFirst(2)), ["이거 드실 분 [거친 돌", "[리넨 붕대]를 만들었습니다.", "넵"], "\(feed.texts)")
    }
}

// MARK: - Short lines with numbers in them

final class NumbersInChatTests: XCTestCase {

    /// Prices, hands, levels and nights as players type them are language, and are sent.
    func testNumberTokensAreNotDebris() {
        for line in ["r u 2h or 1h+shield", "1.5g each", "wts 1.5g", "2.5k gold", "1.2k dps", "5.5k hp", "500g+tip", "mats+5g tip", "t0.5 set",
                     "brd5man lfm", "aq20+zg20", "c u 2nite", "ok 2moro", "4ever alone", "bwl2nite", "2nite?", "lf 5.5k+ tank", "ubrs>lbrs",
                     "need 0.5 set", "10g/stack obo", "wts 50g", "LF1M", "lvl60 mage lf guild"] {
            XCTAssertFalse(LanguageGate.isUnreadable(line), line)
        }
        for line in ["r u 2h or 1h+shield", "1.5g each", "wts 1.5g", "2.5k gold", "1.2k dps", "5.5k hp", "500g+tip", "mats+5g tip", "t0.5 set",
                     "brd5man lfm", "aq20+zg20", "c u 2nite", "ok 2moro", "4ever alone", "bwl2nite", "2nite?"] {
            XCTAssertTrue(LanguageGate.needsTranslation(line, reader: .korean), line)
        }
    }

    /// What OCR makes of Hangul it cannot read is still debris.
    func testDebrisIsStillDebris() {
        for junk in ["o» 7ЛУ t Ф1.", "57||8", "CE024| EE", "2 9024", "14 |У", "| 20N...", "7™|84|8", "E82t91&?", "23% 8", "9|4 54Hg", "4н84at п91",
                     "E82.t91+7ЛУ", "CE024+E82t91"] {
            XCTAssertFalse(LanguageGate.needsTranslation(junk, reader: .korean), junk)
        }
        XCTAssertEqual(LanguageGate.kind(ofToken: "1h+shield"), .word)
        XCTAssertEqual(LanguageGate.kind(ofToken: "1.5g"), .neutral)
        XCTAssertEqual(LanguageGate.kind(ofToken: "2nite"), .code)
        XCTAssertEqual(LanguageGate.kind(ofToken: "E82t91"), .junk)
        XCTAssertEqual(LanguageGate.kind(ofToken: "20N"), .code, "as before: a few capitals around digits are left to the rest of the line")
        XCTAssertEqual(LanguageGate.kind(ofToken: "CE024"), .junk)
    }
}

// MARK: - Names one thin letter apart

final class NamesOneLetterApartTests: XCTestCase {

    /// Two names that are both names go by how often each was seen: a name seen once does not
    /// take over the lines of somebody who has been talking all along.
    func testTwoRealNamesAreNotMergedTowardsTheLongerOne() {
        for (short, long) in [("Kai", "Kali"), ("Mia", "Mila"), ("Marin", "Martin"), ("Jule", "Julie"), ("Ania Vale", "Anita Vale")] {
            var memory = SenderMemory()
            XCTAssertEqual(memory.resolve(short), short)
            XCTAssertEqual(memory.resolve(short), short)
            _ = memory.resolve(long)
            XCTAssertEqual(memory.resolve(short), short, "\(short) stays \(short) after \(long) spoke once")
            XCTAssertEqual(memory.resolve(short), short)
        }
        // A one-off misread with a doubled thin letter does not stick either.
        var memory = SenderMemory()
        for _ in 0..<3 { _ = memory.resolve("Sly Jorvik") }
        XCTAssertEqual(memory.resolve("Sly JJorvik"), "Sly Jorvik")
        XCTAssertEqual(memory.resolve("Sly Jorvik"), "Sly Jorvik")
        // The capital that begins a later word, dropped: that is no name, whatever the counts.
        var other = SenderMemory()
        for _ in 0..<3 { _ = other.resolve("Sly orvik") }
        XCTAssertEqual(other.resolve("Sly Jorvik"), "Sly Jorvik")
        XCTAssertEqual(other.resolve("Sly orvik"), "Sly Jorvik")
        XCTAssertTrue(SenderMemory.lacksWordInitial("Sly orvik", of: "Sly Jorvik"))
        XCTAssertFalse(SenderMemory.lacksWordInitial("Kai", of: "Kali"))
        XCTAssertFalse(SenderMemory.lacksWordInitial("Sly Jorvik", of: "Sly JJorvik"))
    }
}
