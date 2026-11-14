import XCTest
@testable import RunespeakCore

final class GlossaryTests: XCTestCase {

    // MARK: Fixtures

    private var root: URL!
    private var paths: AppPaths { AppPaths(root: root) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("runespeak-glossary-\(UUID().uuidString)", isDirectory: true)
        try paths.ensureDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeData(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: paths.dataDirectory.appendingPathComponent(name))
    }

    private func writeRoot(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }

    /// Rows written as "a|b|c" for readability; the files use tabs.
    private static func tsv(_ header: String, _ rows: [String], comment: String? = "generated for the tests") -> String {
        var lines: [String] = []
        if let comment { lines.append("# " + comment) }
        lines.append(header)
        lines += rows
        return lines.map { $0.replacingOccurrences(of: "|", with: "\t") }.joined(separator: "\n") + "\n"
    }

    private static let officialClassicRows = [
        "zone|스톰윈드|Stormwind City",
        "zone|아이언포지|Ironforge",
        "zone|다르나서스|Darnassus",
        "zone|저습지|Wetlands",
        "zone|불모의 땅|The Barrens",
        "zone|타나리스|Tanaris",
        "zone|가시덤불 골짜기|Stranglethorn Vale",
        "zone|운고로 분화구|Un'Goro Crater",
        "instance|죽음의 폐광|The Deadmines",
        "instance|혈투의 전장|Dire Maul",
        "instance|줄파락|Zul'Farrak",
        "instance|검은바위 첨탑|Blackrock Spire",
        "instance|검은바위 첨탑 상층|Upper Blackrock Spire",
        "instance|오닉시아의 둥지|Onyxia's Lair",
        "instance|스톰윈드|Stormwind City",
        "zone|숲|Forest",
        "zone|눈|Eye",
        "subzone|쇼|Sho",
        "subzone|최후|The End",
        "item|아케이나이트 주괴|Arcanite Bar",
        "item|우레폭풍 - 바람추적자의 성검|Thunderfury, Blessed Blade of the Windseeker",
        "item|두꺼운 가죽|Thick Hide",
        "item|질긴 가죽|Thick Hide",
        "class|사냥꾼|Hunter",
        "class|흑마법사|Warlock",
        "Class|전사|Warrior",
        "achievement|탐험가|Explorer",
        "achievement|칼림도어의 길잡이|Pathfinder of Kalimdor",
        "spec|냉기|Frost",
        "spell|돌진|Charge",
        "spell|공포|Fear",
        "spell|기절시키기|Sap",
        "spell|마법 차단|Counterspell",
        "spell|빛|Light",
        "spell|신의 권능: 인내|Power Word: Fortitude",
        "relic|고대의 무언가|Something Ancient",
        "zone|클래식 전용|Classic Only Zone",
        "zone|영어 없음|",
        "zone||No Korean",
    ]
    /// Rows that load: the two incomplete ones and the repeated Stormwind pair do not.
    private static let officialClassicCount = officialClassicRows.count - 3

    // A BOM and CRLF line ends, as a spreadsheet export would leave them.
    private static let officialClassic = "\u{FEFF}"
        + tsv("kind|korean|english", officialClassicRows).replacingOccurrences(of: "\n", with: "\r\n")

    private static let officialRetail = tsv("kind|korean|english", [
        "zone|도른의 섬|Isle of Dorn",
        "zone|저습지|Wetlands",
    ])

    private static let nicknameRows = [
        "스톰윈드|Stormwind City|Stormwind, SW",
        "아이언포지|Ironforge|IF",
        "다르나서스|Darnassus|Darna (night elf capital on Teldrassil)",
        "가시덤불 골짜기|Stranglethorn Vale|Stranglethorn, Strangle, STV, 가덤",
        "죽음의 폐광|The Deadmines|Deadmines, VC, DM(low-level groups, around 18-23)",
        "혈투의 전장|Dire Maul|DM(level 55+, or with east, west or north)",
        "운고로 분화구|Un'Goro Crater|Un'Goro, Ungoro",
        "검은바위 첨탑 상층|Upper Blackrock Spire|UBRS",
        "흑마법사|Warlock|lock(the class), WL",
        "전사|Warrior|warr",
        "안퀴라즈 사원|Temple of Ahn'Qiraj|AQ40",
        "별명 없음|No Aliases|",
    ]
    private static let nicknames = tsv("korean|english|aliases", nicknameRows)

    private static let abbreviationClassicRows = [
        "DM||The Deadmines|죽음의 폐광|Westfall dungeon; the sense for groups around level 18-23",
        "DM||Dire Maul|혈투의 전장|Feralas dungeon; the sense at level 55+ or next to a wing name",
        "IF||Ironforge|아이언포지|Alliance capital city",
        "LFM|LF1M, LF2M|looking for more|구함|a group recruiting more members",
        "ZF|zul farrak, farrak|Zul'Farrak|줄파락|Tanaris dungeon, mid 40s",
        "tribute|trib, tribute run, DMT|Dire Maul North tribute run|공물런|clearing the north wing with the guards left alive",
        "ud run||Stratholme undead side||the Baron half of Stratholme",
        "8/8||eight of eight bosses down||raid progress; a letter after it is the difficulty",
        "+10||keystone level 10|10단|",
        "M+||Mythic+|쐐기|keystone dungeons",
        "H||Heroic|영웅|difficulty tag after a progress count",
        "1||invite me||the usual answer to a recruiting call",
        "NP||Nerub-ar Palace|네룹아르 궁전|raid",
        "np|NP, no prob|no problem||chat reply",
        "live|strat live, LIVE, need|Stratholme living side||the Scarlet half",
        "达拉然|達拉然|Dalaran|달라란|the mage city",
        "血色|血色修道院|Scarlet Monastery|붉은십자군 수도원|dungeon",
        "данж|данжа, данжи|dungeon|던전|5-player instance",
        "nothing||||",
        "|orphan|no abbreviation||",
    ]
    private static let abbreviationsClassic = tsv("abbr|also|english|korean|note", abbreviationClassicRows)

    private static let abbreviationsRetail = tsv("abbr|also|english|korean|note", [
        "DM||private message||\"DM me\" asks for a whisper",
    ])

    private static let commands = tsv("chat_type|canonical|aliases", [
        "SAY|/s|/s /say /ㄴ /말",
        "YELL|/y|/y /yell /sh /shout /ㅛ /외침",
        "PARTY|/p|/p /party /ㅔ /파티",
        "GUILD|/g|/g /gc /gu /guild /ㅎ /길드",
        "RAID|/ra|/ra /raid /rsay /공격대 /공",
        "WHISPER|/w|/w /whisper /t /tell /send /ㅈ /귓속말 /귓",
        "REPLY|/r|/r /reply /ㄱ /답장",
        "EMOTE|/e|/e /em /me /emote /ㄷ /감정표현",
        "CHANNEL|/c|/c /csay /ㅊ",
    ])

    private func installStandardFixtures() throws {
        try writeData("official_names.classic.tsv", GlossaryTests.officialClassic)
        try writeData("official_names.retail.tsv", GlossaryTests.officialRetail)
        try writeData("nicknames.tsv", GlossaryTests.nicknames)
        try writeData("abbreviations.classic.tsv", GlossaryTests.abbreviationsClassic)
        try writeData("abbreviations.retail.tsv", GlossaryTests.abbreviationsRetail)
        try writeData("chat_commands.classic.tsv", GlossaryTests.commands)
        try writeData("chat_commands.retail.tsv", GlossaryTests.commands)
    }

    private func makeStore(_ flavor: GameFlavor = .classic) throws -> GlossaryStore {
        try installStandardFixtures()
        return GlossaryStore(paths: paths, flavor: flavor)
    }

    private func names(_ store: GlossaryStore, _ text: String) -> [String] {
        store.hints(for: [text]).names.map { "\($0.korean) ↔ \($0.english)" }
    }

    private func abbreviations(_ store: GlossaryStore, _ text: String) -> [String] {
        store.hints(for: [text]).abbreviations.map(\.abbr)
    }

    /// One sense on one line, for compact assertions.
    private func senses(_ hints: GlossaryHints) -> [String] {
        hints.abbreviations.map { "\($0.abbr) | \($0.english) | \($0.korean) | \($0.note)" }
    }

    // MARK: File formats

    func testFileNamesPerFlavor() {
        let classic = DictionaryFiles.names(for: .classic), retail = DictionaryFiles.names(for: .retail)
        XCTAssertEqual([classic.officialNames, classic.abbreviations, classic.chatCommands],
                       ["official_names.classic.tsv", "abbreviations.classic.tsv", "chat_commands.classic.tsv"])
        XCTAssertEqual([retail.officialNames, retail.abbreviations, retail.chatCommands],
                       ["official_names.retail.tsv", "abbreviations.retail.tsv", "chat_commands.retail.tsv"])
        XCTAssertEqual(DictionaryFiles.all.count, 7)
        XCTAssertTrue(DictionaryFiles.all.contains("nicknames.tsv"))
    }

    func testTSVRowsFollowTheHeader() {
        let text = "# first comment\n\n#second\nenglish\tsource\tkind\tkorean\n# between rows\n"
            + "Tanaris\tdb\tzone\t타나리스\n  Gadgetzan \tdb\tsubzone\t 가젯잔 \n\t\t\t\nshort row\n"
        let rows = GlossaryParser.tsvRows(text, columns: ["kind", "korean", "english"])
        XCTAssertEqual(rows, [["zone", "타나리스", "Tanaris"], ["subzone", "가젯잔", "Gadgetzan"], ["", "", "short row"]],
                       "columns are found by name; comments and blank rows are skipped; cells are trimmed")

        // No line names a wanted column: there is no header, and the first line is data too.
        let positional = GlossaryParser.tsvRows("zone\t헤더없음\tNoheader Town\nzone\t타나리스\tTanaris\n", columns: ["kind", "korean", "english"])
        XCTAssertEqual(positional, [["zone", "헤더없음", "Noheader Town"], ["zone", "타나리스", "Tanaris"]])

        // A comment may be indented; it must not be taken for the header.
        let indented = GlossaryParser.tsvRows(" # indented\n\t# tabbed\nkind\tkorean\tenglish\nzone\t타나리스\tTanaris\n", columns: ["kind", "korean", "english"])
        XCTAssertEqual(indented, [["zone", "타나리스", "Tanaris"]])

        // A wanted column the header does not have is empty, not whatever sits at its usual place.
        let four = GlossaryParser.parseAbbreviations("abbr\tenglish\tkorean\tnote\nZF\tZul'Farrak\t줄파락\tdungeon\n")
        XCTAssertEqual(four.map(\.variants), [[]])
        XCTAssertEqual(four.first?.sense, GlossaryAbbreviation(abbr: "ZF", english: "Zul'Farrak", korean: "줄파락", note: "dungeon"))

        // A tab typed inside a name: the pieces are kept together and the row is counted.
        let stray = GlossaryParser.tsvTable("kind\tkorean\tenglish\nzone\t탭마을\tTab\tTown\nzone\t타나리스\tTanaris\t\n", columns: ["kind", "korean", "english"])
        XCTAssertEqual(stray.rows, [["zone", "탭마을", "Tab Town"], ["zone", "타나리스", "Tanaris"]])
        XCTAssertEqual(stray.overlong, 1, "a trailing empty cell is not a stray tab")
        XCTAssertEqual(GlossaryParser.tsvRows("", columns: ["kind"]), [])
        XCTAssertEqual(GlossaryParser.tsvRows("kind\tkorean\tenglish\n", columns: ["kind"]), [], "header only")
    }

