import XCTest
import CoreGraphics
@testable import RunespeakCore

// Chat as the capture side sees it in real play on a Korean client: a menu of the game over the
// chat, speech of creatures with quoted nicknames, notices that begin with an item link, wrapped
// links in other colours, rows that go out without their header row, and what OCR makes of text
// it cannot read. All frames are hand-built; all names are invented.

// XCTest pulls in AppKit, which still exports a QuickDraw-era `RGBColor`.
private typealias RGBColor = RunespeakCore.RGBColor

private enum Ink {
    static let pink = RGBColor(r: 0.99, g: 0.76, b: 0.77)       // numbered public channel
    static let guild = RGBColor(r: 0.33, g: 0.95, b: 0.33)
    static let white = RGBColor(r: 1, g: 1, b: 1)
    static let gold = RGBColor(r: 1, g: 0.84, b: 0)
    static let creature = RGBColor(r: 1, g: 1, b: 0.62)         // speech of a creature
    static let loot = RGBColor(r: 0, g: 0.67, b: 0)             // "... 만들었습니다."
    static let notice = RGBColor(r: 1, g: 1, b: 0)
    static let orange = RGBColor(r: 1, g: 0.5, b: 0.25)         // quest link (the colour of an emote)
    static let uncommon = RGBColor(r: 0.12, g: 1, b: 0)
    static let rare = RGBColor(r: 0, g: 0.44, b: 0.87)
    static let epic = RGBColor(r: 0.64, g: 0.21, b: 0.93)
}

/// A chat window with the proportions of a real one on a Retina display: rows 41.6 px apart,
/// messages start at x = 76, wrapped rows 16 px to their right, ten rows, text up to x = 1010.
private enum Screen {
    struct Row {
        var text: String
        var colour: RGBColor
        var wrapped = false
        var confidence = 1.0
        /// Offset of the row's box from its column (box jitter, a row read from a little left).
        var nudge: CGFloat = 0

        init(_ text: String, _ colour: RGBColor, wrapped: Bool = false, confidence: Double = 1, nudge: CGFloat = 0) {
            self.text = text; self.colour = colour; self.wrapped = wrapped; self.confidence = confidence; self.nudge = nudge
        }
    }

    static let size = CGSize(width: 1056, height: 432)
    static let pitch: CGFloat = 41.6
    static let visible = 10
    static let messageX: CGFloat = 76
    static let wrappedX: CGFloat = 92
    static let rightEdge: CGFloat = 1010

    /// Glyph widths of the game's chat font at this size ("[1. 공개 - 저습지] " is 251 px wide).
    static func width(_ c: Character) -> CGFloat {
        if c == " " { return 9 }
        if TextFold.columns(String(c)) == 2 { return 33 }
        if c.isLetter { return c.isUppercase ? 20 : 15 }
        return 10
    }
    static func width(_ text: String) -> CGFloat { text.reduce(0) { $0 + width($1) } }

    static func line(_ row: Row, slot: Int) -> OCRLine {
        let x = (row.wrapped ? wrappedX : messageX) + row.nudge
        return OCRLine(text: row.text, box: CGRect(x: x, y: 11 + CGFloat(slot) * pitch, width: min(width(row.text), rightEdge - x), height: 36),
                       color: row.colour, confidence: row.confidence)
    }

    /// The window after `count` rows of `log` have arrived: the newest ten, bottom-aligned as
    /// the game shows them.
    static func frame(_ log: [Row], shown count: Int) -> OCRFrame {
        let rows = Array(log[max(0, count - visible)..<count])
        let first = visible - rows.count
        return OCRFrame(lines: rows.enumerated().map { line($0.element, slot: first + $0.offset) }, imageSize: size)
    }
}

private typealias Row = Screen.Row

/// Feeds frames to a tracker and keeps the list of lines as the app shows it: a message that
/// stands in for earlier ones (`ChatTracker.corrections`) takes the place of the first of them.
private final class Feed {
    let tracker: ChatTracker
    var clock = Date(timeIntervalSince1970: 1_700_000_000)
    var listed: [ChatMessage] = []
    /// Everything the tracker handed out, in order.
    var everything: [ChatMessage] = []

    init(locale: ClientLocale = .koKR) { tracker = ChatTracker(clientLocale: locale) }