    func testParsesOfficialNamesWithBOMAndCRLF() {
        let rows = GlossaryParser.parseOfficialNames(GlossaryParser.decode(Data(GlossaryTests.officialClassic.utf8)))
        XCTAssertEqual(rows.count, GlossaryTests.officialClassicRows.count - 2, "rows missing a side are dropped")
        XCTAssertEqual(rows[0], GlossaryOfficialName(kind: "zone", korean: "스톰윈드", english: "Stormwind City"))
        XCTAssertEqual(rows[3].english, "Wetlands", "no stray carriage return")
        XCTAssertEqual(rows[20].english, "Thunderfury, Blessed Blade of the Windseeker")
        XCTAssertEqual(rows[25].kind, "class", "kinds are case-insensitive")
        XCTAssertEqual(rows[35].kind, "relic", "an unknown kind is kept")
    }

    func testParsesNicknames() {
        let lines = GlossaryParser.parseNicknames(GlossaryTests.nicknames)
        XCTAssertEqual(lines.count, GlossaryTests.nicknameRows.count)
        XCTAssertEqual(lines[0].korean.map(\.text), ["스톰윈드"])
        XCTAssertEqual(lines[0].english.map(\.text), ["Stormwind City", "Stormwind", "SW"])
        XCTAssertEqual(lines[2].english[1], GlossaryAlias(text: "Darna", note: "night elf capital on Teldrassil"),
                       "a space before the hint is fine")
        XCTAssertEqual(lines[5].english.last?.note, "level 55+, or with east, west or north", "a comma inside the hint does not split")
        XCTAssertEqual(lines[3].korean.map(\.text), ["가시덤불 골짜기", "가덤"], "a Hangul alias belongs to the Korean side")
        XCTAssertEqual(lines[3].english.map(\.text), ["Stranglethorn Vale", "Stranglethorn", "Strangle", "STV"])
        XCTAssertEqual(lines[4].english.last, GlossaryAlias(text: "DM", note: "low-level groups, around 18-23"))
        XCTAssertEqual(lines[4].english.last?.written, "DM(low-level groups, around 18-23)")
        XCTAssertEqual(lines[11].english.map(\.text), ["No Aliases"])
        XCTAssertEqual(GlossaryParser.splitList("a, b(x, y) ,, c，d"), ["a", "b(x, y)", "c", "d"])
    }

    func testParsesAbbreviationsAndComposesThePromptLine() {
        let lines = GlossaryParser.parseAbbreviations(GlossaryTests.abbreviationsClassic)
        XCTAssertEqual(lines.count, GlossaryTests.abbreviationClassicRows.count - 2, "rows without an abbreviation or a meaning are dropped")
        XCTAssertEqual(lines.filter { $0.abbreviation == "DM" }.count, 2, "one row per sense")
        XCTAssertEqual(lines[0].sense, GlossaryAbbreviation(abbr: "DM", english: "The Deadmines", korean: "죽음의 폐광",
                                                            note: "Westfall dungeon; the sense for groups around level 18-23"))
        XCTAssertEqual(lines[3].sense, GlossaryAbbreviation(abbr: "LFM", english: "looking for more", korean: "구함", note: "a group recruiting more members"))
        XCTAssertEqual(lines[3].variants, ["LF1M", "LF2M"])
        XCTAssertEqual(lines[5].variants, ["trib", "tribute run", "DMT"])
        XCTAssertEqual(lines[6].abbreviation, "ud run")
        XCTAssertEqual(lines[6].sense, GlossaryAbbreviation(abbr: "ud run", english: "Stratholme undead side", note: "the Baron half of Stratholme"),
                       "no Korean term")
        XCTAssertEqual(lines[8].sense, GlossaryAbbreviation(abbr: "+10", english: "keystone level 10", korean: "10단"), "no note")
        XCTAssertEqual(lines[15].variants, ["達拉然"])
        XCTAssertEqual(lines[17].variants, ["данжа", "данжи"])

        XCTAssertEqual(GlossaryParser.abbreviationSense(abbreviation: "ㄱㄱ", english: "", korean: "", note: "go go"),
                       GlossaryAbbreviation(abbr: "ㄱㄱ", note: "go go"))
        XCTAssertEqual(GlossaryParser.abbreviationSense(abbreviation: "gz", english: "", korean: "축하", note: ""),
                       GlossaryAbbreviation(abbr: "gz", korean: "축하"))
        XCTAssertEqual(GlossaryParser.abbreviationSense(abbreviation: "BRD", english: "Blackrock Depths", korean: "Blackrock Depths", note: "(dungeon)"),
                       GlossaryAbbreviation(abbr: "BRD", english: "Blackrock Depths", note: "dungeon"),
                       "a repeated name is given once; parentheses around the whole note are dropped")
        XCTAssertNil(GlossaryParser.abbreviationSense(abbreviation: "x", english: "", korean: "", note: ""))
    }

    func testParsesCommandRows() {
        let lines = GlossaryParser.parseCommands(GlossaryTests.commands)
        XCTAssertEqual(lines.count, 9)
        XCTAssertEqual(lines[0], GlossaryCommandLine(type: "SAY", canonical: "/s", commands: ["/s", "/say", "/ㄴ", "/말"]))
        let odd = GlossaryParser.parseCommands(GlossaryTests.tsv("chat_type|canonical|aliases", [
            "say|/talk|/말 word /",
            "NOTE||/메모 /note",
            "EMPTY||",
        ]))
        XCTAssertEqual(odd, [
            GlossaryCommandLine(type: "SAY", canonical: "/talk", commands: ["/talk", "/말"]),
            GlossaryCommandLine(type: "NOTE", canonical: nil, commands: ["/메모", "/note"]),
        ])
    }

    private static let myTerms = tsv("korean|english|aliases", [
        "폭풍성|Stormwind City|SW",
        "습지|Wetlands|",
        "검은날개 둥지|Blackwing Lair|검둥, BWL, Lair (when a raid is meant, not an animal's den)",
        "내 던전|My Dungeon|DM(내가 정한 뜻)",
        "영어 칸이 빈 줄||",
        "|Korean Cell Empty|",
    ], comment: "내가 더한 이름")

    func testParsesMyTermsRowsWithAliasesAndNotes() {
        let lines = GlossaryParser.parseNicknames(GlossaryTests.myTerms)
        XCTAssertEqual(lines.count, 4, "comment and incomplete rows are skipped")
        XCTAssertEqual(lines[0].korean.map(\.text), ["폭풍성"])
        XCTAssertEqual(lines[0].english.map(\.text), ["Stormwind City", "SW"])
        XCTAssertEqual(lines[1].english.map(\.text), ["Wetlands"], "the aliases cell may be empty")
        XCTAssertEqual(lines[2].korean.map(\.text), ["검은날개 둥지", "검둥"], "a Hangul alias joins the Korean side")
        // A comma inside a note must not split the cell.
        XCTAssertEqual(lines[2].english.map(\.text), ["Blackwing Lair", "BWL", "Lair"])
        XCTAssertEqual(lines[2].english[2].note, "when a raid is meant, not an animal's den")
        XCTAssertEqual(lines[3].english.last?.written, "DM(내가 정한 뜻)")
    }

    func testAliasNoteIsTheClosingParenthesis() {
        XCTAssertEqual(GlossaryParser.alias("ZG(공격대)"), GlossaryAlias(text: "ZG", note: "공격대"))
        XCTAssertEqual(GlossaryParser.alias("Naxx (the raid)"), GlossaryAlias(text: "Naxx", note: "the raid"))
        XCTAssertEqual(GlossaryParser.alias("ST(a (nested) note)"), GlossaryAlias(text: "ST", note: "a (nested) note"))
        XCTAssertEqual(GlossaryParser.alias("(only a note)"), GlossaryAlias(text: "(only a note)", note: nil))
        XCTAssertEqual(GlossaryParser.alias("[Explorer]"), GlossaryAlias(text: "Explorer", note: nil, bracketed: true))
        XCTAssertNil(GlossaryParser.alias(""))
    }

    private static let corrections = tsv("source|translation|note", [
        "LF healer ZF then mara|줄파락 갔다가 마라우돈 갈 힐러 구함|mara는 마라우돈을 줄여 부르는 말입니다.",
        "WTS PORTA1S TO DARNASUS 2G|다르나서스 차원문 팝니다 2골|PORTA1S와 DARNASUS는 화면 인식 오류입니다.",
        "缺个奶 就差一个|힐러 구함, 한 자리 남음|奶는 힐러를 뜻합니다.",
        "ty|ㄳ",
    ], comment: "교정 기록")

    func testParsesCorrectionRows() {
        let examples = GlossaryParser.parseCorrections(GlossaryTests.corrections + "only one cell\n\t번역만 있음\nhttp://a.b/c\t링크 https://x.y/z\t설명 하나\t둘\n")
        XCTAssertEqual(examples.count, 5)
        XCTAssertEqual(examples[0], CorrectionExample(source: "LF healer ZF then mara", translation: "줄파락 갔다가 마라우돈 갈 힐러 구함",
                                                   note: "mara는 마라우돈을 줄여 부르는 말입니다."))
        XCTAssertEqual(examples[2].source, "缺个奶 就差一个")
        XCTAssertEqual(examples[2].translation, "힐러 구함, 한 자리 남음")
        XCTAssertEqual(examples[3], CorrectionExample(source: "ty", translation: "ㄳ", note: nil))
        XCTAssertEqual(examples[4], CorrectionExample(source: "http://a.b/c", translation: "링크 https://x.y/z", note: "설명 하나 둘"),
                       "a tab inside the note does not lose text")
        XCTAssertEqual(GlossaryParser.parseCorrections("no header\t머리글 없는 파일\n"),
                       [CorrectionExample(source: "no header", translation: "머리글 없는 파일", note: nil)])
    }

    func testReadsCP949Text() throws {
        // "썬더 블러프<tab>Thunder Bluff" saved in CP949 with CRLF line ends, not UTF-8.
        let cp949: [UInt8] = [0xBD, 0xE3, 0xB4, 0xF5, 0x20, 0xBA, 0xED, 0xB7, 0xAF, 0xC7, 0xC1] + Array("\tThunder Bluff\r\n".utf8)
        try Data(cp949).write(to: paths.myTermsFile)
        let store = GlossaryStore(paths: paths, flavor: .classic)
        XCTAssertEqual(store.entryCount, 1)
        XCTAssertEqual(names(store, "meet at thunder bluff"), ["썬더 블러프 ↔ Thunder Bluff"])
    }

    // MARK: Name matching

    func testFindsNamesInEitherLanguageIgnoringCaseAndSpacing() throws {
        let store = try makeStore()
        XCTAssertEqual(names(store, "LFM Dire Maul need tank"), ["혈투의 전장 ↔ Dire Maul"])
        XCTAssertEqual(names(store, "lfm dire  maul"), ["혈투의 전장 ↔ Dire Maul"])
        XCTAssertEqual(names(store, "DIREMAUL anyone"), ["혈투의 전장 ↔ Dire Maul"])
        XCTAssertEqual(names(store, "혈투의 전장 가실분"), ["혈투의 전장 ↔ Dire Maul"])
        XCTAssertEqual(names(store, "혈투의전장 가실분"), ["혈투의 전장 ↔ Dire Maul"])
        XCTAssertEqual(names(store, "going to ungoro crater"), ["운고로 분화구 ↔ Un'Goro Crater"], "apostrophes are optional")
        XCTAssertEqual(names(store, "Onyxia’s Lair tonight"), ["오닉시아의 둥지 ↔ Onyxia's Lair"])
        XCTAssertEqual(names(store, "ＷＥＴＬＡＮＤＳ"), ["저습지 ↔ Wetlands"], "full-width letters")
        XCTAssertEqual(names(store, "anyone seen Something Ancient"), ["고대의 무언가 ↔ Something Ancient"], "a kind the app does not know is still a name")
    }

    func testEnglishNamesNeedWordBoundaries() throws {
        let store = try makeStore()
        XCTAssertEqual(names(store, "wetlandsman is here"), [])
        XCTAssertEqual(names(store, "unlock the door, warlocked"), [])
        XCTAssertEqual(names(store, "need 2 locks"), ["흑마법사 ↔ Warlock | lock(the class)"], "plural s")
        XCTAssertEqual(names(store, "wetlands, then (wetlands)!"), ["저습지 ↔ Wetlands"])
    }

    func testNicknameMatchShowsTheNicknameAndItsHint() throws {
        let store = try makeStore()
        XCTAssertEqual(names(store, "heading to STV"), ["가시덤불 골짜기 ↔ Stranglethorn Vale | STV"])
        XCTAssertEqual(names(store, "가덤 가자"), ["가시덤불 골짜기 | 가덤 ↔ Stranglethorn Vale"])
        XCTAssertEqual(names(store, "darna is far"), ["다르나서스 ↔ Darnassus | Darna(night elf capital on Teldrassil)"])
        XCTAssertEqual(names(store, "strangle that mob first"), [], "a nickname that is an everyday word is not taken")
        XCTAssertEqual(names(store, "AQ40 tonight"), ["안퀴라즈 사원 ↔ Temple of Ahn'Qiraj | AQ40"],
                       "a nickname row works even when the official table lacks the name")
    }

    func testShortAllCapsNicknamesMatchOnlyCapitals() throws {
        let store = try makeStore()
        XCTAssertEqual(names(store, "summons at IF"), ["아이언포지 ↔ Ironforge | IF"])
        XCTAssertEqual(names(store, "ask if there is room"), [])
        XCTAssertEqual(names(store, "If you can"), [])
        XCTAssertEqual(names(store, "sw or if"), [])
        // Longer all-capitals nicknames that are no word are typed in lower case as often.
        XCTAssertEqual(names(store, "aq40 tonight"), ["안퀴라즈 사원 ↔ Temple of Ahn'Qiraj | AQ40"])
        XCTAssertEqual(names(store, "lfm ubrs, then stv"),
                       ["검은바위 첨탑 상층 ↔ Upper Blackrock Spire | UBRS", "가시덤불 골짜기 ↔ Stranglethorn Vale | STV"])
        // Mixed-case nicknames stay case-insensitive.
        XCTAssertEqual(names(store, "LF WARR"), ["전사 ↔ Warrior | warr"])
        // In a fully capitalised message capitals prove nothing for an everyday word.
        XCTAssertEqual(names(store, "LF TANK IF YOU CAN HEAL"), [])
        XCTAssertEqual(names(store, "IF"), ["아이언포지 ↔ Ironforge | IF"])
    }

    func testAmbiguousAbbreviationListsEverySense() throws {
        let store = try makeStore()
        let hints = store.hints(for: ["LFM DM need tank"])
        XCTAssertEqual(hints.names, [
            GlossaryPair(korean: "죽음의 폐광", english: "The Deadmines | DM(low-level groups, around 18-23)"),
            GlossaryPair(korean: "혈투의 전장", english: "Dire Maul | DM(level 55+, or with east, west or north)"),
        ])
        XCTAssertEqual(senses(hints), [
            "LFM | looking for more | 구함 | a group recruiting more members",
            "DM | The Deadmines | 죽음의 폐광 | Westfall dungeon; the sense for groups around level 18-23",
            "DM | Dire Maul | 혈투의 전장 | Feralas dungeon; the sense at level 55+ or next to a wing name",
        ])
        // Lower-case "dm": the capitals-only nickname stays out, the abbreviation senses remain.
        let lower = store.hints(for: ["lf tank dm 20"])
        XCTAssertEqual(lower.names, [])
        XCTAssertEqual(lower.abbreviations.count, 2)
    }

    func testPriorityMyTermsOverNicknamesOverOfficialNames() throws {
        try installStandardFixtures()
        var store = GlossaryStore(paths: paths, flavor: .classic)
        XCTAssertEqual(names(store, "스톰윈드 가자"), ["스톰윈드 ↔ Stormwind City"])
        XCTAssertEqual(names(store, "the deadmines run"), ["죽음의 폐광 ↔ The Deadmines"])
        XCTAssertEqual(names(store, "wetlands"), ["저습지 ↔ Wetlands"])
        XCTAssertEqual(store.entryCount, GlossaryTests.officialClassicCount, "nickname rows are not counted as names")

        // A nickname beats an official name of the same spelling.
        try writeData("nicknames.tsv", GlossaryTests.tsv("korean|english|aliases", ["타나리스|Tanaris|Wetlands, Tana"]))
        store.reload(flavor: .classic)
        XCTAssertEqual(names(store, "wetlands"), ["타나리스 ↔ Tanaris | Wetlands"])
        try writeData("nicknames.tsv", GlossaryTests.nicknames)

        try writeRoot("my_terms.tsv", GlossaryTests.myTerms)
        store = GlossaryStore(paths: paths, flavor: .classic)
        XCTAssertEqual(names(store, "go to Stormwind City"), ["폭풍성 ↔ Stormwind City"])
        XCTAssertEqual(names(store, "SW bank"), ["폭풍성 ↔ Stormwind City | SW"])
        XCTAssertEqual(names(store, "wetlands"), ["습지 ↔ Wetlands"])
        XCTAssertEqual(names(store, "LFM DM"), ["내 던전 ↔ My Dungeon | DM(내가 정한 뜻)"], "my_terms.tsv replaces both nickname senses")
        // A spelling my_terms.tsv does not mention still comes from nicknames.tsv.
        XCTAssertEqual(names(store, "Stormwind"), ["스톰윈드 ↔ Stormwind City | Stormwind"])
        XCTAssertEqual(store.entryCount, 4 + GlossaryTests.officialClassicCount)
        XCTAssertEqual(store.abbreviationCount, GlossaryTests.abbreviationClassicRows.count - 2)
    }

    func testLongestMatchWins() throws {
        let store = try makeStore()
        XCTAssertEqual(names(store, "LFM Upper Blackrock Spire"), ["검은바위 첨탑 상층 ↔ Upper Blackrock Spire"])
        XCTAssertEqual(names(store, "검은바위 첨탑 상층 갑니다"), ["검은바위 첨탑 상층 ↔ Upper Blackrock Spire"])
        XCTAssertEqual(names(store, "Blackrock Spire then Upper Blackrock Spire"),
                       ["검은바위 첨탑 상층 ↔ Upper Blackrock Spire", "검은바위 첨탑 ↔ Blackrock Spire"])
        // The full name wins over the bare nickname inside it.
        XCTAssertEqual(names(store, "The Deadmines"), ["죽음의 폐광 ↔ The Deadmines"])
    }

    func testKoreanParticlesAndWordStarts() throws {
        let store = try makeStore()
        XCTAssertEqual(names(store, "스톰윈드에서 출발합니다"), ["스톰윈드 ↔ Stormwind City"], "particle glued to the name")
        XCTAssertEqual(names(store, "전사를 구해요"), ["전사 ↔ Warrior"])
        XCTAssertEqual(names(store, "우리전사 최고"), [], "a two-syllable name must start a word")
        XCTAssertEqual(names(store, "오늘밤스톰윈드집결"), ["스톰윈드 ↔ Stormwind City"], "longer names are found inside a run")
        XCTAssertEqual(names(store, "55레벨 전사 2명"), ["전사 ↔ Warrior"])
    }

    func testLatinNamesInsideChineseText() throws {
        let store = try makeStore()
        let hints = store.hints(for: ["下午组DM还缺2个warlock，打完转血色，最后回达拉然"])
        XCTAssertEqual(hints.names.map(\.korean), ["흑마법사", "죽음의 폐광", "혈투의 전장"])
        XCTAssertEqual(Set(hints.abbreviations.map(\.abbr)), ["DM", "血色", "达拉然"])
        XCTAssertEqual(abbreviations(store, "去達拉然打本"), ["达拉然"], "traditional spelling from the also column")
    }

    func testCommonWordAndTinyOfficialNamesDoNotMatch() throws {
        let store = try makeStore()
        XCTAssertEqual(names(store, "meet me in the forest at the end"), [], "everyday words")
        XCTAssertEqual(names(store, "eye sho"), [], "names shorter than four letters")
        XCTAssertEqual(names(store, "쇼 눈 숲"), [], "one-syllable Korean names")
        XCTAssertEqual(names(store, "anyone in the barrens"), ["불모의 땅 ↔ The Barrens"])
        XCTAssertEqual(names(store, "barrens chat"), ["불모의 땅 ↔ The Barrens"], "leading article is optional")
        XCTAssertEqual(names(store, "hunter LFG"), ["사냥꾼 ↔ Hunter"])
        XCTAssertEqual(names(store, "The quick brown fox jumps over the lazy dog because it was late"), [])
    }

    func testShortAchievementNamesNeedTheLinkBrackets() throws {
        let store = try makeStore()
        XCTAssertEqual(names(store, "any explorer here"), [])
        XCTAssertEqual(names(store, "just got [Explorer]!"), ["탐험가 ↔ Explorer"])
        XCTAssertEqual(names(store, "grats on pathfinder of kalimdor"), ["칼림도어의 길잡이 ↔ Pathfinder of Kalimdor"])
    }

    func testSameSpellingKeepsSeveralSensesButNotAFlood() throws {
        let store = try makeStore()
        XCTAssertEqual(names(store, "WTS Thick Hide"), ["두꺼운 가죽 ↔ Thick Hide", "질긴 가죽 ↔ Thick Hide"])

        // Six things with one English name: only those of the best kind present are kept.
        try writeData("official_names.classic.tsv", GlossaryTests.tsv("kind|korean|english", [
            "item|열쇠 하나|Shadow Vault", "item|열쇠 둘|Shadow Vault", "achievement|업적 이름|Shadow Vault",
            "spell|주문 이름|Shadow Vault", "subzone|소지역 이름|Shadow Vault", "instance|던전 이름|Shadow Vault",
        ]))
        store.reload(flavor: .classic)
        XCTAssertEqual(names(store, "LFM shadow vault"), ["던전 이름 ↔ Shadow Vault"])
        XCTAssertEqual(store.entryCount, 6)

        // The same within one kind: at most three senses.
        try writeData("official_names.classic.tsv", GlossaryTests.tsv("kind|korean|english",
            (1...5).map { "item|열쇠 \($0)번|Shadow Vault" } + ["boss|라그나로스|Ragnaros", "item|용암 과자|Ragnar-O's"]))
        store.reload(flavor: .classic)
        XCTAssertEqual(names(store, "LFM shadow vault"), ["열쇠 1번 ↔ Shadow Vault", "열쇠 2번 ↔ Shadow Vault", "열쇠 3번 ↔ Shadow Vault"])
        XCTAssertEqual(names(store, "ragnaros kill tonight"), ["라그나로스 ↔ Ragnaros"],
                       "an item whose name folds to the boss's spelling does not ride along")
    }

    // MARK: Realistic chat lines (found with --dictionary-check on the shipped files)