    @discardableResult
    func feed(_ frame: OCRFrame, times: Int = 1) -> [ChatMessage] {
        var all: [ChatMessage] = []
        for _ in 0..<times {
            clock += 0.7
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
    func play(_ log: [Screen.Row], from start: Int = 1, settle: Int = 8) {
        for count in start...log.count { feed(Screen.frame(log, shown: count)) }
        feed(Screen.frame(log, shown: log.count), times: settle)
    }

    var texts: [String] { listed.map(\.rawText) }
}

/// Lines a Korean reader's translator would be asked for, as the app decides it.
private func wouldTranslate(_ message: ChatMessage) -> Bool {
    message.channel.group != nil && LanguageGate.needsTranslation(message, reader: .korean)
}

// MARK: - K3: the game's chat menu over the chat

/// The damage model is distilled from real OCR of chat rows under the menu: the panel hides the
/// columns x 120...346 of every row; left of it the stub of the channel tag is read ("[1.",
/// "[길"), then the menu label, then what is right of the panel. A long label reaches the text
/// on its right and comes out as ONE line; a short one leaves a gap and the row comes out as two.
private enum MenuScene {

    /// Screen rows of the log, oldest first (wrapped rows follow their header row).
    static let rows: [Row] = [
        Row("[1. 공개 - 저습지] [Bram Oakwind]: pushed them back to", Ink.pink),
        Row("the bridge", Ink.pink, wrapped: true),
        Row("[길드] [Sena Dawnpetal]: 다들 어디세요", Ink.guild),
        Row("[1. 공개 - 저습지] [Lena Emberfall]: hold the line here", Ink.pink),
        Row("[1. 공개 - 저습지] [Tovin Marsh]: see you at the gate", Ink.pink),
        Row("[1. 공개 - 저습지] [Uncle Pim]: anyone for the crab", Ink.pink),
        Row("quest later?", Ink.pink, wrapped: true),
        Row("[1. 공개 - 저습지] [Mira Fenn]: they will regroup and come", Ink.pink),
        Row("at us from the hill unless we hold it", Ink.pink, wrapped: true),
        Row("[길드] [Sena Dawnpetal]: 저녁 먹고 올게요", Ink.guild),
        // Arrive while the menu is open.
        Row("[길드] [Dalla Reed]: 이거 필요하신 분?", Ink.guild),
        Row("[1. 공개 - 저습지] [Hank Brill]: thanks for the escort to", Ink.pink),
        Row("the docks", Ink.pink, wrapped: true),
        Row("[1. 공개 - 저습지] [Bram Oakwind]: never trust a goblin", Ink.pink),
        Row("when he offers you a discount", Ink.pink, wrapped: true),
        Row("[길드] [Sena Dawnpetal]: 다녀왔어요", Ink.guild),
        Row("[1. 공개 - 저습지] [Tovin Marsh]: victory", Ink.pink),
    ]
    /// What the players said.
    static let said = [
        "[1. 공개 - 저습지] [Bram Oakwind]: pushed them back to the bridge", "[길드] [Sena Dawnpetal]: 다들 어디세요",
        "[1. 공개 - 저습지] [Lena Emberfall]: hold the line here", "[1. 공개 - 저습지] [Tovin Marsh]: see you at the gate",
        "[1. 공개 - 저습지] [Uncle Pim]: anyone for the crab quest later?",
        "[1. 공개 - 저습지] [Mira Fenn]: they will regroup and come at us from the hill unless we hold it",
        "[길드] [Sena Dawnpetal]: 저녁 먹고 올게요", "[길드] [Dalla Reed]: 이거 필요하신 분?",
        "[1. 공개 - 저습지] [Hank Brill]: thanks for the escort to the docks",
        "[1. 공개 - 저습지] [Bram Oakwind]: never trust a goblin when he offers you a discount",
        "[길드] [Sena Dawnpetal]: 다녀왔어요", "[1. 공개 - 저습지] [Tovin Marsh]: victory",
    ]
    static let speakers: Set<String> = ["Bram Oakwind", "Sena Dawnpetal", "Lena Emberfall", "Tovin Marsh", "Uncle Pim", "Mira Fenn",
                                        "Dalla Reed", "Hank Brill"]

    /// The labels of the menu, top to bottom, and whether they are headings (drawn in gold).
    static let labels: [(text: String, heading: Bool)] = [
        ("편집 모드", false), ("상호작용 비활성화", false), ("창 이름 변경", false), ("새 대화창 생성", false),
        ("디스플레이 설정", true), ("글자 크기", false), ("배경 설정", false), ("필터 설정", true), ("설정", false),
    ]
    static let panel: ClosedRange<CGFloat> = 120...346

    /// The window `offset` rows into the log. `menu`: the menu is open, showing its first
    /// `labelCount` labels inside the captured region.
    static func frame(offset: Int, menu: Bool, labelCount: Int = labels.count) -> OCRFrame {
        var out: [OCRLine] = []
        for slot in 0..<Screen.visible where offset + slot < rows.count {
            let row = rows[offset + slot]
            let label = slot < labelCount ? labels[slot] : nil
            guard menu, let label else {
                out.append(Screen.line(row, slot: slot))
                continue
            }
            let y = 11 + CGFloat(slot) * Screen.pitch
            // What is left of the panel, and what is right of it.
            var left = "", right = "", pen = row.wrapped ? Screen.wrappedX : Screen.messageX
            for c in row.text {
                let w = Screen.width(c)
                if pen + w <= panel.lowerBound + 6 { left.append(c) } else if pen + w / 2 >= panel.upperBound { right.append(c) }
                pen += w
            }
            left = left.trimmingCharacters(in: .whitespaces)
            right = right.trimmingCharacters(in: .whitespaces)
            let labelColour = label.heading ? Ink.gold : Ink.white
            let labelEnd = 140 + CGFloat(TextFold.columns(label.text)) * 12.5
            let stub = [left, label.text].filter { !$0.isEmpty }.joined(separator: " ")
            if !right.isEmpty, panel.upperBound - labelEnd <= 68 {
                // One line: the label reaches the text on its right.
                out.append(OCRLine(text: stub + " " + right, box: CGRect(x: 74, y: y, width: 272 + Screen.width(right), height: 38),
                                   color: right.count > 14 ? row.colour : labelColour, confidence: 0.9))
            } else {
                out.append(OCRLine(text: stub, box: CGRect(x: left.isEmpty ? 138 : 74, y: y + 2, width: max(44, labelEnd - 74), height: 34),
                                   color: labelColour, confidence: 0.67))
                if !right.isEmpty {
                    out.append(OCRLine(text: right, box: CGRect(x: 342, y: y, width: Screen.width(right), height: 38),
                                       color: row.colour, confidence: 1))
                }
            }
        }
        return OCRFrame(lines: out, imageSize: Screen.size)
    }

    static func containsLabel(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        return labels.contains { $0.text.count >= 4 && compact.contains($0.text.filter { !$0.isWhitespace }) }
    }
}

final class ChatMenuTests: XCTestCase {

    func testLabelsAreToldFromChat() {
        // Rows as they were read under the open menu.
        for text in ["[1. 편집 모드 [Bram Oakwind]: pushed them back to", "[1. 상호작용 비활성화 Uncle Pim]: anyone for [Some Quest",
                     "창 이름 변경", "[1. 새 대화창 생성 Lena Emberfall]: hold the line here", "디스플레이 설정 the hill unless we hold it",
                     "[길 디스플레이 설정 Reed]: [늑대가죽 장화] 이거 필요하신분?", "[ 필터 설정", "[1. 필터 설정습지] [Bram Oakwind]: NEVER TRUST",
                     "설정", "글자 크기 [1. fis", "화면 설정"] {
            XCTAssertNotNil(ChatMenu.labelAtStart(of: text, locale: .koKR), text)
        }
        // Chat, also chat about those very settings.
        for text in ["[길드] [Sena Dawnpetal]: 글자 크기 어떻게 바꿔요?", "[1. 공개 - 저습지] [Tovin Marsh]: see you at the gate", "설정 좀 알려주세요",
                     "[길드] [Sena Dawnpetal]: 설정", "the bridge", "[조잡한 연마석]을 만들었습니다."] {
            XCTAssertNil(ChatMenu.labelAtStart(of: text, locale: .koKR), text)
        }
        XCTAssertNotNil(ChatMenu.labelAtStart(of: "[1. Rename Window Oakwind]: pushed them", locale: .enUS))
        XCTAssertNotNil(ChatMenu.labelAtStart(of: "Settings", locale: .enUS))
        XCTAssertNil(ChatMenu.labelAtStart(of: "[Guild] [Sena]: Settings are fine", locale: .enUS))
    }

    func testMenuIsOpenOnlyWithSeveralLabelsInItsOrder() {
        func lines(_ texts: [String]) -> [OCRLine] {
            texts.enumerated().map { Screen.line(Screen.Row($0.element, Ink.white), slot: $0.offset) }
        }
        XCTAssertTrue(ChatMenu.isOpen(over: MenuScene.frame(offset: 0, menu: true).lines, locale: .koKR))
        XCTAssertTrue(ChatMenu.isOpen(over: MenuScene.frame(offset: 5, menu: true).lines, locale: .koKR))
        XCTAssertTrue(ChatMenu.isOpen(over: MenuScene.frame(offset: 3, menu: true, labelCount: 2).lines, locale: .koKR))
        XCTAssertFalse(ChatMenu.isOpen(over: MenuScene.frame(offset: 0, menu: false).lines, locale: .koKR))
        // One label is one row of chat that happens to start that way.
        XCTAssertFalse(ChatMenu.isOpen(over: MenuScene.frame(offset: 0, menu: true, labelCount: 1).lines, locale: .koKR))
        // Two wrapped rows of a talk about the chat settings, in the other order.
        XCTAssertFalse(ChatMenu.isOpen(over: lines(["[길드] [Sena Dawnpetal]: 채팅창 우클릭하면 나와요 거기서", "배경 설정 누르면 되고 글자는",
                                                     "[길드] [Dalla Reed]: 아하", "글자 크기 메뉴에서 바꾸면 돼요"]), locale: .koKR))
        // Labels inside the rows (a menu opened further right): three of them, in order.
        XCTAssertTrue(ChatMenu.isOpen(over: lines(["[1. 공개 - 저습지] [Bram Oak 편집 모드 out of", "the bri 상호작용 비활성화",
                                                    "[길드] [Sena Dawnpe 창 이름 변경 디세요"]), locale: .koKR))
        XCTAssertFalse(ChatMenu.isOpen(over: lines(["[길드] [Sena Dawnpetal]: 글자 크기 어떻게 바꿔요?", "[길드] [Dalla Reed]: 배경 설정 옆에 있어요"]),
                                       locale: .koKR))
    }

    /// The report from the game: the menu is open, new messages keep arriving, the chat scrolls
    /// under the labels. Nothing that went out before goes out again, nobody is given another
    /// player's words, no label is shown as chat, and once the menu is closed every message
    /// that is still on screen comes out once, in order.
    func testChatScrollingUnderTheOpenMenu() {
        let feed = Feed()
        feed.feed(MenuScene.frame(offset: 0, menu: false), times: 4)
        XCTAssertEqual(feed.texts, Array(MenuScene.said.prefix(7)), "before the menu opens")
        let before = feed.everything.count
        for offset in 0...7 { feed.feed(MenuScene.frame(offset: offset, menu: true), times: 3) }
        XCTAssertEqual(feed.everything.count, before, "nothing is reported while the menu is open: \(feed.everything.dropFirst(before).map(\.rawText))")
        feed.feed(MenuScene.frame(offset: 7, menu: false), times: 8)

        XCTAssertEqual(feed.texts, MenuScene.said)
        XCTAssertEqual(feed.everything.count, MenuScene.said.count, "each message once: \(feed.everything.map(\.rawText))")
        for message in feed.everything {
            XCTAssertFalse(MenuScene.containsLabel(message.rawText), message.rawText)
            if let sender = message.sender { XCTAssertTrue(MenuScene.speakers.contains(sender), "nobody is called \(sender)") }
        }
        XCTAssertEqual(feed.everything.filter(wouldTranslate).count, MenuScene.said.filter { $0.hasPrefix("[1.") }.count)
    }

    /// The menu over a chat that does not move, opened and closed again: nothing is added.
    func testMenuOverQuietChatAddsNothing() {
        let feed = Feed()
        feed.feed(MenuScene.frame(offset: 0, menu: false), times: 4)
        feed.feed(MenuScene.frame(offset: 0, menu: true), times: 8)
        feed.feed(MenuScene.frame(offset: 0, menu: false), times: 4)
        feed.feed(MenuScene.frame(offset: 0, menu: true, labelCount: 4), times: 6)
        feed.feed(MenuScene.frame(offset: 0, menu: false), times: 8)
        XCTAssertEqual(feed.texts, Array(MenuScene.said.prefix(7)))
        XCTAssertEqual(feed.everything.count, 7, "\(feed.everything.map(\.rawText))")
    }

    /// One label alone on the bottom row (the rest of the menu and of that row hidden), staying
    /// where it is while new messages arrive, the last row of each under it: the label is never
    /// chat, by itself or as the wrapped row of the message above it.
    func testALoneLabelNeverBecomesChat() {
        let feed = Feed()
        feed.feed(MenuScene.frame(offset: 0, menu: false), times: 4)
        // (A message arrives with all its rows at once.)
        for offset in [0, 1, 3, 5, 6, 7] {
            var frame = MenuScene.frame(offset: offset, menu: false)
            frame.lines[9] = OCRLine(text: "창 이름 변경", box: CGRect(x: 138, y: 13 + 9 * Screen.pitch, width: 160, height: 34),
                                     color: Ink.white, confidence: 0.67)
            feed.feed(frame, times: 2)
        }
        feed.feed(MenuScene.frame(offset: 7, menu: false), times: 8)
        XCTAssertFalse(feed.everything.contains { MenuScene.containsLabel($0.rawText) }, "\(feed.everything.map(\.rawText))")
        XCTAssertEqual(feed.texts, MenuScene.said)
    }

    /// The window is made wider while something covers most of it: the rows still showing
    /// read differently from how their messages went out (more words on the first row, the
    /// rest of the message hidden), so nothing lines up with what is known. What went out is
    /// not said again as its first part.
    func testFirstPartOfAMessageThatWentOutIsNotSaidAgain() {
        let log = Array(MenuScene.rows.prefix(10))
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: log.count), times: 4)
        XCTAssertEqual(feed.everything.count, 7)
        let rewrapped = [
            Row("[1. 공개 - 저습지] [Bram Oakwind]: pushed them back to the bridge", Ink.pink),
            Row("[1. 공개 - 저습지] [Uncle Pim]: anyone for the crab quest", Ink.pink),
            Row("[1. 공개 - 저습지] [Mira Fenn]: they will regroup and come at us from the", Ink.pink),
        ]
        feed.feed(Screen.frame(rewrapped, shown: rewrapped.count), times: 8)
        XCTAssertEqual(feed.everything.count, 7, "\(feed.everything.dropFirst(7).map(\.rawText))")
        XCTAssertEqual(feed.texts, Array(MenuScene.said.prefix(7)))
    }
}