    private func makeChatStore() throws -> GlossaryStore {
        try writeData("official_names.classic.tsv", GlossaryTests.tsv("kind|korean|english", [
            "zone|스톰윈드|Stormwind City", "instance|스트라솔름|Stratholme", "instance|한밤|Midnight",
            "mount|천둥이|Midnight", "item|꿀단지|Honey", "mount|호랑이|Tiger", "currency|명예|Honor",
            "subzone|탑|Tower", "subzone|감시탑|Watchtower", "boss|미녀|Beauty", "zone|검은바위 산|Blackrock Mountain",
            "item|검은 연꽃|Black Lotus", "class|마법사|Mage", "profession|요리|Cooking",
        ]))
        try writeData("nicknames.tsv", GlossaryTests.tsv("korean|english|aliases", [
            "검은바위 산|Blackrock Mountain|BRM", "스톰윈드|Stormwind City|SW, Stormwind",
        ]))
        try writeData("abbreviations.classic.tsv", GlossaryTests.tsv("abbr|also|english|korean|note", [
            "WA|weakauras|WeakAuras|위크오라|alert add-on",
            "BrM|brewmaster|Brewmaster|양조|monk tank spec",
            "BRM||Blackrock Mountain|검은바위 산|the mountain",
            "HoT|hots|heal over time|지속 치유|periodic healing",
            "DE|disenchant|disenchant|마력 추출|break an item into materials",
            "LoS||line of sight|시야|hide behind an obstacle",
            "M+|mythic+, mplus|Mythic+|쐐기|keystone dungeons",
            "SW||Stormwind City|스톰윈드|human city in Elwynn Forest, typed in either case",
            "танк|танка|tank|탱커|Russian",
            "熔火之心||Molten Core|화산 심장부|Chinese name of the raid",
            "治疗|奶|healer|힐러|Chinese",
        ]))
        return GlossaryStore(paths: paths, flavor: .classic)
    }

    func testOrdinarySentencesGiveNoHints() throws {
        let store = try makeChatStore()
        for line in [
            "my brother was here last night and he said it was really cold outside",
            "what time is it there? it is almost midnight here",
            "wtb honey for cooking, and a tiger would be nice lol",
            "I love this tower, such beauty and honor",
            "it's getting hot in here",
            "un grupo de 5, des gens pour los dos?",
        ] {
            let hints = store.hints(for: [line])
            XCTAssertEqual(hints.names.filter { $0.english != "Cooking" }, [], line)
            XCTAssertEqual(hints.abbreviations, [], line)
        }
    }

    func testPluralOfAnAbbreviationIsNotAnEverydayWord() throws {
        let store = try makeChatStore()
        XCTAssertEqual(abbreviations(store, "that was close"), [], "'was' is not several WAs")
        XCTAssertEqual(abbreviations(store, "share your WAs pls"), ["WA"])
        XCTAssertEqual(abbreviations(store, "des gens"), [], "nor 'des' several DEs")
    }

    func testOneWordNamesOfMinorKindsNeedACapitalOrALink() throws {
        let store = try makeChatStore()
        XCTAssertEqual(names(store, "WTS [Honey] x40"), ["꿀단지 ↔ Honey"])
        XCTAssertEqual(names(store, "selling Honey and a Tiger"), ["호랑이 ↔ Tiger", "꿀단지 ↔ Honey"])
        XCTAssertEqual(names(store, "SELLING HONEY CHEAP"), [], "capitals prove nothing in a shouted line")
        XCTAssertEqual(names(store, "wts [honey]"), ["꿀단지 ↔ Honey"])
        XCTAssertEqual(names(store, "meet at the watchtower"), [], "even when the word is not an everyday one")
        XCTAssertEqual(names(store, "wts black lotus"), ["검은 연꽃 ↔ Black Lotus"], "names of several words match in any case")
        XCTAssertEqual(names(store, "lfm stratholme, need mage"), ["스트라솔름 ↔ Stratholme", "마법사 ↔ Mage"],
                       "places, bosses and classes match in any case")
        // The Korean side: a one-word item name is only offered loosely, a two-syllable one not at all.
        let korean = store.hints(for: ["꿀단지 팝니다 명예 얼마"])
        XCTAssertEqual(korean.names, [])
        XCTAssertEqual(korean.looseNames, [GlossaryPair(korean: "꿀단지", english: "Honey")])
        XCTAssertEqual(names(store, "검은 연꽃 삽니다"), ["검은 연꽃 ↔ Black Lotus"], "a name of several words is binding in Korean too")
        XCTAssertEqual(names(store, "Midnight launch was fun"), [], "an ordinary word that is a whole place name")
    }

    func testMixedCaseAbbreviationYieldsToAnExactSpelling() throws {
        let store = try makeChatStore()
        XCTAssertEqual(abbreviations(store, "summon to BRM pls"), ["BRM"])
        XCTAssertEqual(abbreviations(store, "LF BrM for key"), ["BrM", "BRM"])
        XCTAssertEqual(abbreviations(store, "brm"), ["BrM", "BRM"], "lower case says nothing")
        XCTAssertEqual(abbreviations(store, "keep HoTs rolling"), ["HoT"])
        XCTAssertEqual(abbreviations(store, "keep hots rolling"), ["HoT"], "through the also column")
        XCTAssertEqual(abbreviations(store, "the fire is hot"), [])
        XCTAssertEqual(abbreviations(store, "LoS the caster"), ["LoS"])
        XCTAssertEqual(abbreviations(store, "los tanques"), [])
    }

    func testForeignFunctionWordsDoNotTriggerCapitalAbbreviations() throws {
        let store = try makeChatStore()
        XCTAssertEqual(abbreviations(store, "busco grupo de 5"), [])
        XCTAssertEqual(abbreviations(store, "can someone DE this"), ["DE"])
        XCTAssertEqual(abbreviations(store, "WTS Mythic carry"), [], "'mythic+' needs its plus sign")
        XCTAssertEqual(abbreviations(store, "LF mythic+ group"), ["M+"])
    }

    func testCityAbbreviationCoversLowerCaseWhereTheNicknameDoesNot() throws {
        let store = try makeChatStore()
        XCTAssertEqual(names(store, "port to sw pls"), [])
        XCTAssertEqual(senses(store.hints(for: ["port to sw pls"])), ["SW | Stormwind City | 스톰윈드 | human city in Elwynn Forest, typed in either case"])
        XCTAssertEqual(names(store, "port to SW pls"), ["스톰윈드 ↔ Stormwind City | SW"])
    }

    func testRussianAndChineseRowsMatch() throws {
        let store = try makeChatStore()
        XCTAssertEqual(abbreviations(store, "нужен танк в Стратхольм"), ["танк"])
        XCTAssertEqual(abbreviations(store, "ищем Танка"), ["танк"])
        XCTAssertEqual(abbreviations(store, "组队熔火之心来个奶"), ["熔火之心", "治疗"])
    }

    func testHintsAreCappedPreferringNicknamesAndLongerNames() throws {
        try writeData("official_names.classic.tsv", GlossaryTests.tsv("kind|korean|english",
            (0..<40).map { "zone|자동이름\($0)번|Zoneword\($0)x Place" } + ["zone|아이언포지|Ironforge"]))
        try writeData("nicknames.tsv", GlossaryTests.tsv("korean|english|aliases", ["아이언포지|Ironforge|IF"]))
        let store = GlossaryStore(paths: paths, flavor: .classic)
        let text = (0..<40).map { "Zoneword\($0)x Place" }.joined(separator: ", ") + " and Ironforge"
        let hints = store.hints(for: [text])
        XCTAssertEqual(hints.names.count, 12)
        XCTAssertEqual(hints.names.first, GlossaryPair(korean: "아이언포지", english: "Ironforge"))

        // A batch is capped as well, and never repeats a pair.
        let batch = store.hints(for: Array(repeating: text, count: 30))
        XCTAssertEqual(batch.names.count, 12)
        XCTAssertEqual(Set(batch.names).count, batch.names.count)
    }

    // MARK: Ordinary words that happen to be dictionary keys

    func testEverydayKoreanWordsAreNotOfficialNames() throws {
        try writeData("official_names.classic.tsv", GlossaryTests.tsv("kind|korean|english", [
            "instance|대해|The Veiled Sea", "zone|도시|City", "zone|타나리스|Tanaris", "boss|들창코|Hogger",
            "currency|없음|Nothing Much", "subzone|정원|The Botanica", "subzone|시장|The Bazaar",
            "item|꿀단지|Honey", "item|임시|Dwarf Loot", "subzone|가젯잔|Gadgetzan", "subzone|희망의 빛 예배당|Light's Hope Chapel",
            "spec|야수|Beast Mastery", "spell|돌진|Charge", "spell|죽은척하기|Feign Death",
        ]))
        let store = GlossaryStore(paths: paths, flavor: .classic)
        for line in ["이 퀘스트에 대해 아시는 분 있나요", "도시로 돌아가서 수리할게요", "임시 공대장 맡을게요",
                     "자리 없음 다음에 같이 가요", "정원 구경 갑시다", "시장 가서 물약 살게요"] {
            XCTAssertTrue(store.hints(for: [line]).isEmpty, line)
        }
        // Places and bosses of one Korean word stay binding; the English side is untouched.
        XCTAssertEqual(names(store, "타나리스에서 들창코 잡아요"), ["타나리스 ↔ Tanaris", "들창코 ↔ Hogger"])
        XCTAssertEqual(names(store, "meet at the veiled sea"), ["대해 ↔ The Veiled Sea"])
        // A one-word Korean item or subzone name of three syllables or more is a loose name.
        let loose = store.hints(for: ["가젯잔에서 꿀단지 팝니다"])
        XCTAssertEqual(loose.names, [])
        XCTAssertEqual(loose.looseNames, [GlossaryPair(korean: "가젯잔", english: "Gadgetzan"), GlossaryPair(korean: "꿀단지", english: "Honey")])
        XCTAssertEqual(names(store, "희망의 빛 예배당 앞"), ["희망의 빛 예배당 ↔ Light's Hope Chapel"])
        // A specialization or spell whose Korean name is one word is loose even when the English name is not.
        let spec = store.hints(for: ["야수 사냥꾼 죽은척하기"])
        XCTAssertEqual(spec.names, [])
        XCTAssertEqual(Set(spec.looseNames.map(\.english)), ["Beast Mastery", "Feign Death"])
        XCTAssertEqual(names(store, "beast mastery hunter"), ["야수 ↔ Beast Mastery"])
    }

    private func makeWordStore() throws -> GlossaryStore {
        try writeData("official_names.retail.tsv", GlossaryTests.tsv("kind|korean|english", [
            "spell|분통|Seethe", "spell|제압|Takedown", "spell|불태움|Burnout", "spell|약진|Overrun", "spell|사전 준비|Setup",
            "instance|자유지대|Freehold", "zone|아웃랜드|Outland", "zone|운고로 분화구|Un'Goro Crater", "boss|켈투자드|Kel'Thuzad",
            "zone|언더시티|Undercity", "instance|줄파락|Zul'Farrak",
        ]))
        try writeData("nicknames.tsv", GlossaryTests.tsv("korean|english|aliases", ["운고로 분화구|Un'Goro Crater|Ungoro"]))
        try writeData("abbreviations.retail.tsv", GlossaryTests.tsv("abbr|also|english|korean|note", [
            "BoS||Blessing of Salvation|구원의 축복|paladin buff",
            "ToS||Tomb of Sargeras|살게라스의 무덤|raid",
            "MoS||Maw of Souls|영혼의 아귀|dungeon",
            "ID||Iron Docks|강철 선착장|dungeon",
            "dev||Devastation|황폐|evoker spec",
            "AD||Atal'Dazar|아탈다자르|dungeon",
            "HoT||heal over time|지속 치유|periodic healing",
            "C'Thun|cthun|C'Thun|크툰|raid boss",
            "NP||Nerub-ar Palace|네룹아르 궁전|raid",
            "np||no problem||chat reply",
            "lfm||looking for more|구함|recruiting",
        ]))
        return GlossaryStore(paths: paths, flavor: .retail)
    }

    func testBossAndTossAreNotPluralAbbreviations() throws {
        let store = try makeWordStore()
        for line in ["the boss hits really hard so stay behind him", "kill the BOSS first then the adds", "coin toss for the last item",
                     "moss is growing on this server", "the devs fixed it", "too many ads here", "check their ids"] {
            XCTAssertEqual(abbreviations(store, line), [], line)
        }
        XCTAssertEqual(abbreviations(store, "need BoS on the mage"), ["BoS"])
        XCTAssertEqual(abbreviations(store, "paladins put BoSs on dps"), ["BoS"], "written as the abbreviation plus a small s")
        XCTAssertEqual(abbreviations(store, "two ToSs this week"), ["ToS"])
        XCTAssertEqual(abbreviations(store, "keep HoTs up"), ["HoT"])
        XCTAssertEqual(abbreviations(store, "hots"), [], "a mixed-case abbreviation in the plural needs its own capitals")
        XCTAssertEqual(abbreviations(store, "any devs here? two IDs left"), ["ID"], "capitals with a small s are a plural even of a word")
    }

    func testContractionIsNotAnAbbreviation() throws {
        let store = try makeWordStore()
        XCTAssertEqual(abbreviations(store, "i'd like to join if you still have room"), [])
        XCTAssertEqual(abbreviations(store, "I'D LIKE TO JOIN"), [])
        XCTAssertEqual(abbreviations(store, "id like to join"), [], "the apostrophe-less spelling is an everyday word")
        XCTAssertEqual(abbreviations(store, "LFM ID need tank"), ["ID", "lfm"])
        XCTAssertEqual(abbreviations(store, "c'thun tonight"), ["C'Thun"], "an abbreviation spelled with an apostrophe keeps it")
        XCTAssertEqual(abbreviations(store, "cthun tonight"), ["C'Thun"])
    }

    func testCapitalAbbreviationWithALowerCaseTwinNeedsCapitals() throws {
        let store = try makeWordStore()
        XCTAssertEqual(abbreviations(store, "np, happy to help"), ["np"])
        XCTAssertEqual(abbreviations(store, "LFM NP heroic"), ["NP", "lfm", "np"])
    }

    func testOneWordNamesAreNotAssembledFromSeparateWords() throws {
        let store = try makeWordStore()
        for line in ["can you see the mats", "we will take down the boss tonight", "dont burn out, take a break",
                     "we over run them every time", "free hold my beer", "let me set up the group first", "out land is boring",
                     "under city rules", "l f m"] {
            XCTAssertTrue(store.hints(for: [line]).isEmpty, line)
        }
        // Written as one word they are found as before.
        XCTAssertEqual(store.hints(for: ["use takedown then seethe"]).looseNames.map(\.english), ["Takedown", "Seethe"])
        XCTAssertEqual(names(store, "lfm freehold, then outland"), ["자유지대 ↔ Freehold", "아웃랜드 ↔ Outland"])
        // A split that leaves a telling piece is still the name: these are how players type them.
        XCTAssertEqual(names(store, "going to un goro then kel thuzad"), ["운고로 분화구 ↔ Un'Goro Crater | Ungoro", "켈투자드 ↔ Kel'Thuzad"])
        XCTAssertEqual(names(store, "lfm zul farrak"), ["줄파락 ↔ Zul'Farrak"])
        XCTAssertEqual(names(store, "un'goro crater"), ["운고로 분화구 ↔ Un'Goro Crater"], "names of several words keep their tolerance for spacing")
        XCTAssertEqual(names(store, "ungorocrater"), ["운고로 분화구 ↔ Un'Goro Crater"])
    }

    func testNicknameRowTakesTheKoreanNameOfTheLoadedFlavor() throws {
        try writeData("official_names.classic.tsv", GlossaryTests.tsv("kind|korean|english", [
            "zone|힐스브래드 구릉지|Hillsbrad Foothills", "instance|검은심연의 나락|Blackfathom Deeps",
        ]))
        try writeData("official_names.retail.tsv", GlossaryTests.tsv("kind|korean|english", [
            "zone|언덕마루 구릉지|Hillsbrad Foothills", "instance|검은심연 나락|Blackfathom Deeps",
        ]))
        try writeData("nicknames.tsv", GlossaryTests.tsv("korean|english|aliases", [
            "힐스브래드 구릉지|Hillsbrad Foothills|Hillsbrad", "검은심연의 나락|Blackfathom Deeps|BFD", "안퀴라즈 사원|Temple of Ahn'Qiraj|AQ40",
        ]))
        let store = GlossaryStore(paths: paths, flavor: .classic)
        XCTAssertEqual(names(store, "LFG Hillsbrad Foothills quests"), ["힐스브래드 구릉지 ↔ Hillsbrad Foothills"])
        XCTAssertEqual(names(store, "lfm bfd"), ["검은심연의 나락 ↔ Blackfathom Deeps | BFD"])

        store.reload(flavor: .retail)
        XCTAssertEqual(names(store, "LFG Hillsbrad Foothills quests"), ["언덕마루 구릉지 ↔ Hillsbrad Foothills"])
        XCTAssertEqual(names(store, "hillsbrad pvp"), ["언덕마루 구릉지 ↔ Hillsbrad Foothills | Hillsbrad"])
        XCTAssertEqual(names(store, "lfm bfd"), ["검은심연 나락 ↔ Blackfathom Deeps | BFD"])
        XCTAssertEqual(names(store, "힐스브래드 구릉지 가요"), ["언덕마루 구릉지 | 힐스브래드 구릉지 ↔ Hillsbrad Foothills"],
                       "the older Korean name still leads to the current one")
        XCTAssertEqual(names(store, "aq40"), ["안퀴라즈 사원 ↔ Temple of Ahn'Qiraj | AQ40"], "a place the official table lacks keeps the row's own name")
    }

    func testLoadWarningsNameMissingFilesAndStrayTabs() throws {
        XCTAssertEqual(GlossaryStore(paths: paths, flavor: .classic).loadWarnings.count, 4, "nothing is there: four files missing")
        try installStandardFixtures()
        let store = GlossaryStore(paths: paths, flavor: .classic)
        XCTAssertEqual(store.loadWarnings, [])
        try writeData("nicknames.tsv", "korean\tenglish\taliases\n타나리스\tTanaris\tTana\tStray\n")
        try FileManager.default.removeItem(at: paths.dataDirectory.appendingPathComponent("abbreviations.retail.tsv"))
        store.reload(flavor: .retail)
        XCTAssertEqual(store.loadWarnings.count, 2)
        XCTAssertTrue(store.loadWarnings.contains { $0.contains("abbreviations.retail.tsv") })
        XCTAssertTrue(store.loadWarnings.contains { $0.hasPrefix("nicknames.tsv") })
    }

    // MARK: Abbreviations and skills

    func testAbbreviationMatching() throws {
        let store = try makeStore()
        XCTAssertEqual(abbreviations(store, "lfm zf"), ["LFM", "ZF"], "case-insensitive")
        XCTAssertEqual(abbreviations(store, "LF2M for farrak?"), ["LFM", "ZF"], "spellings from the also column")
        XCTAssertEqual(abbreviations(store, "anyone for Zul Farrak"), ["ZF"], "a spelling of several words")
        XCTAssertEqual(abbreviations(store, "LF tank tribute run"), ["tribute"])
        XCTAssertEqual(abbreviations(store, "trib in 5"), ["tribute"])
        XCTAssertEqual(abbreviations(store, "45 min UD Run"), ["ud run"])
        XCTAssertEqual(abbreviations(store, "if you want"), [], "IF is capitals-only because 'if' is a word")
        XCTAssertEqual(abbreviations(store, "port to IF"), ["IF"])
        XCTAssertEqual(abbreviations(store, "нужен танк в данж"), ["данж"])
        XCTAssertEqual(abbreviations(store, "го в данжи"), ["данж"])
        XCTAssertEqual(abbreviations(store, "NP"), ["NP", "np"], "exact case first, other case still offered")
        XCTAssertEqual(abbreviations(store, "np, happy to help"), ["np"],
                       "the file has a lower-case row of that spelling, so the capital one needs capitals")
        XCTAssertEqual(abbreviations(store, "no prob"), ["np"])
    }

    func testEverydayWordAsSecondSpellingNeedsCapitals() throws {
        let store = try makeStore()
        XCTAssertEqual(abbreviations(store, "we need a healer"), [], "'need' in the also column is an everyday word")
        XCTAssertEqual(abbreviations(store, "is the stream live yet"), ["live"], "the abbreviation itself is taken as written")
        XCTAssertEqual(abbreviations(store, "going LIVE side"), ["live"])
    }

    func testNameInsideLongerAbbreviationPhraseIsKept() throws {
        try writeData("official_names.classic.tsv", GlossaryTests.tsv("kind|korean|english", [
            "instance|스트라솔름|Stratholme", "instance|폭풍의 눈|Eye of the Storm",
        ]))
        try writeData("nicknames.tsv", GlossaryTests.tsv("korean|english|aliases", ["스트라솔름|Stratholme|Strat"]))
        try writeData("abbreviations.classic.tsv", GlossaryTests.tsv("abbr|also|english|korean|note", [
            "live|strat live, living|Stratholme living side||the Scarlet half",
            "eye||Tempest Keep: The Eye||raid",
        ]))
        let store = GlossaryStore(paths: paths, flavor: .classic)
        let hints = store.hints(for: ["LFG strat live"])
        XCTAssertEqual(hints.names, [GlossaryPair(korean: "스트라솔름", english: "Stratholme | Strat")])
        XCTAssertEqual(senses(hints), ["live | Stratholme living side |  | the Scarlet half"])
        // The other way round stays longest-match: an abbreviation inside a longer name is dropped.
        let eye = store.hints(for: ["queue for eye of the storm"])
        XCTAssertEqual(eye.names, [GlossaryPair(korean: "폭풍의 눈", english: "Eye of the Storm")])
        XCTAssertEqual(eye.abbreviations, [])
    }

    func testSymbolAndOneLetterAbbreviations() throws {
        let store = try makeStore()
        XCTAssertEqual(abbreviations(store, "8/8 H LF heals"), ["8/8", "H"])
        XCTAssertEqual(abbreviations(store, "level 88 hunter"), [])
        XCTAssertEqual(abbreviations(store, "LF +10 key"), ["+10"])
        XCTAssertEqual(abbreviations(store, "need 10 more"), [])
        XCTAssertEqual(abbreviations(store, "m+ tonight"), ["M+"])
        XCTAssertEqual(abbreviations(store, "h"), [], "one-letter abbreviations need the exact case")
        XCTAssertEqual(abbreviations(store, "ah ok"), [])
        XCTAssertEqual(abbreviations(store, "1"), ["1"])
        XCTAssertEqual(abbreviations(store, "need 1 more dps for the run"), [], "a lone digit only counts as the whole reply")
    }