final class MenuParserTests: XCTestCase {
    private func parse(_ text: String, _ colour: RGBColor = Ink.pink) -> ParsedChatLine {
        ChatLineParser.parse(text, locale: .koKR, color: colour)
    }

    /// A numbered channel tag that opens and never closes has something over it: whatever
    /// reads as the speaker behind it is no speaker.
    func testNumberedTagThatNeverClosesIsADamagedHeader() {
        for text in ["[1. 편집 모드 [Bram Oakwind]: pushed them back to", "[1. 새 대화창 생성 Lena Emberfall]: hold the line here",
                     "[1. 상호작용 비활성화 Uncle Pim]: anyone for [Some Quest", "[1. 디스플레이 설정 Tovin Marsh]: GO TO THE GATE",
                     "[1. 공개 - 저습지 [Bram Oakwind]: pushed them back to"] {
            let p = parse(text)
            XCTAssertTrue(p.isDamagedHeader, text)
        }
        // The label of the menu inside a tag that does close.
        XCTAssertTrue(parse("[1. 필터 설정습지] [Bram Oakwind]: NEVER TRUST GOBLINS").isDamagedHeader)
        XCTAssertTrue(parse("[길 디스플레이 설정 Reed]: [늑대가죽 장화] 이거 필요하신분?", Ink.guild).isDamagedHeader)
        // Sound headers stay sound; a tag whose OPENING bracket fell off the edge of the region too.
        for text in ["[1. 공개 - 저습지] [Bram Oakwind]: pushed them back to", "1. 공개 - 저습지] [Bram Oakwind]: pushed them back to",
                     "[2. 거래 - 도시] [Bram Oakwind]: 설정 어디서 바꿔요"] {
            let p = parse(text)
            XCTAssertTrue(p.hasPrefix && !p.isDamagedHeader, text)
            XCTAssertEqual(p.sender, "Bram Oakwind", text)
        }
    }

    /// OCR itself loses the closing bracket of a tag once in a long while. Such a row goes out
    /// after the wait when its channel is known from sound rows, and never under a tag nobody
    /// has seen.
    func testTagWithoutItsBracketGoesOutOnlyUnderAKnownChannel() {
            var log = [Row("[1. 공개 - 저습지] [Tovin Marsh]: see you at the gate", Ink.pink),
                   Row("[길드] [Sena Dawnpetal]: 다들 어디세요", Ink.guild)]
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: 2), times: 3)
        log.append(Row("[1. 공개 - 저습지 [Bram Oakwind]: pushed them back to the bridge", Ink.pink))
        log.append(Row("[길드] [Sena Dawnpetal]: 저녁 먹고 올게요", Ink.guild))
        feed.feed(Screen.frame(log, shown: 4), times: 10)
        XCTAssertEqual(feed.listed.map(\.sender), ["Tovin Marsh", "Sena Dawnpetal", "Bram Oakwind", "Sena Dawnpetal"], "\(feed.texts)")
        XCTAssertEqual(feed.listed[2].body, "pushed them back to the bridge")

        let other = Feed()
        var second = Array(log.prefix(2))
        other.feed(Screen.frame(second, shown: 2), times: 3)
        second.append(Row("[4. 창 정렬 방식 [Bram Oakwind]: pushed them back to the bridge", Ink.pink))
        second.append(Row("[길드] [Sena Dawnpetal]: 저녁 먹고 올게요", Ink.guild))
        other.feed(Screen.frame(second, shown: 4), times: 10)
        XCTAssertFalse(other.everything.contains { $0.sender == "Bram Oakwind" }, "\(other.texts)")
        XCTAssertFalse(other.everything.contains { $0.rawText.contains("창 정렬") }, "\(other.texts)")
    }

    func testReReadOfAMessageThatWentOut() {
        func key(_ text: String) -> LineKey { LineKey(text: text, parsed: parse(text)) }
        let whole = key("[1. 공개 - 저습지] [Bram Oakwind]: pushed them back to the bridge")
        // Its header row alone under another tag, the name with a glyph read differently.
        XCTAssertTrue(LineSimilarity.isReRead(key("[7. 안내판 표시] [Bram Oakwind]: pushed them back to"), of: whole))
        XCTAssertTrue(LineSimilarity.isReRead(key("[7. 안내판 표시] [Bram Oakwlnd]: pushed them back to the bridqe"), of: whole))
        XCTAssertFalse(LineSimilarity.isSameMessage(key("[7. 안내판 표시] [Bram Oakwind]: pushed them back to"), whole))
        // Somebody else, or the same speaker saying another thing.
        XCTAssertFalse(LineSimilarity.isReRead(key("[1. 공개 - 저습지] [Tovin Marsh]: pushed them back to"), of: whole))
        XCTAssertFalse(LineSimilarity.isReRead(key("[1. 공개 - 저습지] [Bram Oakwind]: pushed them into the river"), of: whole))
        XCTAssertFalse(LineSimilarity.isReRead(key("[1. 공개 - 저습지] [Bram Oakwind]: ty"), of: key("[1. 공개 - 저습지] [Bram Oakwind]: ty all")))
        // Wrapped rows that went out alone are part of the message.
        let rows = LineKey(text: "[1. 공개 - 저습지] cute where is it from",
                           parsed: ParsedChatLine(timestamp: nil, channel: .publicChannel, channelLabel: "1. 공개 - 저습지", sender: nil,
                                                  body: "cute where is it from", hasPrefix: true))
        XCTAssertTrue(LineSimilarity.isPart(rows, of: key("[1. 공개 - 저습지] [Dorn Flint]: that owl pet is so cute where is it from")))
        XCTAssertFalse(LineSimilarity.isPart(rows, of: key("[1. 공개 - 저습지] [Dorn Flint]: that owl pet is so cute")))
    }
}

// MARK: - K6, K7: lines of their own on the message column

final class QuotedSpeakerTests: XCTestCase {
    private func parse(_ text: String, _ colour: RGBColor? = Ink.creature, locale: ClientLocale = .koKR) -> ParsedChatLine {
        ChatLineParser.parse(text, locale: locale, color: colour)
    }

    func testCreatureWithAQuotedNicknameSpeaks() {
        let cases: [(String, ChatChannel, String, String, RGBColor)] = [
            ("\"말라깽이\" 토르벤 하크의 말: 내 창고에 그 일에 쓸 연장이 좀 있으니 그걸", .say, "\"말라깽이\" 토르벤 하크", "내 창고에 그 일에 쓸 연장이 좀 있으니 그걸", Ink.creature),
            ("“말라깽이” 토르벤 하크의 말: 어서 오게", .say, "\"말라깽이\" 토르벤 하크", "어서 오게", Ink.creature),
            // OCR writes a space inside the quotes now and then.
            ("\" 말라깽이\" 토르벤 하크의 말: 어서 오게", .say, "\"말라깽이\" 토르벤 하크", "어서 오게", Ink.creature),
            ("\"칼잡이\" 맥 더프의 외침: 다 덤벼라!", .yell, "\"칼잡이\" 맥 더프", "다 덤벼라!", RGBColor(r: 1, g: 0.25, b: 0.25)),
            ("\"칼잡이\" 맥 더프의 귓속말: 조용히 따라오게", .whisper, "\"칼잡이\" 맥 더프", "조용히 따라오게", RGBColor(r: 1, g: 0.5, b: 1)),
            ("말라깽이의 친구의 말: 어서 오게나", .say, "말라깽이의 친구", "어서 오게나", Ink.creature),
            ("토르벤 하크 데 라 크루스의 말: 어서 오게나", .say, "토르벤 하크 데 라 크루스", "어서 오게나", Ink.creature),
        ]
        for (text, channel, sender, body, colour) in cases {
            let p = parse(text, colour)
            XCTAssertTrue(p.hasPrefix && !p.isDamagedHeader, text)
            XCTAssertEqual(p.channel, channel, text)
            XCTAssertEqual(p.sender, sender, text)
            XCTAssertEqual(p.body, body, text)
        }
        let english = parse("\"Slim\" Torben Hark says: meet me at the inn", Ink.creature, locale: .enUS)
        XCTAssertEqual(english.channel, .say)
        XCTAssertEqual(english.sender, "\"Slim\" Torben Hark")
        XCTAssertEqual(parse("Torben O'Hark says: meet me at the inn", Ink.creature, locale: .enUS).sender, "Torben O'Hark")
    }

    /// The same words in the colour of a player channel are a wrapped sentence that happens to
    /// read like a header, as for any speaker without brackets.
    func testQuotedWordsInAChannelColourAreNoHeader() {
        XCTAssertFalse(parse("\"말라깽이\" 그 사람의 말: 이라고 했는데 진짜인지 모르겠음", Ink.pink).hasPrefix)
        XCTAssertFalse(parse("\"gg\" 라고 한 사람의 말: 믿지 마세요", Ink.guild).hasPrefix)
        // One quote, or quotes around nothing, is no nickname.
        XCTAssertFalse(parse("\"말라깽이 토르벤 하크의 말: 어서 오게").hasPrefix)
        XCTAssertFalse(parse("\"\" 토르벤 하크의 말: 어서 오게").hasPrefix)
    }
}

final class OwnLineTests: XCTestCase {

    /// Two lines of chat that fill the window before the scene, so the columns are known.
    private let preamble = [
        Row("[1. 공개 - 저습지] [Tovin Marsh]: anyone selling linen cloth for the tailors here", Ink.pink),
        Row("or some wool", Ink.pink, wrapped: true),
        Row("[길드] [Sena Dawnpetal]: 다들 어디세요", Ink.guild),
    ]

    /// The screen from the game (names invented).
    private let scene: [Row] = [
        Row("[길드] [Mira Dawnsong]: 조심해서 가야겠다", Ink.guild),
        Row("\"말라깽이\" 토르벤 하크의 말: 내 창고에 그 일에 쓸 연장이 좀 있으니 그걸", Ink.creature, nudge: -4),
        Row("챙겨서 주막에서 다시 만나도록 하세나.", Ink.creature, wrapped: true),
        Row("[조잡한 연마석]을 만들었습니다.", Ink.loot, nudge: -4),
        Row("[길드] [Lu Mi]: 법사는", Ink.guild),
        Row("[조잡한 연마석]을 만들었습니다.", Ink.loot, nudge: -4),
        Row("[길드] [Lu Mi]: 먼저 달려들어갔다가", Ink.guild),
        Row("[조잡한 연마석]을 만들었습니다.", Ink.loot, nudge: -4),
        Row("[길드] [Hazel Monk]: 사냥꾼을 그래서 요즘에", Ink.guild),
        Row("[길드] [Lu Mi]: 안되겠다 싶으면 얼리고 점멸 ㅌㅌ", Ink.guild),
    ]
    private let wanted: [(ChatChannel, String?, String)] = [
        (.guild, "Mira Dawnsong", "조심해서 가야겠다"),
        (.say, "\"말라깽이\" 토르벤 하크", "내 창고에 그 일에 쓸 연장이 좀 있으니 그걸 챙겨서 주막에서 다시 만나도록 하세나."),
        (.system, nil, "[조잡한 연마석]을 만들었습니다."),
        (.guild, "Lu Mi", "법사는"),
        (.system, nil, "[조잡한 연마석]을 만들었습니다."),
        (.guild, "Lu Mi", "먼저 달려들어갔다가"),
        (.system, nil, "[조잡한 연마석]을 만들었습니다."),
        (.guild, "Hazel Monk", "사냥꾼을 그래서 요즘에"),
        (.guild, "Lu Mi", "안되겠다 싶으면 얼리고 점멸 ㅌㅌ"),
    ]

    private func check(_ feed: Feed, skipping: Int, _ note: String, file: StaticString = #filePath, line: UInt = #line) {
        let got = feed.listed.dropFirst(skipping).map { "\($0.channel.rawValue)|\($0.sender ?? "-")|\($0.body)" }
        let want = wanted.map { "\($0.0.rawValue)|\($0.1 ?? "-")|\($0.2)" }
        XCTAssertEqual(got, want, note, file: file, line: line)
        XCTAssertEqual(feed.everything.count, feed.listed.count, "\(note): nothing is said twice", file: file, line: line)
    }

    func testCreatureSpeechAndCraftingNoticesAreLinesOfTheirOwn() {
        let feed = Feed()
        let log = preamble + scene
        feed.feed(Screen.frame(log, shown: preamble.count), times: 3)
        feed.play(log, from: preamble.count + 1)
        check(feed, skipping: 2, "rows arriving one by one")

        // The whole screen at once (the app was started, or the tab switched, with it showing).
        let cold = Feed()
        cold.feed(Screen.frame(log, shown: log.count), times: 6)
        check(cold, skipping: cold.listed.count - wanted.count, "the whole screen at once")
    }