    func testOneWordSpellsAreOfferedAsSkillsNotNames() throws {
        let store = try makeStore()
        let hints = store.hints(for: ["charge then fear and sap the add"])
        XCTAssertEqual(hints.looseNames, [
            GlossaryPair(korean: "돌진", english: "Charge"),
            GlossaryPair(korean: "공포", english: "Fear"),
            GlossaryPair(korean: "기절시키기", english: "Sap"),
        ])
        XCTAssertEqual(hints.names, [])
        XCTAssertEqual(store.hints(for: ["돌진 쓰고 마법차단"]).looseNames.map(\.english), ["Counterspell", "Charge"])
        XCTAssertEqual(store.hints(for: ["recharge, fearless"]).looseNames, [])
        XCTAssertEqual(store.hints(for: ["turn on the light"]).looseNames, [], "a spell that is an everyday English word")
        XCTAssertEqual(store.hints(for: ["빛 써주세요"]).looseNames, [], "one-syllable Korean spell names")

        XCTAssertEqual(store.hints(for: ["frost mage LFG"]).looseNames, [GlossaryPair(korean: "냉기", english: "Frost")],
                       "a one-word specialization name is context-dependent too")
        XCTAssertEqual(names(store, "frost mage LFG"), [])

        // A spell name of several words is a name like any other.
        let buff = store.hints(for: ["can i get power word fortitude"])
        XCTAssertEqual(buff.names, [GlossaryPair(korean: "신의 권능: 인내", english: "Power Word: Fortitude")])
        XCTAssertEqual(buff.looseNames, [])
    }

    // MARK: Corrections

    private func makeStoreWithCorrections() throws -> GlossaryStore {
        try installStandardFixtures()
        try writeRoot("corrections.tsv", GlossaryTests.corrections)
        return GlossaryStore(paths: paths, flavor: .classic)
    }

    func testCorrectionsTolerateOCRNoise() throws {
        let store = try makeStoreWithCorrections()
        XCTAssertEqual(store.hints(for: ["LF healer ZF then mara"]).corrections.map(\.translation), ["줄파락 갔다가 마라우돈 갈 힐러 구함"])
        XCTAssertEqual(store.hints(for: ["lf  healer zf, then mara!"]).corrections.count, 1, "case, spacing and punctuation")
        XCTAssertEqual(store.hints(for: ["WTS PORTALS TO DARNASSUS 2G"]).corrections.map(\.source), ["WTS PORTA1S TO DARNASUS 2G"])
        XCTAssertEqual(store.hints(for: ["WTS PORTA1S TO DARNASUS 3G"]).corrections.count, 1)
        XCTAssertEqual(store.hints(for: ["缺个奶 就差一个"]).corrections.count, 1)
        XCTAssertEqual(store.hints(for: ["缺个奶就差一个 速度"]).corrections.count, 1)
        XCTAssertEqual(store.hints(for: ["WTB PORTAL TO IRONFORGE"]).corrections, [])
        XCTAssertEqual(store.hints(for: ["LFM DM need tank"]).corrections, [])
        XCTAssertEqual(store.hints(for: ["ty"]).corrections.map(\.translation), ["ㄳ"])
        XCTAssertEqual(store.hints(for: ["tu"]).corrections, [], "very short lines only match exactly")
    }

    func testAddCorrectionRoundTrip() throws {
        let store = try makeStore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.correctionsFile.path))

        let first = CorrectionExample(source: "any1 for arena/anger run brd", translation: "나락 투기장·분노 런 가실 분", note: "anger는 장군 앵거포지입니다.")
        store.addCorrection(first)
        store.addCorrection(CorrectionExample(source: "multi\nline\tsrc", translation: "두 줄\n번역\t아님", note: nil))
        store.addCorrection(CorrectionExample(source: "  ", translation: "빈 원문은 무시", note: nil))

        XCTAssertEqual(store.hints(for: ["any1 for arena/anger run brd"]).corrections, [first], "visible immediately")
        XCTAssertEqual(store.hints(for: ["any1 for arena/anger run brd pls"]).corrections, [first])

        let text = try String(contentsOf: paths.correctionsFile, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines[0].hasPrefix("#") && lines[1].hasPrefix("#"), "a new file starts with two explanatory comment lines")
        XCTAssertEqual(lines[2], "source\ttranslation\tnote", "and the column names")
        XCTAssertEqual(lines[3], "any1 for arena/anger run brd\t나락 투기장·분노 런 가실 분\tanger는 장군 앵거포지입니다.")
        XCTAssertEqual(lines[4], "multi line src\t두 줄 번역 아님")

        // A fresh store reads the same thing back.
        let again = GlossaryStore(paths: paths, flavor: .classic)
        XCTAssertEqual(again.hints(for: ["any1 for arena/anger run brd"]).corrections, [first])
        XCTAssertEqual(again.hints(for: ["multi line src"]).corrections,
                       [CorrectionExample(source: "multi line src", translation: "두 줄 번역 아님", note: nil)])

        // A newer correction of the same text replaces the older one.
        store.addCorrection(CorrectionExample(source: "ANY1 for arena/anger run BRD", translation: "나락 투기장 앵거포지 런 구함", note: nil))
        XCTAssertEqual(store.hints(for: ["any1 for arena/anger run brd"]).corrections.map(\.translation), ["나락 투기장 앵거포지 런 구함"])
        store.reload(flavor: .classic)
        XCTAssertEqual(store.hints(for: ["any1 for arena/anger run brd"]).corrections.map(\.translation), ["나락 투기장 앵거포지 런 구함"])
    }

    func testAddCorrectionAppendsAfterFileWithoutTrailingNewline() throws {
        try installStandardFixtures()
        try writeRoot("corrections.tsv", "hand edited\t손으로 고침")
        let store = GlossaryStore(paths: paths, flavor: .classic)
        store.addCorrection(CorrectionExample(source: "second line", translation: "둘째 줄", note: nil))
        let text = try String(contentsOf: paths.correctionsFile, encoding: .utf8)
        XCTAssertEqual(text, "hand edited\t손으로 고침\nsecond line\t둘째 줄\n")
    }

    func testAddCorrectionCreatesMissingFolder() throws {
        let fresh = AppPaths(root: root.appendingPathComponent("not-there-yet", isDirectory: true))
        let store = GlossaryStore(paths: fresh, flavor: .retail)
        store.addCorrection(CorrectionExample(source: "hello there", translation: "안녕", note: nil))
        XCTAssertEqual(GlossaryParser.parseCorrections(try String(contentsOf: fresh.correctionsFile, encoding: .utf8)),
                       [CorrectionExample(source: "hello there", translation: "안녕", note: nil)])
    }

    // MARK: Outgoing commands

    func testParseOutgoing() throws {
        let store = try makeStore()
        XCTAssertEqual(store.parseOutgoing("안녕하세요"), OutgoingCommand(command: nil, text: "안녕하세요"))
        XCTAssertEqual(store.parseOutgoing("  안녕  "), OutgoingCommand(command: nil, text: "안녕"))
        XCTAssertEqual(store.parseOutgoing("/ㄴ 반가워요"), OutgoingCommand(command: "/s", text: "반가워요"))
        XCTAssertEqual(store.parseOutgoing("/ㅎ 오늘 레이드 가요"), OutgoingCommand(command: "/g", text: "오늘 레이드 가요"))
        XCTAssertEqual(store.parseOutgoing("/ㅔ 탱커 구해요"), OutgoingCommand(command: "/p", text: "탱커 구해요"))
        XCTAssertEqual(store.parseOutgoing("/길드 안녕"), OutgoingCommand(command: "/g", text: "안녕"))
        XCTAssertEqual(store.parseOutgoing("/SAY 안녕"), OutgoingCommand(command: "/s", text: "안녕"))
        XCTAssertEqual(store.parseOutgoing("/외침   도와주세요"), OutgoingCommand(command: "/y", text: "도와주세요"))
        XCTAssertEqual(store.parseOutgoing("／ㄴ 안녕"), OutgoingCommand(command: "/s", text: "안녕"), "full-width slash")
        XCTAssertEqual(store.parseOutgoing("/공 모이세요"), OutgoingCommand(command: "/ra", text: "모이세요"))
        XCTAssertEqual(store.parseOutgoing("/ㄱ 네 갈게요"), OutgoingCommand(command: "/r", text: "네 갈게요"))
        XCTAssertEqual(store.parseOutgoing("/me 춤춘다"), OutgoingCommand(command: "/e", text: "춤춘다"))
        XCTAssertEqual(store.parseOutgoing("/s"), OutgoingCommand(command: "/s", text: ""))
    }

    func testParseOutgoingWhisperKeepsTarget() throws {
        let store = try makeStore()
        XCTAssertEqual(store.parseOutgoing("/ㅈ Thrall 안녕"), OutgoingCommand(command: "/w Thrall", text: "안녕"))
        XCTAssertEqual(store.parseOutgoing("/귓 Jaina-Stormrage 파티 초대 좀 해줘"),
                       OutgoingCommand(command: "/w Jaina-Stormrage", text: "파티 초대 좀 해줘"))
        XCTAssertEqual(store.parseOutgoing("/tell 쓰랄  고마워요"), OutgoingCommand(command: "/w 쓰랄", text: "고마워요"))
        XCTAssertEqual(store.parseOutgoing("/w Thrall"), OutgoingCommand(command: "/w Thrall", text: ""))
        XCTAssertEqual(store.parseOutgoing("/w"), OutgoingCommand(command: "/w", text: ""))
        XCTAssertEqual(store.parseOutgoing("/ㅊ 4 탱커 구함"), OutgoingCommand(command: "/c 4", text: "탱커 구함"))
    }

    func testParseOutgoingNumberedChannelsAndOtherCommands() throws {
        let store = try makeStore()
        XCTAssertEqual(store.parseOutgoing("/1 hello"), OutgoingCommand(command: "/1", text: "hello"))
        XCTAssertEqual(store.parseOutgoing("/2 아케이나이트 팝니다"), OutgoingCommand(command: "/2", text: "아케이나이트 팝니다"))
        XCTAssertEqual(store.parseOutgoing("/10"), OutgoingCommand(command: "/10", text: ""))
        // Not chat: the whole line is the command and nothing is left to translate.
        XCTAssertEqual(store.parseOutgoing("/roll 100"), OutgoingCommand(command: "/roll 100", text: ""))
        XCTAssertEqual(store.parseOutgoing("/초대 홍길동"), OutgoingCommand(command: "/초대 홍길동", text: ""))
        XCTAssertEqual(store.parseOutgoing("/ㅋㅋ 뭐야"), OutgoingCommand(command: "/ㅋㅋ 뭐야", text: ""))
        XCTAssertEqual(store.parseOutgoing("/ 안녕"), OutgoingCommand(command: nil, text: "/ 안녕"))
        XCTAssertEqual(store.parseOutgoing(""), OutgoingCommand(command: nil, text: ""))
    }

    func testParseOutgoingWorksWithoutCommandFile() {
        // English commands are built in, and a command typed with the Korean keyboard still on is
        // read by the keys pressed.
        let store = GlossaryStore(paths: paths, flavor: .classic)
        XCTAssertEqual(store.parseOutgoing("/s 안녕"), OutgoingCommand(command: "/s", text: "안녕"))
        XCTAssertEqual(store.parseOutgoing("/ㄴ 반가워요"), OutgoingCommand(command: "/s", text: "반가워요"))
        XCTAssertEqual(store.parseOutgoing("/ㅈ Thrall 안녕"), OutgoingCommand(command: "/w Thrall", text: "안녕"))
        XCTAssertEqual(store.parseOutgoing("/ㅑ 가자"), OutgoingCommand(command: "/i", text: "가자"))
        XCTAssertEqual(store.parseOutgoing("/ㄱㅁ 모이세요"), OutgoingCommand(command: "/ra", text: "모이세요"))
        XCTAssertEqual(store.parseOutgoing("/ㄱㅈ 쫄 온다"), OutgoingCommand(command: "/rw", text: "쫄 온다"))
        XCTAssertEqual(store.parseOutgoing("/officer 회의합시다"), OutgoingCommand(command: "/o", text: "회의합시다"))
        XCTAssertEqual(store.parseOutgoing("/말 안녕"), OutgoingCommand(command: "/말 안녕", text: ""), "Korean words come from the file")
    }

    func testCommandFileDecidesTheCanonicalCommand() throws {
        try writeData("chat_commands.classic.tsv", GlossaryTests.tsv("chat_type|canonical|aliases", [
            "SAY|/talk|/말 /s /ㄴ",
            "CUSTOM||/맞춤 /cst /custom",
            "BN_WHISPER|/bnw|/친구귓",
        ]))
        let store = GlossaryStore(paths: paths, flavor: .classic)
        XCTAssertEqual(store.parseOutgoing("/ㄴ 반가워요"), OutgoingCommand(command: "/talk", text: "반가워요"))
        XCTAssertEqual(store.parseOutgoing("/talk 안녕"), OutgoingCommand(command: "/talk", text: "안녕"), "the canonical command is a spelling too")
        XCTAssertEqual(store.parseOutgoing("/맞춤 안녕"), OutgoingCommand(command: "/cst", text: "안녕"),
                       "without a canonical cell the first plain-English spelling is used")
        XCTAssertEqual(store.parseOutgoing("/친구귓 Jaina 안녕"), OutgoingCommand(command: "/bnw Jaina", text: "안녕"))
        XCTAssertEqual(store.parseOutgoing("/ㅎ 안녕"), OutgoingCommand(command: "/g", text: "안녕"), "built-in table still applies")

        // A row of Korean spellings only borrows the built-in command of its chat type.
        try writeData("chat_commands.classic.tsv", GlossaryTests.tsv("chat_type|canonical|aliases", [
            "SAY||/말 /ㄴ", "MYSTERY||/수수께끼",
        ]))
        store.reload(flavor: .classic)
        XCTAssertEqual(store.parseOutgoing("/말 안녕"), OutgoingCommand(command: "/s", text: "안녕"))
        XCTAssertEqual(store.parseOutgoing("/수수께끼 안녕"), OutgoingCommand(command: "/수수께끼 안녕", text: ""), "an unknown chat type has nothing to borrow")
    }

    // MARK: Flavor, reload, missing data

    func testFlavorPicksFileSetAndReloadSwitches() throws {
        let store = try makeStore(.classic)
        XCTAssertEqual(store.entryCount, GlossaryTests.officialClassicCount)
        XCTAssertEqual(names(store, "Classic Only Zone"), ["클래식 전용 ↔ Classic Only Zone"])
        XCTAssertEqual(names(store, "Isle of Dorn"), [])
        XCTAssertEqual(store.hints(for: ["DM me"]).abbreviations.count, 2)

        store.reload(flavor: .retail)
        XCTAssertEqual(store.loadedFlavor, .retail)
        XCTAssertEqual(store.entryCount, 2)
        XCTAssertEqual(store.abbreviationCount, 1)
        XCTAssertEqual(names(store, "Classic Only Zone"), [])
        XCTAssertEqual(names(store, "Isle of Dorn"), ["도른의 섬 ↔ Isle of Dorn"])
        XCTAssertEqual(senses(store.hints(for: ["DM me"])), ["DM | private message |  | \"DM me\" asks for a whisper"])
        XCTAssertEqual(names(store, "heading to STV"), ["가시덤불 골짜기 ↔ Stranglethorn Vale | STV"], "nicknames.tsv is shared")

        // reload picks up an edited my_terms.tsv.
        try writeRoot("my_terms.tsv", "도른 섬\tIsle of Dorn\n")
        store.reload(flavor: .retail)
        XCTAssertEqual(names(store, "Isle of Dorn"), ["도른 섬 ↔ Isle of Dorn"])
    }

    func testMissingFilesAreFine() {
        let store = GlossaryStore(paths: AppPaths(root: root.appendingPathComponent("nothing")), flavor: .retail)
        XCTAssertEqual(store.entryCount, 0)
        XCTAssertEqual(store.abbreviationCount, 0)
        XCTAssertTrue(store.hints(for: ["LFM DM need tank", "", "   ", "혈장 가실분"]).isEmpty)
        XCTAssertTrue(store.hints(for: []).isEmpty)
    }

    func testOddInputDoesNotCrash() throws {
        let store = try makeStore()
        let odd = ["", " ", "'", "[]", "[", "]]]", "////", "+", "8/", "s", "S", "'s", "🙂🙂", "e\u{301}e\u{301}", "\u{200B}",
                   "İstanbul ß ǅ", String(repeating: "DM ", count: 3000), String(repeating: "가", count: 5000),
                   String(repeating: "x", count: 20000), "\u{1112}\u{1161}\u{11AB}", "a\u{0}b", "\t\t\t", "#"]
        for text in odd {
            _ = store.hints(for: [text])
            _ = store.parseOutgoing(text)
            _ = GlossaryParser.parseOfficialNames(text)
            _ = GlossaryParser.parseNicknames(text)
            _ = GlossaryParser.parseAbbreviations(text)
            _ = GlossaryParser.parseCommands(text)
        }
        XCTAssertEqual(names(store, "스톰윈드"), names(store, "스톰윈드".decomposedStringWithCanonicalMapping), "decomposed Hangul")
    }

    func testConcurrentUse() throws {
        let store = try makeStore()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            switch i % 4 {
            case 0: store.addCorrection(CorrectionExample(source: "concurrent line number \(i)", translation: "번역 \(i)", note: nil))
            case 1: XCTAssertEqual(store.hints(for: ["LFM Dire Maul"]).names.count, 1)
            case 2: XCTAssertEqual(store.parseOutgoing("/ㄴ 반가워요").command, "/s")
            default:
                if i % 40 == 3 { store.reload(flavor: i % 80 == 3 ? .retail : .classic) }
                XCTAssertGreaterThan(store.entryCount, 0)
            }
        }
        let saved = GlossaryParser.parseCorrections(try String(contentsOf: paths.correctionsFile, encoding: .utf8))
        XCTAssertEqual(saved.count, 50, "every appended line is intact")
        XCTAssertEqual(Set(saved.map(\.source)).count, 50)
        store.reload(flavor: .classic)
        XCTAssertEqual(store.hints(for: ["concurrent line number 4"]).corrections.first?.translation, "번역 4")
    }

    // MARK: Data folder upkeep

    func testSeedCopiesMissingAndChangedFilesOnly() throws {
        let bundled = root.appendingPathComponent("bundle-data", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        func bundle(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: bundled.appendingPathComponent(name)) }
        try bundle("official_names.classic.tsv", GlossaryTests.officialClassic)
        try bundle("nicknames.tsv", GlossaryTests.nicknames)
        try bundle("abbreviations.classic.tsv", GlossaryTests.abbreviationsClassic)
        try bundle("empty.tsv", "")
        try bundle("notes.txt", "not a dictionary file")
        try FileManager.default.createDirectory(at: bundled.appendingPathComponent("folder.tsv"), withIntermediateDirectories: true)

        // Fresh install: the data folder does not exist yet.
        let fresh = AppPaths(root: root.appendingPathComponent("fresh", isDirectory: true))
        let first = DictionaryFiles.seed(from: bundled, to: fresh)
        XCTAssertEqual(first.changed, ["abbreviations.classic.tsv", "nicknames.tsv", "official_names.classic.tsv"])
        XCTAssertEqual(first.failures, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fresh.dataDirectory.path).sorted(), first.changed)
        XCTAssertEqual(GlossaryStore(paths: fresh, flavor: .classic).entryCount, GlossaryTests.officialClassicCount)
        XCTAssertEqual(DictionaryFiles.seed(from: bundled, to: fresh).changed, [], "identical files are left alone")

        // A new build: one file changed while keeping its size, one grew, one is untouched.
        let sameSize = GlossaryTests.nicknames.replacingOccurrences(of: "STV", with: "STX")
        XCTAssertEqual(sameSize.utf8.count, GlossaryTests.nicknames.utf8.count)
        try bundle("nicknames.tsv", sameSize)
        try bundle("abbreviations.classic.tsv", GlossaryTests.abbreviationsClassic + "gz\t\tcongratulations\t축하\t\n")
        try Data("left by the user".utf8).write(to: fresh.dataDirectory.appendingPathComponent("other.txt"))
        XCTAssertEqual(DictionaryFiles.seed(from: bundled, to: fresh).changed, ["abbreviations.classic.tsv", "nicknames.tsv"])
        let store = GlossaryStore(paths: fresh, flavor: .classic)
        XCTAssertEqual(names(store, "heading to STX"), ["가시덤불 골짜기 ↔ Stranglethorn Vale | STX"])
        XCTAssertEqual(abbreviations(store, "gz man"), ["gz"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.dataDirectory.appendingPathComponent("other.txt").path))

        // A .tsv this bundle does not ship is removed; the standard files
        // this small bundle lacks are not, and neither is anything that is no .tsv.
        try Data("old".utf8).write(to: fresh.dataDirectory.appendingPathComponent("stray_table.tsv"))
        try Data("kept".utf8).write(to: fresh.dataDirectory.appendingPathComponent("official_names.retail.tsv"))
        XCTAssertEqual(DictionaryFiles.seed(from: bundled, to: fresh).changed, ["stray_table.tsv"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fresh.dataDirectory.path).sorted(),
                       ["abbreviations.classic.tsv", "nicknames.tsv", "official_names.classic.tsv", "official_names.retail.tsv", "other.txt"])

        XCTAssertEqual(DictionaryFiles.seed(from: root.appendingPathComponent("no-bundle"), to: fresh), DictionaryFiles.Report())
    }

    // MARK: Performance

    func testLargeDictionaryLoadsAndAnswersQuickly() throws {
        // About the size of one flavor's official name table: 40k generated rows.
        let syllables = ["검은", "바위", "폭풍", "서리", "화염", "그늘", "달빛", "칼날", "용의", "숲", "요새", "협곡", "성채", "둥지"]
        let words = ["Black", "Rock", "Storm", "Frost", "Flame", "Shadow", "Moon", "Blade", "Dragon", "Forest", "Keep", "Gulch", "Hold", "Lair"]
        let kinds = ["zone", "subzone", "instance", "boss", "item", "spell", "achievement", "mount"]
        var text = "# generated\nkind\tkorean\tenglish\n"
        text.reserveCapacity(2_400_000)
        for i in 0..<40_000 {
            let a = i % 14, b = (i / 14) % 14, c = (i / 196) % 14
            text += "\(kinds[i % kinds.count])\t\(syllables[a]) \(syllables[b]) \(syllables[c]) \(i)\t\(words[a]) \(words[b]) of the \(words[c]) \(i)\n"
        }
        try writeData("official_names.classic.tsv", text)
        try writeData("nicknames.tsv", GlossaryTests.nicknames)
        var abbreviations = GlossaryTests.abbreviationsClassic
        for i in 0..<3_000 { abbreviations += "ab\(i)x\talso\(i)x, other\(i)y\tMeaning number \(i)\t뜻 \(i)번\tgenerated sense \(i)\n" }
        try writeData("abbreviations.classic.tsv", abbreviations)

        let loadStart = Date()
        let store = GlossaryStore(paths: paths, flavor: .classic)
        let loadTime = Date().timeIntervalSince(loadStart)
        XCTAssertEqual(store.entryCount, 40_000)
        XCTAssertEqual(store.abbreviationCount, GlossaryTests.abbreviationClassicRows.count - 2 + 3_000)
        XCTAssertLessThan(loadTime, 2.0, "load took \(loadTime)s")

        let lines = [
            "LFM DM need tank and healer then Black Rock of the Storm 406 pst",
            "혈투의 전장 가실분 검은 바위 폭풍 406 앞에서 모여요 스톰윈드에서 출발합니다",
            "下午组DM还缺2dps打完转血色最后回达拉然集合有意的直接密我人齐马上出发",
            "WTS Flame Shadow of the Moon 1234 and Dragon Forest of the Keep 39999 cheap cheap cheap /w me",
        ]
        XCTAssertEqual(names(store, lines[0]).first, "죽음의 폐광 ↔ The Deadmines | DM(low-level groups, around 18-23)")
        XCTAssertTrue(names(store, lines[0]).contains("검은 바위 폭풍 406 ↔ Black Rock of the Storm 406"))
        XCTAssertTrue(names(store, lines[1]).contains("검은 바위 폭풍 406 ↔ Black Rock of the Storm 406"))
        XCTAssertEqual(self.abbreviations(store, "lf other2999y"), ["ab2999x"])

        let rounds = 50
        let start = Date()
        for _ in 0..<rounds { for line in lines { _ = store.hints(for: [line]) } }
        let perLine = Date().timeIntervalSince(start) / Double(rounds * lines.count)
        XCTAssertLessThan(perLine, 0.005, "hints took \(perLine * 1000) ms per line")
        print("Glossary 40k load \(String(format: "%.3f", loadTime))s, hints \(String(format: "%.3f", perLine * 1000)) ms per line")
    }

    // MARK: The shipped data files (skipped while data/ is not generated yet)

    private func shippedStore(_ flavor: GameFlavor) throws -> GlossaryStore {
        let data = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data", isDirectory: true)
        let files = DictionaryFiles.names(for: flavor)
        guard FileManager.default.fileExists(atPath: data.appendingPathComponent(files.officialNames).path) else {
            throw XCTSkip("data/\(files.officialNames) is not there")
        }
        // Read through a link; nothing is copied or modified.
        try FileManager.default.removeItem(at: paths.dataDirectory)
        try FileManager.default.createSymbolicLink(at: paths.dataDirectory, withDestinationURL: data)
        return GlossaryStore(paths: paths, flavor: flavor)
    }

    /// Chat lines that once drew wrong hints from the shipped files (found with --dictionary-check).
    func testShippedDataGivesNoHintsForOrdinaryLines() throws {
        let quiet = [
            "이 퀘스트에 대해 아시는 분 있나요", "도시로 돌아가서 수리할게요", "임시 공대장 맡을게요", "자리 없음 다음에 같이 가요",
            "정원 구경 갑시다", "시장 가서 물약 살게요", "월드 오브 워크래프트 정말 재밌네요",
            "the boss hits really hard so stay behind him", "moss is growing on this server",
            "we will take down the boss tonight", "dont burn out, take a break", "we over run them every time",
            "free hold my beer", "let me set up the group first", "out land is boring",
            "i'd like to join if you still have room", "shoot, the boat left without me",
            "lower your price and i will buy it", "anyone living in europe here?", "OK thanks, see you at the inn",
            "so many bugs in this game", "take a seat and wait",
        ]
        for flavor in [GameFlavor.classic, .retail] {
            let store = try shippedStore(flavor)
            XCTAssertEqual(store.loadWarnings, [])
            for line in quiet {
                let hints = store.hints(for: [line])
                XCTAssertTrue(hints.isEmpty, "\(flavor) \(line): \(hints.names) \(hints.looseNames) \(hints.abbreviations.map(\.abbr))")
            }
            XCTAssertEqual(abbreviations(store, "np, happy to help"), ["np"])
            XCTAssertEqual(abbreviations(store, "ur gear is fine"), ["ur"])
            XCTAssertEqual(Set(store.hints(for: ["eng only pls"]).abbreviations.filter { $0.abbr == "eng" }.map(\.english)),
                           ["Engineering", "English language"])
            XCTAssertEqual(Set(store.hints(for: ["need tranq for the enrage"]).abbreviations.filter { $0.abbr == "tranq" }.map(\.english)),
                           ["Tranquility", "Tranquilizing Shot"])
            XCTAssertEqual(names(store, "going to un goro"), ["운고로 분화구 ↔ Un'Goro Crater | Ungoro"])
            // One Korean name per place, and no nickname that outranks another meaning of the same letters.
            for line in ["going to Deadwind Pass", "inc Stonehearth Graveyard", "Moonglade", "LFM Old Hillsbrad Foothills",
                         "Jin'do the Hexxer", "meet at The Crossroads"] {
                XCTAssertEqual(names(store, line).count, 1, "\(flavor) \(line): \(names(store, line))")
            }
            for line in ["LF CE guild, 8/8 H exp", "LFM AD +12 need healer", "lfm uld need tank", "lf exo and kings"] {
                XCTAssertEqual(names(store, line), [], "\(flavor) \(line)")
            }
            try setUpWithError()
        }
        let classic = try shippedStore(.classic)
        XCTAssertEqual(Set(classic.hints(for: ["since the last patch"]).abbreviations.map(\.english)), ["Patchwerk", "game update"])
        XCTAssertEqual(Set(classic.hints(for: ["lfm uld need tank"]).abbreviations.filter { $0.abbr == "uld" }.map(\.english)), ["Ulduar", "Uldaman"])
        XCTAssertEqual(classic.parseOutgoing("/i 준비됐나요"), OutgoingCommand(command: "/instance", text: "준비됐나요"),
                       "the one spelling every classic client reads as instance chat")
        XCTAssertEqual(classic.parseOutgoing("/bg 가자"), OutgoingCommand(command: "/bg", text: "가자"))
        try setUpWithError()
        let retail = try shippedStore(.retail)
        XCTAssertEqual(names(retail, "LFG Hillsbrad Foothills quests"), ["언덕마루 구릉지 ↔ Hillsbrad Foothills"])
        XCTAssertEqual(retail.parseOutgoing("/i 준비됐나요"), OutgoingCommand(command: "/i", text: "준비됐나요"))
    }

    /// nicknames.tsv promises an official pair of the classic table in its first two columns.
    func testShippedNicknamesAreOfficialPairsAndTablesAreClean() throws {
        let data = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data", isDirectory: true)
        guard let classicText = GlossaryParser.readText(data.appendingPathComponent("official_names.classic.tsv")),
              let retailText = GlossaryParser.readText(data.appendingPathComponent("official_names.retail.tsv")),
              let nicknameText = GlossaryParser.readText(data.appendingPathComponent("nicknames.tsv")) else {
            throw XCTSkip("data/ is not there")
        }
        let classic = GlossaryParser.parseOfficialNames(classicText), retail = GlossaryParser.parseOfficialNames(retailText)
        let classicPairs = Set(classic.map { GlossaryPair(korean: $0.korean, english: $0.english) })
        let retailEnglish = Set(retail.map(\.english))
        let nicknames = GlossaryParser.parseNicknames(nicknameText)
        XCTAssertGreaterThan(nicknames.count, 80)
        for line in nicknames {
            XCTAssertTrue(classicPairs.contains(GlossaryPair(korean: line.korean[0].text, english: line.english[0].text)),
                          "\(line.korean[0].text) / \(line.english[0].text) is not in official_names.classic.tsv")
            XCTAssertTrue(retailEnglish.contains(line.english[0].text), "\(line.english[0].text) is not in official_names.retail.tsv")
            XCTAssertGreaterThan(line.english.count + line.korean.count, 2, "\(line.english[0].text) has no alias")
        }
        // Places, bosses and factions carry one Korean name per English name; scratch rows are gone.
        let single: Set<String> = ["zone", "instance", "boss", "faction", "class", "race", "profession", "subzone"]
        for (flavor, rows) in [("classic", classic), ("retail", retail)] {
            var korean: [String: Set<String>] = [:]
            for row in rows where single.contains(row.kind) {
                korean[(row.kind == "subzone" ? "s:" : "p:") + row.english.lowercased(), default: []].insert(row.korean)
            }
            let doubled = korean.filter { $0.value.count > 1 }
            XCTAssertEqual(doubled.count, 0, "\(flavor): \(doubled.prefix(5))")
            for row in rows {
                XCTAssertFalse(row.english.contains("TEMP") || row.english.contains("WoWEdit") || row.korean == "임시"
                               || row.english == "n/a" || row.english.hasPrefix("Monster, "), "\(flavor): \(row)")
            }
            XCTAssertFalse(rows.contains { $0.kind == "faction" && ["Classic", "Guild", "The Burning Crusade"].contains($0.english) }, flavor)
        }
        for flavor in ["classic", "retail"] {
            let table = GlossaryParser.tsvTable(GlossaryParser.readText(data.appendingPathComponent("abbreviations.\(flavor).tsv")) ?? "",
                                                columns: GlossaryParser.abbreviationColumns)
            XCTAssertEqual(table.overlong, 0)
            XCTAssertGreaterThan(table.rows.count, 500)
        }
    }

    func testShippedOfficialNamesLoadFastAndAnswerQuickly() throws {
        let lines = [
            "LFM Dire Maul need tank", "혈투의 전장 가실분 스톰윈드에서 출발", "组DM 缺2dps 打完转血色 回达拉然",
            "WTS Arcanite Bar and Thunderfury, Blessed Blade of the Windseeker pst",
            "anyone in the barrens want to help with the quest in wetlands for the hunter",
            "가시덤불 골짜기에서 전사 한 분 돌진 좀 써 주세요 검은바위 첨탑 갈 사람 모집합니다 화산 심장부도 갑니다",
            String(repeating: "LFM UBRS need tank healer dps pst have key and summons ", count: 5),
        ]
        for flavor in [GameFlavor.classic, .retail] {
            let start = Date()
            let store = try shippedStore(flavor)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertGreaterThan(store.entryCount, 10_000)
            XCTAssertLessThan(elapsed, 2.0, "\(flavor) load took \(elapsed)s")

            XCTAssertEqual(store.hints(for: ["LFM Dire Maul need tank"]).names, [GlossaryPair(korean: "혈투의 전장", english: "Dire Maul")])
            XCTAssertTrue(store.hints(for: ["스톰윈드에서 출발"]).names.contains { $0.english.hasPrefix("Stormwind") })
            XCTAssertTrue(store.hints(for: ["The quick brown fox jumps over the lazy dog and went home because it was late"]).names.isEmpty)
            XCTAssertTrue(store.hints(for: ["i think we should go there and see what they have for us, thanks man"]).names.isEmpty)
            XCTAssertEqual(store.parseOutgoing("/ㅛ 도와주세요"), OutgoingCommand(command: "/y", text: "도와주세요"))
            XCTAssertEqual(store.parseOutgoing("/길드 안녕"), OutgoingCommand(command: "/g", text: "안녕"))
            XCTAssertEqual(store.parseOutgoing("/귓 Thrall 안녕"), OutgoingCommand(command: "/w Thrall", text: "안녕"))

            var worst = 0.0
            for line in lines {
                let lineStart = Date()
                for _ in 0..<20 { _ = store.hints(for: [line]) }
                worst = max(worst, Date().timeIntervalSince(lineStart) / 20)
            }
            XCTAssertLessThan(worst, 0.005, "\(flavor): slowest line took \(worst * 1000) ms")
            print("Shipped data \(flavor): \(store.entryCount) names, \(store.abbreviationCount) abbreviations, load "
                  + "\(String(format: "%.3f", elapsed))s, slowest line \(String(format: "%.3f", worst * 1000)) ms")
            for line in lines.prefix(6) {
                let hints = store.hints(for: [line])
                print("   \(line.prefix(60)) -> names \(hints.names.map { "\($0.korean)=\($0.english)" }) skills \(hints.looseNames.map(\.english))")
            }
            try setUpWithError()
        }
    }
}