    /// Before the scene the window showed nothing but short guild lines and crafting notices
    /// for a long while, every notice on the message column right below a header row. That
    /// must not teach the tracker that this window does not indent wrapped rows (which made
    /// every later row on the message column "a wrapped row").
    func testNoticesUnderHeaderRowsDoNotUnlearnTheWrapIndent() {
        var log = preamble
        let items = ["조잡한 연마석", "일반 숫돌", "구리 주괴", "청동 주괴"]
        for n in 0..<24 {
            log.append(Row("[길드] [Lu Mi]: \(["넵", "법사는", "ㅇㅋ", "그담에 얼음창 이거도 찍죠?"][n % 4])", Ink.guild, nudge: n % 3 == 0 ? -8 : 0))
            log.append(Row("[\(items[n % 4])]\(n % 4 >= 2 ? "를" : "을") 만들었습니다.", Ink.loot, nudge: CGFloat(n % 5) * 2 - 4))
        }
        let before = log.count
        log += scene
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: preamble.count), times: 3)
        // Every view is read several times, as a quiet chat is.
        for count in (preamble.count + 1)...log.count { feed.feed(Screen.frame(log, shown: count), times: count % 4 == 0 ? 5 : 1) }
        feed.feed(Screen.frame(log, shown: log.count), times: 8)
        check(feed, skipping: 2 + (before - preamble.count), "after many notices")
        let notices = feed.listed.filter { $0.channel == .system }
        XCTAssertEqual(notices.count, 24 + 3)
        XCTAssertTrue(notices.allSatisfy { $0.body.hasSuffix("만들었습니다.") })
        XCTAssertFalse(feed.listed.contains { $0.channel != .system && $0.body.contains("만들었습니다") }, "\(feed.texts)")
    }

    /// The rows as the recogniser used to deliver them: the notice cut down to its link and the
    /// particle glued to it, in the white of the link, and the creature's header not recognised.
    /// Even so, a row on the message column in another colour is no wrapped row of the chat
    /// line above it.
    func testARowOnTheMessageColumnInAnotherColourIsNeverAContinuation() {
        var log = preamble
        log.append(Row("[길드] [Lu Mi]: 그담에 얼음창 이거도 찍죠?", Ink.guild))
        log.append(Row("[일반 숫돌]을", Ink.white, nudge: -4))
        log.append(Row("[1. 공개 - 저습지] [Tovin Marsh]: im pulling the big one now so stay back a little", Ink.pink))
        log.append(Row("[조잡한 연마석]을", Ink.white, nudge: -4))
        log.append(Row("[길드] [Lu Mi]: 넵", Ink.guild))
        log.append(Row("경험치 120을 획득했습니다.", RGBColor(r: 0.44, g: 0.44, b: 1), nudge: -2))
        log.append(Row("[길드] [Sena Dawnpetal]: 수고하셨어요", Ink.guild))
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: preamble.count), times: 3)
        feed.play(log, from: preamble.count + 1)
        let chat = feed.listed.filter { $0.sender != nil }
        XCTAssertEqual(chat.map(\.body).suffix(4), ["그담에 얼음창 이거도 찍죠?", "im pulling the big one now so stay back a little", "넵", "수고하셨어요"],
                       "\(feed.texts)")
        XCTAssertFalse(chat.contains { $0.body.contains("숫돌") || $0.body.contains("연마석") || $0.body.contains("경험치") }, "\(feed.texts)")
    }

    /// For a long while the window shows short guild lines and, right below each, a notice cut
    /// down to its link (as the recogniser delivered them once) on the message column. None of
    /// those rows is a wrapped row, and they must not teach the tracker that this window does
    /// not indent wrapped rows: after them, such a row below a FULL row of chat is still a
    /// line of its own, because it stands on the message column.
    func testRowsOnTheMessageColumnDoNotUnlearnTheWrapIndent() {
        var log = preamble
        for n in 0..<30 {
            log.append(Row("[길드] [Lu Mi]: \(["넵", "법사는", "ㅇㅋ", "그담에 얼음창 이거도 찍죠?"][n % 4])", Ink.guild, nudge: n % 3 == 0 ? -8 : 0))
            log.append(Row(n % 2 == 0 ? "[일반 숫돌]을" : "[조잡한 연마석]을", Ink.white, nudge: CGFloat(n % 5) * 2 - 4))
        }
        log.append(Row("[1. 공개 - 저습지] [Tovin Marsh]: im pulling the big one now so stay back a little", Ink.pink))
        log.append(Row("[조잡한 연마석]을", Ink.white, nudge: -4))
        log.append(Row("[길드] [Mira Dawnsong]: 조심해서 가야겠다 그냥 지나가는 게 좋겠어요 여기는 너무 위험해서요", Ink.guild))
        log.append(Row("[일반 숫돌]을", Ink.white, nudge: -4))
        log.append(Row("[길드] [Sena Dawnpetal]: 수고하셨어요", Ink.guild))
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: preamble.count), times: 3)
        for count in (preamble.count + 1)...log.count { feed.feed(Screen.frame(log, shown: count), times: count % 3 == 0 ? 6 : 1) }
        feed.feed(Screen.frame(log, shown: log.count), times: 8)
        let chat = feed.listed.filter { $0.sender != nil }
        XCTAssertEqual(chat.map(\.body).suffix(3), ["im pulling the big one now so stay back a little",
                                                    "조심해서 가야겠다 그냥 지나가는 게 좋겠어요 여기는 너무 위험해서요", "수고하셨어요"], "\(feed.texts.suffix(8))")
        XCTAssertFalse(chat.contains { $0.body.contains("숫돌") || $0.body.contains("연마석") }, "\(feed.texts)")
    }

    /// The app starts (or the tab is switched) with a notice that begins with a link right
    /// below a full row of chat, before anything is known about how this window indents: the
    /// colour of the notice's own text, not that of its link, says it is a line of its own.
    func testNoticeThatBeginsWithALinkBelowAFullRowAtAColdStart() {
        let log = [
            Row("[1. 공개 - 저습지] [Tovin Marsh]: im pulling the big one now so stay back a little", Ink.pink),
            Row("[조잡한 연마석]을 만들었습니다.", Ink.loot, nudge: -4),
            Row("[길드] [Mira Dawnsong]: 조심해서 가야겠다 그냥 지나가는 게 좋겠어요 여기는 너무 위험해서요", Ink.guild),
            Row("[구리 주괴]를 만들었습니다.", Ink.loot, nudge: -4),
            Row("[길드] [Sena Dawnpetal]: 수고하셨어요", Ink.guild),
        ]
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: log.count), times: 6)
        XCTAssertEqual(feed.listed.map(\.body), ["im pulling the big one now so stay back a little", "[조잡한 연마석]을 만들었습니다.",
                                                 "조심해서 가야겠다 그냥 지나가는 게 좋겠어요 여기는 너무 위험해서요", "[구리 주괴]를 만들었습니다.", "수고하셨어요"])
        XCTAssertEqual(feed.listed.map(\.channel), [.publicChannel, .system, .guild, .system, .guild])
    }

    /// The other direction: links in their own colours inside a chat message, at the end of a
    /// row and on the wrapped row below, stay in the message.
    func testChatMessagesKeepTheirLinks() {
        var log = preamble
        // A link that wraps, the wrapped row all link: sampled in the link's colour.
        log.append(Row("[2. 거래 - 도시] [Odalys Fenn]: WTS cheap today [Blade of Eternal", Ink.pink))
        log.append(Row("Darkness]", Ink.epic, wrapped: true))
        // Text behind the end of the link: sampled in the message colour.
        log.append(Row("[2. 거래 - 도시] [Hexa Bloom]: Selling this [Staff of the Silver", Ink.pink))
        log.append(Row("Moon] to the best offer tonight", Ink.pink, wrapped: true))
        // A wrapped row that begins with a whole link.
        log.append(Row("[길드] [Lu Mi]: 이거 드실 분 계신가요 지금 막 나왔는데 필요하시면 말씀해주세요", Ink.guild))
        log.append(Row("[화염의 단검] 입니다", Ink.guild, wrapped: true))
        log.append(Row("[길드] [Sena Dawnpetal]: 저요", Ink.guild))
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: preamble.count), times: 3)
        feed.play(log, from: preamble.count + 1)
        XCTAssertEqual(feed.listed.dropFirst(2).map(\.body), [
            "WTS cheap today [Blade of Eternal Darkness]", "Selling this [Staff of the Silver Moon] to the best offer tonight",
            "이거 드실 분 계신가요 지금 막 나왔는데 필요하시면 말씀해주세요 [화염의 단검] 입니다", "저요",
        ], "\(feed.texts)")
    }

    /// Loot and crafting notices, own and other players', with the link at either end.
    func testNoticesWithLinksStayWhole() {
        var log = preamble
        let notices = ["[조잡한 연마석]을 만들었습니다.", "아이템을 획득했습니다: [리넨 옷감]x3", "Lu Mi님이 아이템을 획득했습니다: [구리 광석]x2",
                       "[청동 주괴]를 2개 만들었습니다.", "Lu Mi님이 [일반 숫돌]을 만들었습니다."]
        for (n, text) in notices.enumerated() {
            log.append(Row("[길드] [Lu Mi]: \(["넵", "잠시만요 금방 갑니다", "ㅇㅋ", "법사는", "ㄱㄱ"][n])", Ink.guild))
            log.append(Row(text, Ink.loot, nudge: -4))
        }
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: preamble.count), times: 3)
        feed.play(log, from: preamble.count + 1)
        XCTAssertEqual(feed.listed.filter { $0.channel == .system }.map(\.body), notices, "\(feed.texts)")
        XCTAssertEqual(feed.listed.filter { $0.channel == .guild }.map(\.body).suffix(5), ["넵", "잠시만요 금방 갑니다", "ㅇㅋ", "법사는", "ㄱㄱ"])
        XCTAssertFalse(feed.listed.dropFirst(2).contains(where: wouldTranslate), "nothing here is foreign")
    }
}

// MARK: - K9: links that wrap, in any colour

final class WrappedLinkTests: XCTestCase {

    private let preamble = [
        Row("[1. 공개 - 저습지] [Tovin Marsh]: anyone selling linen cloth for the tailors here", Ink.pink),
        Row("or some wool", Ink.pink, wrapped: true),
        Row("[길드] [Sena Dawnpetal]: 다들 어디세요", Ink.guild),
    ]

    /// Three quest links in a row, the first wrapping: the wrapped row is all link, in the
    /// orange of an emote, and begins in the middle of a link. Read perfectly and read with the
    /// brackets as thin letters, it is the rest of the message above.
    func testRunOfLinksOnTheWrappedRow() {
        let wanted = "LFG[The Old Iron Vow][Bring Back a Ring][The Marrow Span]"
        let reads: [(String, String)] = [
            ("LFG[The Old Iron", "Vow][Bring Back a Ring][The Marrow Span]"),
            ("LFG[The Old Iron", "Vow][Bring Back a Ringl[The Marrow Span]"),
            ("LFG[The Old Iron", "Vow][Bring Back a RingI[The Marrow Span]"),
            ("LFG[The Old Iron", "Vow][Bring Back a Ring|[The Marrow Span]"),
            ("LFGlThe Old Iron", "Vow][Bring Back a Ring][The Marrow Span]"),
            ("LFGIThe Old Iron", "Vow][Bring Back a Ringi[The Marrow Span]"),
        ]
        for colour in [Ink.orange, Ink.notice, Ink.uncommon, Ink.white, Ink.rare, Ink.epic] {
            for (head, tail) in reads {
                var log = preamble
                log.append(Row("[1. 공개 - 저습지] [Exa Stormcaller]: " + head, Ink.pink))
                log.append(Row(tail, colour, wrapped: true))
                log.append(Row("[1. 공개 - 저습지] [Fenna Pim]: what about tomorrow", Ink.pink))
                let feed = Feed()
                feed.feed(Screen.frame(log, shown: preamble.count), times: 3)
                feed.play(log, from: preamble.count + 1)
                XCTAssertEqual(feed.listed.dropFirst(2).map(\.body), [wanted, "what about tomorrow"], "\(head) / \(tail) in \(colour)")
                XCTAssertEqual(feed.everything.count, 4)
            }
        }
    }

    func testEvidentBracketMisreadsAreMended() {
        func mend(_ s: String) -> String { ChatLinks.mendBrackets(inBody: s) }
        XCTAssertEqual(mend("LFG[The Old Iron Vow][Bring Back a Ringl[The Marrow Span]"), "LFG[The Old Iron Vow][Bring Back a Ring][The Marrow Span]")
        XCTAssertEqual(mend("LFGlThe Old Iron Vow][Bring Back a Ring][The Marrow Span]"), "LFG[The Old Iron Vow][Bring Back a Ring][The Marrow Span]")
        XCTAssertEqual(mend("WTS [Iron BarI[Copper Bar] cheap"), "WTS [Iron Bar][Copper Bar] cheap")
        XCTAssertEqual(mend("WTS [Iron Bar|[Copper Bar] cheap"), "WTS [Iron Bar][Copper Bar] cheap")
        XCTAssertEqual(mend("LFG[The Old Iron Vow][Bring Back a Ring]The Marrow Span]"), "LFG[The Old Iron Vow][Bring Back a Ring][The Marrow Span]")
        // Nothing evident: text as it may well have been typed.
        for s in ["WTS [Iron Bar] and [Copper Bar] cheap", "lol :] nice", "I need [Iron Bar] now", "Small talk] here", "MILITIAS] UNITE",
                  "[조잡한 연마석] 팝니다", "anyone [1/2] here"] {
            XCTAssertEqual(mend(s), s)
        }
    }

    func testLinksAloneAreNotLanguage() {
        for text in ["[The Old Iron Vow][Bring Back a Ring][The Marrow Span]", "Vow][Bring Back a Ring][The Marrow Span]",
                     "[Blade of Eternal", "[조잡한 연마석]", "[Staff of Jordan] [Moss Agate]", "Darkness]", "Hand of Ragnaros] x2"] {
            XCTAssertFalse(LanguageGate.needsTranslation(text, reader: .korean), text)
        }
        XCTAssertTrue(LanguageGate.isOnlyLinks("[The Old Iron Vow][Bring Back a Ring]"))
        XCTAssertTrue(LanguageGate.isOnlyLinks("Vow][Bring Back a Ring][The Marrow Span]"))
        XCTAssertFalse(LanguageGate.isOnlyLinks("LFG [The Old Iron Vow]"))
        XCTAssertFalse(LanguageGate.isOnlyLinks("what about tomorrow"))
        // Words around a link are language as before.
        XCTAssertTrue(LanguageGate.needsTranslation("LFG [The Old Iron Vow] need healer", reader: .korean))
        XCTAssertTrue(LanguageGate.needsTranslation("WTS [Blade of Eternal Darkness] cheap pst me", reader: .korean))
        XCTAssertTrue(LanguageGate.needsTranslation("LFG[The Old Iron Vow][Bring Back a Ring][The Marrow Span]", reader: .korean))
    }

    func testLatinModelMendsBracketsBetweenLinks() {
        func merged(_ k: String, _ l: String) -> String? {
            ScriptChoice.mergeEquivalent(Array(k), Array(l)).map { String($0.map(\.character)) }
        }
        XCTAssertEqual(merged("RingllThe", "RingI[The"), "RingI[The")
        XCTAssertEqual(merged("RinglThe", "Ring|[The"), "Ring|[The")
        XCTAssertEqual(merged("Ringilhe", "Ring|[The"), "Ring|[The")
        XCTAssertEqual(merged("RingllThe", "Ring][The"), "Ring][The")
        // The bracket that closes a link, skipped where the colour changes behind it, and the
        // bracket in front of the speaker colon read as a letter that is no thin one.
        XCTAssertEqual(merged("Will", "Will]"), "Will]")
        XCTAssertEqual(merged("Flintg:", "Flint]:"), "Flint]:")
        XCTAssertEqual(merged("orvikl:", "Jorvik]:"), "Jorvik]:")
        // Two thin strokes in front of the colon where the other model has only the bracket:
        // the name's own "l" and the bracket. With the "i" read by both, it is an "i".
        XCTAssertEqual(merged("Tharil:", "Thar]:"), "Tharl]:")
        XCTAssertEqual(merged("Tharil:", "Thar]"), "Tharl]:")
        // Case is taken from the other model for letters drawn alike small and large, but not
        // into a word nobody writes.
        XCTAssertEqual(merged("Summon", "summon"), "summon")
        XCTAssertNil(merged("Rowan", "ROwan"))
        XCTAssertEqual(merged("Tammil:", "Tammi]:"), "Tammi]:")
        XCTAssertNil(merged("ember", "member"), "only a capital, in front of the very same word")
        XCTAssertNil(merged("orvik", "Jarvik"))
        // No bracket on the Latin side, or other letters between: not taken.
        XCTAssertNil(merged("RingllThe", "RingIIThe"))
        XCTAssertNil(merged("Ringalore", "Ring][ore"))
        XCTAssertNil(merged("Ringilhe", "Ring|[she"))
    }
}

// MARK: - K8: rows that go out without their header row

final class FragmentTests: XCTestCase {

    private let preamble = [
        Row("[1. 공개 - 저습지] [Tovin Marsh]: anyone selling linen cloth for the tailors here", Ink.pink),
        Row("or some wool", Ink.pink, wrapped: true),
        Row("[길드] [Sena Dawnpetal]: 다들 어디세요", Ink.guild),
    ]

    /// The header row of a wrapped message reads as damaged for the whole wait (the picture
    /// does not change, so it is not read again): its wrapped row goes out alone, marked as a
    /// fragment, and is never sent for translation. When the row is read soundly the whole
    /// message takes the fragment's place: one entry, one translation.
    func testWrappedRowWithoutItsHeaderIsAFragmentUntilTheWholeMessageIsRead() {
        var log = preamble
        log.append(Row("[1. 공개 - 저습지] iDorn Flintj that owl pet is so", Ink.pink, confidence: 0.5))
        log.append(Row("cute where is it from", Ink.pink, wrapped: true))
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: preamble.count), times: 3)
        feed.feed(Screen.frame(log, shown: log.count), times: 9)

        XCTAssertEqual(feed.listed.count, 3, "\(feed.texts)")
        guard let fragment = feed.listed.last, feed.listed.count == 3 else { return }
        XCTAssertTrue(fragment.isFragment)
        XCTAssertNil(fragment.sender)
        XCTAssertEqual(fragment.body, "cute where is it from")
        XCTAssertEqual(fragment.channel, .publicChannel)
        XCTAssertFalse(wouldTranslate(fragment), "half a sentence is not translated by itself")
        XCTAssertFalse(feed.listed.dropLast().contains(where: \.isFragment))

        // The next line arrives; the picture changes and the header row reads soundly.
        log[3] = Row("[1. 공개 - 저습지] [Dorn Flint]: that owl pet is so", Ink.pink)
        log.append(Row("[길드] [Sena Dawnpetal]: 더있나?", Ink.guild))
        feed.feed(Screen.frame(log, shown: log.count), times: 8)

        XCTAssertEqual(feed.listed.map(\.body), ["anyone selling linen cloth for the tailors here or some wool", "다들 어디세요",
                                                 "that owl pet is so cute where is it from", "더있나?"])
        let whole = feed.listed[2]
        XCTAssertFalse(whole.isFragment)
        XCTAssertEqual(whole.sender, "Dorn Flint")
        XCTAssertTrue(wouldTranslate(whole))
        XCTAssertEqual(feed.everything.filter(wouldTranslate).map(\.body),
                       ["anyone selling linen cloth for the tailors here or some wool", "that owl pet is so cute where is it from"],
                       "one request per message")
    }

    /// Rows under a header row that was not read at all.
    func testRowsWhoseHeaderRowWasNeverReadAreAFragment() {
        var log = preamble
        log.append(Row("[1. 공개 - 저습지] [Dorn Flint]: that owl pet is so", Ink.pink))
        log.append(Row("cute where is it from", Ink.pink, wrapped: true))
        let feed = Feed()
        feed.feed(Screen.frame(log, shown: preamble.count), times: 3)
        var hidden = Screen.frame(log, shown: log.count)
        hidden.lines.remove(at: hidden.lines.count - 2)
        feed.feed(hidden, times: 9)
        XCTAssertEqual(feed.listed.last?.body, "cute where is it from", "\(feed.texts)")
        XCTAssertEqual(feed.listed.last?.isFragment, true)
        XCTAssertFalse(feed.listed.last.map(wouldTranslate) ?? true)
        feed.feed(Screen.frame(log, shown: log.count), times: 8)
        XCTAssertEqual(feed.listed.last?.body, "that owl pet is so cute where is it from")
        XCTAssertEqual(feed.listed.last?.isFragment, false)
        XCTAssertEqual(feed.listed.count, 3, "\(feed.texts)")
    }

    func testWholeMessagesAreNoFragments() {
        let feed = Feed()
        feed.feed(Screen.frame(preamble, shown: preamble.count), times: 4)
        XCTAssertEqual(feed.listed.count, 2)
        XCTAssertFalse(feed.listed.contains(where: \.isFragment))
        // The flag survives coding, and a message stored without it is none.
        let fragment = ChatMessage(channel: .publicChannel, channelLabel: "1. 공개", sender: nil, body: "cute where is it from",
                                   rawText: "[1. 공개] cute where is it from", color: Ink.pink, firstSeen: Date(timeIntervalSince1970: 0), isFragment: true)
        let data = try! JSONEncoder().encode(fragment)
        XCTAssertEqual(try! JSONDecoder().decode(ChatMessage.self, from: data), fragment)
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["isFragment"] = nil
        let old = try! JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(old.isFragment)
    }

    func testAFragmentIsReplacedInPlace() {
        func entry(_ body: String, fragment: Bool = false) -> ChatEntry {
            ChatEntry(message: ChatMessage(channel: .publicChannel, channelLabel: "1. 공개", sender: fragment ? nil : "Dorn Flint", body: body,
                                           rawText: body, color: Ink.pink, firstSeen: Date(timeIntervalSince1970: 0), isFragment: fragment),
                      state: .original)
        }
        var entries = [entry("first"), entry("cute where is it from", fragment: true), entry("third")]
        let whole = entry("that owl pet is so cute where is it from")
        entries.place(whole, replacing: [entries[1].id])
        XCTAssertEqual(entries.map(\.message.body), ["first", "that owl pet is so cute where is it from", "third"])
        XCTAssertEqual(ChatDisplay.body(for: entry("cute where is it from", fragment: true).message), "… cute where is it from")
        XCTAssertEqual(ChatDisplay.body(for: whole.message), "that owl pet is so cute where is it from")
    }
}

// MARK: - K2: what OCR makes of text it cannot read is not sent to the translator

final class UnreadableTextTests: XCTestCase {

    func testDebrisIsNeverSent() {
        // Bodies from real play: Hangul read by the model that cannot read it.
        let junk = ["o» 7ЛУ t Ф1.", "57||8", "CE024| EE", "АНZИ4ФЕ0Ч241 тт", "[Gnarled Root]9|4 54Hg", "Nm SO|8ЖЕЧ||&", "ачю UХЕyоu",
                    "7™|84|8", "E82t91&?", "NE94 аau ЛEЧO dA", "‡ Л| ЯИE", "4н84at п91", "£ůЧ?", "£ЯЧ?", "2 9024", "14 |У", "| 20N...",
                    "23% 8", "S7E", "14 |4У"]
        for text in junk {
            XCTAssertFalse(LanguageGate.needsTranslation(text, reader: .korean), text)
        }
        for text in ["o» 7ЛУ t Ф1.", "CE024| EE", "АНZИ4ФЕ0Ч241 тт", "Nm SO|8ЖЕЧ||&", "ачю UХЕyоu", "7™|84|8", "E82t91&?", "NE94 аau ЛEЧO dA",
                     "‡ Л| ЯИE", "4н84at п91", "£ůЧ?", "14 |У", "[Gnarled Root]9|4 54Hg"] {
            XCTAssertTrue(LanguageGate.isUnreadable(text), text)
        }
    }

    func testShortChatIsStillSent() {
        // Short as it is, this is language a Korean reader may need.
        for text in ["wassup", "wts 50g", "inv", "LF1M", "LF2M UBRS need healer", "ty for the run", "omw 2 min", "5g50s each pls", "t2 set please",
                     "he||o there friend", "anyone need 5v5?", "its over at the north gate", "if you are close get your *!@ over here",
                     "привет всем, кто идёт в рейд", "有人一起打副本吗", "¿alguien para mazmorras?", "heading to the keep, they have 40s in their party",
                     "ony8 tonight?", "need 1 more dps", "WTS [Iron Bar] 2g ea", "| need help with this quest"] {
            XCTAssertFalse(LanguageGate.isUnreadable(text), text)
            XCTAssertTrue(LanguageGate.needsTranslation(text, reader: .korean), text)
        }
        // Read by everybody without help, as before: not debris, and not sent either.
        for text in ["gg", "ty", "lol", "?", "??", "...", "ㅋㅋㅋ", "ㄷㄷ", "ㅠㅠ", "100", "2 3", ":)", "^^"] {
            XCTAssertFalse(LanguageGate.isUnreadable(text), text)
            XCTAssertFalse(LanguageGate.needsTranslation(text, reader: .korean), text)
        }
        // Korean, with digits and game terms in it.
        for text in ["20렙 3개 구함", "DPS구함 MC가실분", "비싼템인데 ㄷㄷ", "우편함확인해도안들어왔네 ㅠㅠ", "그럴거면 저도 불러요!!", "t2셋 있음"] {
            XCTAssertFalse(LanguageGate.isUnreadable(text), text)
            XCTAssertFalse(LanguageGate.needsTranslation(text, reader: .korean), text)
        }
    }

    /// A Korean line that went out is not replaced by debris read on the same row later, however
    /// sure OCR claims to be of it.
    func testDebrisDoesNotReplaceALineThatWentOut() {
            func log(_ body: String) -> [Row] {
            [Row("[1. 공개 - 저습지] [Tovin Marsh]: see you at the gate", Ink.pink),
             Row("[길드] [Sena Dawnpetal]: \(body)", Ink.guild),
             Row("[길드] [Dalla Reed]: 저녁 먹고 올게요 다들 수고하세요", Ink.guild)]
        }
        for good in ["그거 법사님", "와 재밌겠다", "비싼템인데 ㄷㄷ", "왜 안오시는..."] {
            let feed = Feed()
            feed.feed(Screen.frame(log(good), shown: 3), times: 4)
            feed.feed(Screen.frame(log("14 |4У"), shown: 3), times: 6)
            XCTAssertEqual(feed.listed.map(\.body), ["see you at the gate", good, "저녁 먹고 올게요 다들 수고하세요"], good)
            XCTAssertEqual(feed.everything.count, 3, good)
        }
    }

    func testAMessageIsJudgedAsAWhole() {
        func message(_ body: String, fragment: Bool = false, channel: ChatChannel = .publicChannel) -> ChatMessage {
            ChatMessage(channel: channel, channelLabel: nil, sender: fragment ? nil : "Dorn Flint", body: body, rawText: body, color: Ink.pink,
                        firstSeen: Date(timeIntervalSince1970: 0), isFragment: fragment)
        }
        XCTAssertTrue(LanguageGate.needsTranslation(message("that owl pet is so cute where is it from"), reader: .korean))
        XCTAssertFalse(LanguageGate.needsTranslation(message("cute where is it from", fragment: true), reader: .korean))
        XCTAssertFalse(LanguageGate.needsTranslation(message("Vow][Bring Back a Ring][The Marrow Span]"), reader: .korean))
        XCTAssertFalse(LanguageGate.needsTranslation(message("o» 7ЛУ t Ф1."), reader: .korean))
        XCTAssertFalse(LanguageGate.needsTranslation(message("그거 법사님"), reader: .korean))
        XCTAssertTrue(LanguageGate.needsTranslation(message("그거 법사님"), reader: .english))
        XCTAssertFalse(LanguageGate.needsTranslation(message("그거", fragment: true), reader: .english))
    }
}

// MARK: - K1: one spelling per sender

final class SenderSpellingTests: XCTestCase {

    /// What OCR does to the thin letters and the case of a Latin name is mended in the name
    /// itself, before anything is remembered.
    func testNameLettersAreMended() {
        func sender(_ text: String) -> String? { ChatLineParser.parse(text, locale: .koKR, color: Ink.guild).sender }
        XCTAssertEqual(sender("[길드] [Dorn lronvale]: 그거 법사님"), "Dorn Ironvale")
        XCTAssertEqual(sender("[길드] [Wren TharI]: 넵"), "Wren Tharl")
        XCTAssertEqual(sender("[길드] [Wren Thar/]: 20렙 3개 구함"), "Wren Tharl")
        XCTAssertEqual(sender("[길드] [odo Marsh]: 비싼템인데 ㄷㄷ"), "Odo Marsh")
        XCTAssertEqual(sender("[길드] [Odo Marsh]: 비싼템인데 ㄷㄷ"), "Odo Marsh")
        // Names that are what they are.
        XCTAssertEqual(sender("[길드] [Illidan Stormrage]: 넵"), "Illidan Stormrage")
        XCTAssertEqual(sender("[길드] [달빛기사]: 넵"), "달빛기사")
        XCTAssertEqual(sender("[길드] [Hand of Odo]: 넵"), "Hand of Odo")
    }

    /// The spelling seen more often is the sender's: a round letter under an accent, a thin
    /// letter run into its neighbour, a consonant read as a round vowel.
    func testReadingsOfOneNameSnapToTheCommonOne() {
        var memory = SenderMemory()
        for _ in 0..<3 { XCTAssertEqual(memory.resolve("Hale Corlin"), "Hale Corlin") }
        XCTAssertEqual(memory.resolve("Hale Cdrlin"), "Hale Corlin")
        XCTAssertEqual(memory.resolve("Hale Corin"), "Hale Corlin")      // a thin letter inside the name, dropped
        for _ in 0..<2 { _ = memory.resolve("Nadric Brindle") }
        XCTAssertEqual(memory.resolve("Nacric Brindle"), "Nadric Brindle")
        for _ in 0..<2 { _ = memory.resolve("Quiet Jorvik") }
        XCTAssertEqual(memory.resolve("Quiet orvik"), "Quiet Jorvik")
        // The whole name is never taken for the one with a letter missing, however often that was seen.
        var other = SenderMemory()
        for _ in 0..<3 { _ = other.resolve("Quiet orvik") }
        XCTAssertEqual(other.resolve("Quiet Jorvik"), "Quiet Jorvik")
        XCTAssertEqual(other.resolve("Quiet orvik"), "Quiet Jorvik")
    }

    /// Two names that differ in a vowel, or in a letter OCR does not confuse, are two people.
    func testDifferentPeopleStayDifferent() {
        var memory = SenderMemory()
        for _ in 0..<3 { _ = memory.resolve("Katarina Vale") }
        XCTAssertEqual(memory.resolve("Katerina Vale"), "Katerina Vale")
        XCTAssertEqual(memory.resolve("Katarino Vale"), "Katarino Vale")
        XCTAssertEqual(memory.resolve("Katarina Valt"), "Katarina Valt")
        for _ in 0..<3 { _ = memory.resolve("Dorn") }
        XCTAssertEqual(memory.resolve("Corn"), "Corn", "a short name is somebody else's")
    }
}
