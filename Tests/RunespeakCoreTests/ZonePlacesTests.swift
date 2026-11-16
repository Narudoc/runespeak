import XCTest
@testable import RunespeakCore

/// Places of the zone a line was said in (zone_places.<flavor>.tsv): which zone a channel label
/// names, which places a line may be speaking of, and how they reach the translation model.
/// The zones, places and chat lines of the fixtures are invented.
final class ZonePlacesTests: XCTestCase {

    // MARK: Fixtures

    private var root: URL!
    private var paths: AppPaths { AppPaths(root: root) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("runespeak-places-\(UUID().uuidString)", isDirectory: true)
        try paths.ensureDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A fresh folder for the next store of the same test; the one before is removed.
    private func startOver() throws {
        try? FileManager.default.removeItem(at: root)
        try setUpWithError()
    }

    private func writeData(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: paths.dataDirectory.appendingPathComponent(name))
    }

    /// Rows written as "a|b|c" for readability; the files use tabs.
    private static func tsv(_ header: String, _ rows: [String]) -> String {
        (["# generated for the tests", header] + rows).map { $0.replacingOccurrences(of: "|", with: "\t") }.joined(separator: "\n") + "\n"
    }

    private static let reach = "1. General - Mistral Reach"
    private static let wood = "1. General - Windgap Wood"

    private static let places = tsv("zone_korean|zone_english|korean|english", [
        // Another Korean name of the zone (a later client's), ahead of its places as the tool writes it.
        "안개언덕|Mistral Reach||",
        "안개 마루터|Mistral Reach|쇠부리 발굴현장|Ironbeak Excavation Site",
        "안개 마루터|Mistral Reach|쇠부리의 은거지|Ironbeak's Retreat",
        "안개 마루터|Mistral Reach|갈매기 부두|Gullwing Wharf",
        "안개 마루터|Mistral Reach|갈매기 등대|Gullwing Lighthouse",
        "안개 마루터|Mistral Reach|소금바람 선술집|Saltbreeze Tavern",
        "안개 마루터|Mistral Reach|코르벤달 교각|Korvendal Span",
        "안개 마루터|Mistral Reach|옛 공원|The Park",
        "안개 마루터|Mistral Reach|초록 띠|The Green Belt",
        "안개 마루터|Mistral Reach|대성당 광장|Cathedral Square",
        "안개 마루터|Mistral Reach|상업 지구|Trade District",
        "안개 마루터|Mistral Reach|구 시가지|Old Town",
        "안개 마루터|Mistral Reach|마루터 요새|Mistral Keep",
        "안개 마루터|Mistral Reach|대해|The Great Sea",
        "안개 마루터|Mistral Reach|잃어버린 함대|The Lost Fleet",
        "안개 마루터|Mistral Reach|가시마루 요새|Thornridge Hold",
        "안개 마루터|Mistral Reach|호박방아 농장|Ambermill Farm",
        "안개 마루터|Mistral Reach|검은엉겅퀴 숲|Blackthistle Grove",
        "안개 마루터|Mistral Reach|주석 광산|Tin Mine",
        "안개 마루터|Mistral Reach|방랑자의 만|Wanderer's Cove",
        "안개 마루터|Mistral Reach|돌풍 고원|Gale Plateau",
        "안개 마루터|Mistral Reach|잊혀진 해안|The Forgotten Coast",
        "바람골 숲|Windgap Wood|던마로우|Dunmarrow",
        "바람골 숲|Windgap Wood|던마로우 수도원|Dunmarrow Abbey",
        "바람골 숲|Windgap Wood|던마로우 과수원|Dunmarrow Orchard",
        "바람골 숲|Windgap Wood|던마로우 포도밭|Dunmarrow Vineyards",
        "바람골 숲|Windgap Wood|던마로우 연못|Dunmarrow Pond",
        "바람골 숲|Windgap Wood|얼룩 굴|Brindle Hollow",
        "바람골 숲|Windgap Wood|골수 굴|Marrow Hollow",
        "바람골 숲|Windgap Wood|수지 굴|Tallow Hollow",
        "바람골 숲|Windgap Wood|버들 굴|Wicker Hollow",
        "바람골 숲|Windgap Wood|호박 관문|Amber Gate",
        "바람골 숲|Windgap Wood|달그림자 폐허|Moonshade Ruins",
        "바람곶 숲|Windcape Wood|소라 해변|Conch Strand",
        "케즈라|Kezra|케즈라 시장|Kezra Bazaar",
    ])

    private static let official = tsv("kind|korean|english", [
        "zone|안개 마루터|Mistral Reach",
        // A zone the places table has no row for, one jamo from the one above.
        "zone|안개 마루턱|Mistral Beach",
        "zone|바람골 숲|Windgap Wood",
        "zone|바람곶 숲|Windcape Wood",
        "zone|케즈라|Kezra",
        "instance|붉은십자군 수도원|Scarlet Monastery",
        "class|마법사|Mage",
        // A one-word spell: a loose name, as often an ordinary word.
        "spell|파멸|Ruin",
    ])

    private static let abbreviations = tsv("abbr|also|english|korean|note", [
        "SM||Scarlet Monastery|붉은십자군 수도원|dungeon with four wings",
        "cath|SM cath, cathedral|Scarlet Monastery - Cathedral|붉은십자군 수도원 - 대성당|fourth wing",
        "LF1M|LF2M|looking for N more|N명 구함|a group recruiting",
    ])

    private static let nicknames = tsv("korean|english|aliases", [
        "갈매기 부두|Gullwing Wharf|Gullwing",
    ])

    private func makeStore(places: Bool = true, dictionary: Bool = true) throws -> GlossaryStore {
        if dictionary {
            try writeData("official_names.classic.tsv", Self.official)
            try writeData("abbreviations.classic.tsv", Self.abbreviations)
            try writeData("nicknames.tsv", Self.nicknames)
        }
        if places { try writeData("zone_places.classic.tsv", Self.places) }
        return GlossaryStore(paths: paths, flavor: .classic)
    }

    /// The English names of the places offered for one line of a channel.
    private func offered(_ store: GlossaryStore, _ text: String, in label: String? = ZonePlacesTests.reach) -> [String] {
        store.hints(forLines: [GlossaryLine(text: text, channelLabel: label)]).zonePlaces.flatMap { $0.places.map(\.english) }
    }

    private func chat(_ body: String, label: String? = ZonePlacesTests.reach, channel: ChatChannel = .publicChannel) -> ChatMessage {
        ChatMessage(channel: channel, channelLabel: label, sender: "Dornhal", body: body, rawText: body, color: .white,
                    firstSeen: Date(timeIntervalSince1970: 0))
    }

    // MARK: The file

    func testZonePlaceRowsAndOtherZoneNames() {
        let rows = GlossaryParser.parseZonePlaces(Self.tsv("zone_korean|zone_english|korean|english", [
            "안개언덕|Mistral Reach||",
            "안개 마루터|Mistral Reach|갈매기 부두|Gullwing Wharf",
            "안개 마루터|Mistral Reach|반쪽|",
            "안개 마루터|Mistral Reach||Half Only",
            "|No Korean Zone|이름|Name",
            "영어 없는 지역||이름|Name",
        ]))
        XCTAssertEqual(rows, [
            GlossaryZonePlace(zone: GlossaryPair(korean: "안개언덕", english: "Mistral Reach"), place: nil),
            GlossaryZonePlace(zone: GlossaryPair(korean: "안개 마루터", english: "Mistral Reach"),
                              place: GlossaryPair(korean: "갈매기 부두", english: "Gullwing Wharf")),
        ], "a row needs its zone in both languages; a place with one name only is dropped")

        // Columns are found by name, like in the other files.
        let reordered = GlossaryParser.parseZonePlaces("english\tzone_english\tkorean\tzone_korean\nGullwing Wharf\tMistral Reach\t갈매기 부두\t안개 마루터\n")
        XCTAssertEqual(reordered.first?.place?.korean, "갈매기 부두")
        XCTAssertEqual(reordered.first?.zone.korean, "안개 마루터")
    }

    func testMissingPlacesFileMeansNoPlaceHintsAndNothingElse() throws {
        let store = try makeStore(places: false)
        XCTAssertEqual(store.placeZoneCount, 0)
        XCTAssertNil(store.zone(forChannelLabel: Self.reach))
        let hints = store.hints(forLines: [GlossaryLine(text: "LF2M for the IB site quest, then Scarlet Monastery", channelLabel: Self.reach)])
        XCTAssertEqual(hints.zonePlaces, [])
        XCTAssertEqual(hints.names.map(\.english), ["Scarlet Monastery"], "the rest of the dictionary answers as before")
        XCTAssertEqual(hints.abbreviations.map(\.abbr), ["LF1M"])
        XCTAssertTrue(store.loadWarnings.contains { $0.contains("zone_places.classic.tsv") }, "\(store.loadWarnings)")
        XCTAssertNil(store.placeZone(for: chat("LF2M for the IB site quest")))

        // The other way round: the places alone still work.
        try startOver()
        let alone = try makeStore(dictionary: false)
        XCTAssertEqual(alone.entryCount, 0)
        XCTAssertEqual(offered(alone, "LF2M for the IB site quest"), ["Ironbeak Excavation Site"])
    }

    func testSeedingCopiesThePlacesFile() throws {
        let bundled = root.appendingPathComponent("bundle-data", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data(Self.places.utf8).write(to: bundled.appendingPathComponent("zone_places.classic.tsv"))
        let fresh = AppPaths(root: root.appendingPathComponent("fresh", isDirectory: true))
        XCTAssertEqual(DictionaryFiles.seed(from: bundled, to: fresh).changed, ["zone_places.classic.tsv"])
        XCTAssertEqual(GlossaryStore(paths: fresh, flavor: .classic).placeZoneCount, 4)
        // A bundle that lacks the file leaves the copy alone: it is a standard dictionary file.
        try FileManager.default.removeItem(at: bundled.appendingPathComponent("zone_places.classic.tsv"))
        XCTAssertEqual(DictionaryFiles.seed(from: bundled, to: fresh).changed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.dataDirectory.appendingPathComponent("zone_places.classic.tsv").path))
    }

    // MARK: Channel label → zone

    func testZoneChannelLabelsInBothClientLanguages() throws {
        let store = try makeStore()
        let reach = GlossaryPair(korean: "안개 마루터", english: "Mistral Reach")
        for label in ["1. 공개 - 안개 마루터", "3. 수비 - 안개 마루터", "1. General - Mistral Reach", "3. LocalDefense - Mistral Reach",
                      "12. General - mistral reach"] {
            XCTAssertEqual(store.zone(forChannelLabel: label), reach, label)
        }
        XCTAssertEqual(store.zone(forChannelLabel: "1. 공개 - 바람골 숲")?.english, "Windgap Wood")
        XCTAssertEqual(store.zone(forChannelLabel: "1. General - Kezra")?.korean, "케즈라")
        XCTAssertEqual(store.zone(forChannelLabel: "1. 공개 - 안개언덕"), reach,
                       "the name another client gives the zone leads to it, under the name of its rows")
    }

    func testLabelsAsOCRDeliversThem() throws {
        let store = try makeStore()
        // The number lost or misread, spacing around the dash gone, another dash.
        for label in ["공개 - 안개 마루터", "l. 공개 - 안개 마루터", "ll. 공개 - 안개 마루터", "I|. General - Mistral Reach", "1 공개 - 안개 마루터",
                      "1. 공개- 안개 마루터", "3. 수비 -안개마루터",
                      "1. 공개 – 안개 마루터", "General - Mistral Reach", "1.General-MistralReach"] {
            XCTAssertEqual(store.zone(forChannelLabel: label)?.english, "Mistral Reach", label)
        }
        // One misread jamo or letter in the name, or in the channel word.
        for label in ["1. 공개 - 안개 마루티", "1. 공개 - 안게 마루터", "1. General - Mistra1 Reach", "1. General - Mistral Reoch",
                      "1. 공게 - 안개 마루터", "1. Genera1 - Mistral Reach", "1. 공개 - 바람골 슾"] {
            XCTAssertNotNil(store.zone(forChannelLabel: label), label)
        }
        XCTAssertEqual(store.zone(forChannelLabel: "1. 공개 - 안개 마루티")?.english, "Mistral Reach")
    }

    /// Two zones under one name (the tables of two clients, a zone and its later remake):
    /// the label does not say which, so it names neither.
    func testANameTwoZonesShareGivesNoZone() {
        let index = GlossaryPlaceIndex(rows: GlossaryParser.parseZonePlaces(Self.tsv("zone_korean|zone_english|korean|english", [
            "쌍둥이 골짜기|Twinvale North|북쪽 다리|North Bridge",
            "쌍둥이 골짜기|Twinvale South|남쪽 다리|South Bridge",
            "외딴 골짜기|Lonevale|외딴 다리|Lone Bridge",
        ])))
        XCTAssertNil(index.zone(forChannelLabel: "1. 공개 - 쌍둥이 골짜기"))
        XCTAssertNil(index.zone(forChannelLabel: "공개 - 쌍둥이 골짜기"))
        XCTAssertNil(index.zone(forChannelLabel: "1. 공개 - 쌍둥이 골짜가"), "nor does a misread of it")
        // The names only one of them has still do.
        XCTAssertEqual(index.zone(forChannelLabel: "1. General - Twinvale North").map { index.zone($0).english }, "Twinvale North")
        XCTAssertEqual(index.zone(forChannelLabel: "1. General - Twinvale South").map { index.zone($0).english }, "Twinvale South")
        XCTAssertEqual(index.zone(forChannelLabel: "1. 공개 - 외딴 골짜기").map { index.zone($0).english }, "Lonevale")
    }

    func testChannelsWithoutAZoneGiveNone() throws {
        let store = try makeStore()
        for label in ["2. 거래 - 도시", "2. Trade - City", "4. 파티찾기", "LookingForGroup", "4. LookingForGroup", "5. 우리끼리", "길드", "파티",
                      "2. 거래 - 안개 마루터", "5. friends - Mistral Reach", "1. 공개", "1. General", "1. 공개 안개 마루터", "", " - "] {
            XCTAssertNil(store.zone(forChannelLabel: label), label)
        }
        // Only a numbered channel brings its label along at all.
        for channel in [ChatChannel.guild, .party, .whisper, .say, .yell, .raid] {
            let line = GlossaryLine(text: "LF2M for the IB site quest", of: chat("LF2M for the IB site quest", channel: channel))
            XCTAssertNil(line.channelLabel, "\(channel)")
            XCTAssertEqual(store.hints(forLines: [line]).zonePlaces, [], "\(channel)")
        }
        XCTAssertEqual(GlossaryLine(text: "x", of: chat("x")).channelLabel, Self.reach)
    }

    func testAnUnclearZoneNameIsNeverGuessed() throws {
        let store = try makeStore()
        // One jamo from two zones at once.
        XCTAssertEqual(store.zone(forChannelLabel: "1. 공개 - 바람골 숲")?.english, "Windgap Wood")
        XCTAssertEqual(store.zone(forChannelLabel: "1. 공개 - 바람곶 숲")?.english, "Windcape Wood")
        XCTAssertNil(store.zone(forChannelLabel: "1. 공개 - 바람곡 숲"))
        XCTAssertNil(store.zone(forChannelLabel: "1. General - Windgape Wood"), "one letter from Windgap and from Windcape")
        // The name of a zone that has no places here is that zone, not its neighbour in spelling.
        XCTAssertNil(store.zone(forChannelLabel: "1. 공개 - 안개 마루턱"))
        XCTAssertNil(store.zone(forChannelLabel: "1. General - Mistral Beach"))
        // As close to that zone as to the one with places.
        XCTAssertNil(store.zone(forChannelLabel: "1. 공개 - 안개 마루턴"))
        // Two misreads, or another name altogether.
        XCTAssertNil(store.zone(forChannelLabel: "1. 공개 - 안게 마루티"))
        XCTAssertNil(store.zone(forChannelLabel: "1. General - Mistrel Reoch"))
        XCTAssertNil(store.zone(forChannelLabel: "1. 공개 - 안개 바다"))
        XCTAssertNil(store.zone(forChannelLabel: "1. General - Nowhere"))
        // A short name leaves no room for a misread.
        XCTAssertNil(store.zone(forChannelLabel: "1. General - Kezro"))
        XCTAssertEqual(GlossaryPlaceIndex.fold("스톰 Wind-7"), Array("스톰wind7".decomposedStringWithCanonicalMapping.unicodeScalars))
        XCTAssertTrue(GlossaryPlaceIndex.oneEditApart(Array("tanari".unicodeScalars), Array("tanaris".unicodeScalars)))
        XCTAssertFalse(GlossaryPlaceIndex.oneEditApart(Array("tanaris".unicodeScalars), Array("tanaris".unicodeScalars)))
        XCTAssertFalse(GlossaryPlaceIndex.oneEditApart(Array("tanaris".unicodeScalars), Array("tonarls".unicodeScalars)))
    }

    // MARK: Line → places

    func testAPlaceSharingAWordWithTheLineIsOffered() throws {
        let store = try makeStore()
        XCTAssertEqual(offered(store, "LF2M for the IB site quest"), ["Ironbeak Excavation Site"])
        XCTAssertEqual(offered(store, "LF2M FOR THE IB SITE QUEST"), ["Ironbeak Excavation Site"], "case does not matter")
        XCTAssertEqual(offered(store, "anyone at the tavern?"), ["Saltbreeze Tavern"])
        XCTAssertEqual(offered(store, "need 2 more for ironbeak"), ["Ironbeak Excavation Site", "Ironbeak's Retreat"],
                       "the name without its possessive s is a spelling of the word")
        XCTAssertEqual(offered(store, "they went past ironbeak's"), ["Ironbeak's Retreat"])
        XCTAssertEqual(offered(store, "boat leaves from the wharf, not the lighthouse"), ["Gullwing Wharf"],
                       "what the glossary takes for an everyday word (lighthouse) is no clue here either")

        let hints = store.hints(forLines: [GlossaryLine(text: "LF2M for the IB site quest", channelLabel: "3. 수비 - 안개 마루티")])
        XCTAssertEqual(hints.zonePlaces, [GlossaryZonePlaces(zone: GlossaryPair(korean: "안개 마루터", english: "Mistral Reach"),
                                                             places: [GlossaryPlaceHint(korean: "쇠부리 발굴현장", english: "Ironbeak Excavation Site",
                                                                                        written: "IB site")])])
        XCTAssertFalse(hints.isEmpty)
    }

    func testOnlyTheLinesOwnZoneCounts() throws {
        let store = try makeStore()
        XCTAssertEqual(offered(store, "anyone at the tavern?", in: Self.wood), [], "the tavern is in the other zone")
        XCTAssertEqual(offered(store, "anyone at the tavern?", in: nil), [])
        XCTAssertEqual(offered(store, "anyone at the tavern?", in: "2. 거래 - 도시"), [])
        XCTAssertEqual(store.hints(for: ["anyone at the tavern?"]).zonePlaces, [], "a bare text has no zone")
        // Two lines of one request, each from its own zone.
        let hints = store.hints(forLines: [GlossaryLine(text: "anyone at the tavern?", channelLabel: Self.reach),
                                           GlossaryLine(text: "lf1m dunmarrow abbey", channelLabel: Self.wood),
                                           GlossaryLine(text: "korvendal is camped", channelLabel: Self.reach)])
        XCTAssertEqual(hints.zonePlaces.map(\.zone.english), ["Mistral Reach", "Windgap Wood"])
        XCTAssertEqual(hints.zonePlaces.first?.places.map(\.english), ["Saltbreeze Tavern", "Korvendal Span"])
    }

    func testAWordCutShortFindsItsPlace() throws {
        let store = try makeStore()
        XCTAssertEqual(offered(store, "LF2M excav quest"), ["Ironbeak Excavation Site"])
        XCTAssertEqual(offered(store, "horde raid at korven"), ["Korvendal Span"])
        XCTAssertEqual(offered(store, "inc gullwi"), ["Gullwing Wharf", "Gullwing Lighthouse"])
        // Four letters are too few to tell.
        XCTAssertEqual(offered(store, "horde raid at korv"), [])
        XCTAssertEqual(offered(store, "inc gull"), [])
        // Nearly the whole word is no shortening (a typo, a plural the other way round).
        XCTAssertEqual(offered(store, "meet at saltbreez"), [])
        // The piece stops where the name's second word begins: a word, not a shortening.
        XCTAssertEqual(offered(store, "thorn in my side"), [])
        XCTAssertEqual(offered(store, "thornr is up"), ["Thornridge Hold"])
        // The piece is a word of another place's name.
        XCTAssertEqual(offered(store, "selling amber here"), [])
        XCTAssertEqual(offered(store, "selling amber here", in: Self.wood), ["Amber Gate"])
        XCTAssertEqual(offered(store, "mobs at ambermi"), ["Ambermill Farm"])
    }

    func testAStemOrAnOrdinaryWordIsNoNameCutShort() throws {
        let store = try makeStore()
        // What the piece leaves off is a mere ending: the piece is the word the name was made from.
        XCTAssertEqual(offered(store, "dont wander off, stay close"), [])
        XCTAssertEqual(offered(store, "murlocs by wanderer's"), ["Wanderer's Cove"])
        XCTAssertEqual(offered(store, "murlocs by the wanderer camp"), ["Wanderer's Cove"])
        XCTAssertEqual(offered(store, "murlocs by wande"), ["Wanderer's Cove"], "cut short inside the stem")
        // The price of that rule: a name cut off right before such an ending is not found either.
        XCTAssertEqual(offered(store, "inc gullw"), [])
        // An ordinary word that happens to begin a word of a name.
        XCTAssertEqual(offered(store, "WTB plate gloves and a shield"), [])
        XCTAssertEqual(offered(store, "elite up on the plateau"), ["Gale Plateau"])
        for word in ["plate", "split", "stage", "speed", "thick", "craft", "protect"] {
            XCTAssertTrue(GlossaryStopwords.isOrdinaryPiece(word), word)
        }
        for word in ["excav", "gullw", "korven", "ambermi", "steamwh"] {
            XCTAssertFalse(GlossaryStopwords.isOrdinaryPiece(word) || GlossaryStopwords.isOrdinaryPlaceWord(word), word)
        }
    }

    func testEverydayWordsBringNoPlace() throws {
        let store = try makeStore()
        for line in ["trade it for the old one and keep the green one", "park your alt in town and wait", "great, i lost my belt at sea",
                     "keep going, the black one is in the park", "lost my way to the old trade post", "WTS belt 5g, will trade for a green",
                     "anyone want to retreat to town", "nice farm spot here", "LF mage for a port", "this hold music is great",
                     "thanks all, see you at the keep tomorrow",
                     // An everyday word is not another word cut short ("black" for Blackthistle),
                     // three letters are no word to go by ("tin"), and the zone's own name is no place in it.
                     "the black one is mine", "WTB tin ore and a fishing pole", "mistral is dead today", "is reach always this empty"] {
            XCTAssertEqual(offered(store, line), [], line)
        }
        XCTAssertEqual(offered(store, "mobs up at blackthistle"), ["Blackthistle Grove"])
        // An everyday word of a name is no word to find the place by, whole or cut short.
        XCTAssertEqual(offered(store, "forgot my keys again"), [])
        XCTAssertEqual(offered(store, "i will forgo my roll"), [], "forgo-tten: the everyday word of the name is not one to cut short either")
        XCTAssertEqual(offered(store, "murlocs all along the coast"), ["The Forgotten Coast"])
        XCTAssertEqual(offered(store, "the lost fleet is by the green belt"), ["The Lost Fleet"],
                       "a name of everyday words is found by the one word that is not")
        for word in ["trade", "old", "park", "keep", "black", "green", "great", "lost", "sea", "belt", "camp", "retreat"] {
            XCTAssertTrue(GlossaryStopwords.isOrdinaryPlaceWord(word), word)
        }
        for word in ["harbor", "site", "tavern", "wharf", "excavation", "district"] {
            XCTAssertFalse(GlossaryStopwords.isOrdinaryPlaceWord(word), word)
        }
    }

    func testAWordTheDictionaryExplainsBringsNoPlace() throws {
        let store = try makeStore()
        // "cathedral" is the dungeon wing here, whatever square the zone has.
        let wing = store.hints(forLines: [GlossaryLine(text: "LF1M healer SM cathedral", channelLabel: Self.reach)])
        XCTAssertEqual(wing.abbreviations.map(\.abbr), ["LF1M", "SM", "cath"])
        XCTAssertEqual(wing.zonePlaces, [])
        XCTAssertEqual(offered(store, "LF1M healer SM cath"), [])
        // A nickname that names one place outright leaves nothing to guess about its neighbours.
        let named = store.hints(forLines: [GlossaryLine(text: "meet at gullwing", channelLabel: Self.reach)])
        XCTAssertEqual(named.names.map(\.english), ["Gullwing Wharf | Gullwing"])
        XCTAssertEqual(named.zonePlaces, [])

        // Without those dictionary entries the same words do find the places.
        try startOver()
        let bare = try makeStore(dictionary: false)
        XCTAssertEqual(offered(bare, "LF1M healer SM cathedral"), ["Cathedral Square"])
        XCTAssertEqual(offered(bare, "meet at gullwing"), ["Gullwing Wharf", "Gullwing Lighthouse"])
    }

    func testALooseNameExplainsNothing() throws {
        let store = try makeStore()
        // "ruins" read as several of the spell Ruin is a guess of the dictionary's own: the
        // word is still a clue to the one place of the zone that has it.
        let hints = store.hints(forLines: [GlossaryLine(text: "LF2M for MS ruins", channelLabel: Self.wood)])
        XCTAssertEqual(hints.looseNames.map(\.english), ["Ruin"])
        XCTAssertEqual(hints.zonePlaces.flatMap { $0.places.map(\.english) }, ["Moonshade Ruins"])
        XCTAssertEqual(offered(store, "LF2M for MS ruins"), [], "no such place in the other zone")
    }

    func testWordsInsideALinkBringNoPlace() throws {
        let store = try makeStore()
        XCTAssertEqual(offered(store, "LFM [Raid on the Tavern] 2 more"), [])
        XCTAssertEqual(offered(store, "LFM [[30] Raid on the Tavern (9901)]"), [])
        XCTAssertEqual(offered(store, "LFM [Raid on the Tavern"), [], "a link cut off by the edge of the window")
        XCTAssertEqual(offered(store, "LFM [Raid on the Brewery] at the tavern"), ["Saltbreeze Tavern"])
        // What the translator asks about: the body without its links, in the message's channel.
        let line = GlossaryLine(incoming: chat("WTS [Tavern Key] at the wharf"))
        XCTAssertEqual(line.text.contains("Tavern"), false)
        XCTAssertEqual(line.channelLabel, Self.reach)
        XCTAssertEqual(store.hints(forLines: [line]).zonePlaces.flatMap { $0.places.map(\.english) }, ["Gullwing Wharf"])
    }

    // MARK: Words for a kind of place, and codes

    /// Four zones with a lodge and a mine each, so "lodge" and "mine" say what kind of place
    /// it is, not which one.
    private static let kinds = tsv("zone_korean|zone_english|korean|english", [
        "북녘 고개|Norvale Pass|브린들무어 오두막|Brindlemoor Lodge",
        "북녘 고개|Norvale Pass|해로우 굴착 오두막|Harrow Dig Lodge",
        "북녘 고개|Norvale Pass|구리맥 광산|Coppervein Mine",
        "남녘 들판|Sudmere Fields|유목날개 오두막|Driftwing Lodge",
        "남녘 들판|Sudmere Fields|주석맥 광산|Tinvein Mine",
        "동녘 늪|Estwick Fen|이끼등 오두막|Mossback Lodge",
        "동녘 늪|Estwick Fen|쇠맥 광산|Ironvein Mine",
        "서녘 숲|Westholt Wood|순록 오두막|Caribou Lodge",
        "서녘 숲|Westholt Wood|은맥 광산|Silvervein Mine",
        // The kind of place may stand in front: "Shrine of ...".
        "북녘 고개|Norvale Pass|아엘린의 제단|Shrine of Aelin",
        "남녘 들판|Sudmere Fields|보렌의 제단|Shrine of Boren",
        "동녘 늪|Estwick Fen|카이라의 제단|Shrine of Caira",
        "서녘 숲|Westholt Wood|도란의 제단|Shrine of Doran",
    ])

    private func found(_ index: GlossaryPlaceIndex, _ text: String, in label: String = "1. General - Norvale Pass") throws -> [String] {
        let zone = try XCTUnwrap(index.zone(forChannelLabel: label), label)
        return index.places(inZone: zone, units: GlossaryUnits(text)).map { "\($0.written) = \($0.pair.english)" }
    }

    func testAWordForAKindOfPlaceNeedsCompany() throws {
        let rows = GlossaryParser.parseZonePlaces(Self.kinds)
        let index = GlossaryPlaceIndex(rows: rows)
        XCTAssertTrue(index.isKindWord("lodge") && index.isKindWord("mine"))
        XCTAssertFalse(index.isKindWord("brindlemoor") || index.isKindWord("harrow") || index.isKindWord("pass"))
        XCTAssertTrue(index.isKindWord("shrine"), "the word in front of \"of\" says what kind of place it is")
        XCTAssertFalse(index.isKindWord("aelin") || index.isKindWord("doran"))
        XCTAssertEqual(try found(index, "anyone at the shrine"), [])
        XCTAssertEqual(try found(index, "anyone at aelin"), ["aelin = Shrine of Aelin"])
        XCTAssertEqual(try found(index, "anyone at the shrine of aelin"), ["shrine of aelin = Shrine of Aelin"])
        // By itself it finds nothing, however few such places the zone has.
        for line in ["meet at the lodge", "which lodge has the vendor", "LODGE", "nice lodge btw", "our lodge is full"] {
            XCTAssertEqual(try found(index, line), [], line)
        }
        XCTAssertEqual(try found(index, "meet at the lodge", in: "1. General - Westholt Wood"), [], "the only lodge there")
        // With a word that is the place's own it is part of what was found.
        XCTAssertEqual(try found(index, "meet at brindlemoor"), ["brindlemoor = Brindlemoor Lodge"])
        XCTAssertEqual(try found(index, "meet at Brindlemoor Lodge now"), ["Brindlemoor Lodge = Brindlemoor Lodge"])
        XCTAssertEqual(try found(index, "meet at brind lodge"), ["brind lodge = Brindlemoor Lodge"])
        XCTAssertEqual(try found(index, "lodge is camped, go brindlemoor"), ["brindlemoor = Brindlemoor Lodge"],
                       "the place's own word is where it is spoken of")

        // With one zone fewer the word is as good as any other.
        let fewer = GlossaryPlaceIndex(rows: rows.filter { $0.zone.english != "Westholt Wood" })
        XCTAssertFalse(fewer.isKindWord("lodge"))
        XCTAssertEqual(try found(fewer, "meet at the lodge"), ["lodge = Brindlemoor Lodge", "lodge = Harrow Dig Lodge"])
        XCTAssertEqual(GlossaryPlaceIndex.kindZoneCount, 4)
    }

    func testACodeInFrontOfAWordShortensTheRestOfTheName() throws {
        let index = GlossaryPlaceIndex(rows: GlossaryParser.parseZonePlaces(Self.kinds))
        XCTAssertEqual(try found(index, "LF2M BM lodge, healer pls"), ["BM lodge = Brindlemoor Lodge"])
        XCTAssertEqual(try found(index, "lf2m BM Lodge"), ["BM Lodge = Brindlemoor Lodge"], "written as the line wrote it")
        XCTAssertEqual(try found(index, "LF2M HD lodge"), ["HD lodge = Harrow Dig Lodge"], "the lodge the code can be read from")
        XCTAssertEqual(try found(index, "LF2M brin lodge"), ["brin lodge = Brindlemoor Lodge"], "four letters of the name are a code too")
        XCTAssertEqual(try found(index, "LF2M XY lodge"), [], "no lodge of the zone reads like that")
        XCTAssertEqual(try found(index, "LF2M BM lodge", in: "1. General - Sudmere Fields"), [], "nor does the one of another zone")
        XCTAssertEqual(try found(index, "LF2M BM, lodge side"), [], "a comma between them: not one expression")
        XCTAssertEqual(try found(index, "LF2M lodge BM"), [], "the code stands in front")
        XCTAssertEqual(try found(index, "LF2M BRIND lodge"), ["BRIND lodge = Brindlemoor Lodge"], "five letters are the name cut short")
        XCTAssertEqual(try found(index, "LF2M bmoor lodge"), [], "and no code: b-m-o-o-r is neither the beginning of the name nor short")
        XCTAssertEqual(try found(index, "LF2M lod lodge"), [], "a code is read off the rest of the name, not off the word it stands at")
        // A word too ordinary to be looked at alone will do behind a code.
        XCTAssertEqual(try found(index, "that loot is mine"), [])
        XCTAssertEqual(try found(index, "the mine is empty, my mine now"), [])
        XCTAssertEqual(try found(index, "LF1M CV mine"), ["CV mine = Coppervein Mine"])
        XCTAssertEqual(try found(index, "LF1M CV mine", in: "1. General - Estwick Fen"), [])
        XCTAssertEqual(try found(index, "LF1M IV mine", in: "1. General - Estwick Fen"), ["IV mine = Ironvein Mine"])
        // An everyday word or a word of some place's name is no code.
        XCTAssertTrue(GlossaryStopwords.contains("hard"))
        XCTAssertEqual(try found(index, "hard lodge fight tonight"), [], "h-a-r-d can be read off Harrow Dig, but it is a word")
        XCTAssertEqual(try found(index, "LF2M HRD lodge"), ["HRD lodge = Harrow Dig Lodge"])
        XCTAssertEqual(try found(index, "dig lodge", in: "1. General - Sudmere Fields"), [],
                       "d-i-g can be read off Driftwing, but it is a word of another lodge's name")
        XCTAssertEqual(try found(index, "LF2M DWG lodge", in: "1. General - Sudmere Fields"), ["DWG lodge = Driftwing Lodge"])
        // Any short word can be read off some name. What tells a code from a word is that
        // it is written in capitals, in a line where capitals mean something.
        for line in ["lf2m bm lodge", "LF2M Bm lodge", "hmd lodge group?", "one hd lodge run then bed", "LF2M BM LODGE NEED HEALER", "HD LODGE"] {
            XCTAssertEqual(try found(index, line), [], line)
        }
        XCTAssertEqual(try found(index, "cv mine is better", in: "1. General - Norvale Pass"), [])
        XCTAssertEqual(try found(index, "LF2M HARR lodge"), ["HARR lodge = Harrow Dig Lodge"])
        XCTAssertEqual(try found(index, "lf2m harr lodge"), ["harr lodge = Harrow Dig Lodge"], "the first four letters of the name, in any case")
        XCTAssertEqual(try found(index, "lf2m haro lodge"), [], "h-a-r-o is in the name, but is not how it begins")
        XCTAssertEqual(try found(index, "LF2M BRIN LODGE"), ["BRIN LODGE = Brindlemoor Lodge"], "which holds in a line of capitals too")
        // A point of the compass in front of a kind of place is where the place lies, not its name.
        let compass = GlossaryPlaceIndex(rows: GlossaryParser.parseZonePlaces(Self.kinds + Self.tsv("zone_korean|zone_english|korean|english", [
            "북녘 고개|Norvale Pass|돌망대 탑|Stonewake Tower", "남녘 들판|Sudmere Fields|새벽빛 탑|Dawnlight Tower",
            "동녘 늪|Estwick Fen|갈대 탑|Reedwatch Tower", "서녘 숲|Westholt Wood|솔방울 탑|Pinecone Tower",
            "북녘 고개|Norvale Pass|북서풍 탑|Northwind Tower",
        ])))
        XCTAssertTrue(compass.isKindWord("tower"))
        XCTAssertEqual(try found(compass, "LF2M SK tower"), ["SK tower = Stonewake Tower"])
        XCTAssertEqual(try found(compass, "LF2M SW tower"), [], "s-w can be read off Stonewake, and is south-west")
        for line in ["horde inc SE tower", "they are at the NW tower", "elite by the NE tower"] {
            XCTAssertEqual(try found(compass, line), [], line)
        }
        // The word for the kind of place said twice: the code may stand at either.
        XCTAssertEqual(try found(index, "which lodge? the BM lodge"), ["BM lodge = Brindlemoor Lodge"])
        XCTAssertEqual(try found(index, "is the lodge group full? HD lodge here"), ["HD lodge = Harrow Dig Lodge"])
        // Inside a link, or explained by the dictionary, neither the word nor the code counts.
        XCTAssertEqual(try found(index, "LFM [BM lodge]"), [])
        let units = GlossaryUnits("LF2M BM lodge")
        let zone = try XCTUnwrap(index.zone(forChannelLabel: "1. General - Norvale Pass"))
        var explained = [Bool](repeating: false, count: units.count)
        for unit in 4..<6 { explained[unit] = true }   // "BM"
        XCTAssertEqual(index.places(inZone: zone, units: units, explained: explained), [])
        XCTAssertEqual(index.places(inZone: zone, units: units, explained: [Bool](repeating: false, count: units.count)).map(\.written), ["BM lodge"])

        func reads(_ code: String, _ words: String...) -> Bool {
            GlossaryPlaceIndex.shortens(Array(code.unicodeScalars), words.map { Array($0.unicodeScalars) })
        }
        XCTAssertTrue(reads("ib", "ironbeak", "excavation"))
        XCTAssertTrue(reads("ie", "ironbeak", "excavation"))
        XCTAssertTrue(reads("ex", "ironbeak", "excavation"))
        XCTAssertTrue(reads("iex", "ironbeak", "excavation"))
        XCTAssertTrue(reads("xv", "xavier", "vale"))
        XCTAssertFalse(reads("be", "ironbeak", "excavation"), "it does not begin a word")
        XCTAssertFalse(reads("ei", "ironbeak", "excavation") && reads("eb", "ironbeak", "excavation"), "nor go back to an earlier word")
        XCTAssertFalse(reads("eb", "ironbeak", "excavation"))
        XCTAssertFalse(reads("kv", "ironbeak", "excavation"))
        XCTAssertFalse(reads("i", "ironbeak"), "one letter is no code")
        XCTAssertFalse(reads("ib"))
    }

    func testWhatWasFoundIsGivenAsTheLineWroteIt() throws {
        let store = try makeStore()
        func written(_ text: String, in label: String = ZonePlacesTests.reach) -> [String] {
            store.hints(forLines: [GlossaryLine(text: text, channelLabel: label)]).zonePlaces.flatMap { $0.places.map(\.written) }
        }
        XCTAssertEqual(written("LF2M for the IB SITE quest"), ["IB SITE"])
        XCTAssertEqual(written("LF2M for the IB Site quest"), ["IB Site"])
        // (The zone of this fixture has one site, so the word alone finds the place.)
        XCTAssertEqual(written("LF2M FOR THE IB SITE QUEST"), ["SITE"], "in a line of capitals a short word in capitals is no code")
        XCTAssertEqual(written("LF2M for the Ib Site quest"), ["Site"])
        XCTAssertEqual(written("LF2M excav quest"), ["excav"])
        XCTAssertEqual(written("they went past Ironbeak's"), ["Ironbeak's"])
        XCTAssertEqual(written("need 2 more for ironbeak"), ["ironbeak", "ironbeak"])
        XCTAssertEqual(written("mobs at ironbeak excavation site, hurry"), ["ironbeak excavation site", "ironbeak"])
        // Words of the name next to the found one belong to it, everyday as they are; a "the" at the edge does not.
        XCTAssertEqual(written("the lost fleet is by the green belt"), ["lost fleet"])
        XCTAssertEqual(written("murlocs at The Forgotten Coast"), ["Forgotten Coast"])
        XCTAssertEqual(written("fleet, lost again"), ["fleet"])

        // In a request the same place found by the same words is one hint; by other words, another.
        let hints = store.hints(forLines: ["LF2M for the IB site quest", "anyone at IB SITE?", "is ironbeak excavation up", "IB site again"]
            .map { GlossaryLine(text: $0, channelLabel: Self.reach) })
        XCTAssertEqual(hints.zonePlaces.first?.places.map { "\($0.written) = \($0.english)" },
                       ["IB site = Ironbeak Excavation Site", "ironbeak excavation = Ironbeak Excavation Site", "ironbeak = Ironbeak's Retreat"])
    }

    func testAWordSharedByManyPlacesPointsAtNone() throws {
        let store = try makeStore()
        XCTAssertEqual(offered(store, "meet in the hollow", in: Self.wood), [], "four hollows")
        XCTAssertEqual(offered(store, "lf group dunmarrow", in: Self.wood), ["Dunmarrow"], "five places share the word; one is named by it alone")
        XCTAssertEqual(offered(store, "lf group dunmarrow abbey", in: Self.wood), ["Dunmarrow Abbey", "Dunmarrow"])
        XCTAssertEqual(offered(store, "meet at brindle hollow", in: Self.wood), ["Brindle Hollow"])
        XCTAssertEqual(offered(store, "at the pond", in: Self.wood), ["Dunmarrow Pond"])
    }

    func testPlacesPerLineAndPerRequestAreCapped() throws {
        let store = try makeStore()
        let many = "ironbeak, saltbreeze, korvendal, thornridge and ambermill are all taken"
        XCTAssertEqual(GlossaryPlaceIndex.placesPerLine, 3)
        XCTAssertEqual(offered(store, many), ["Saltbreeze Tavern", "Korvendal Span", "Thornridge Hold"],
                       "three, in the order of the line: those a word of their own found before the two that share one")
        XCTAssertEqual(offered(store, "ironbeak then ambermill"), ["Ambermill Farm", "Ironbeak Excavation Site", "Ironbeak's Retreat"])

        let lines = ["ironbeak and saltbreeze", "korvendal and thornridge", "ambermill, fleet, district", "wharf", "excav and the tavern"]
            .map { GlossaryLine(text: $0, channelLabel: Self.reach) }
        XCTAssertEqual(lines.map { store.hints(forLines: [$0]).zonePlaces.first?.places.count ?? 0 }, [3, 2, 3, 1, 2])
        let hints = store.hints(forLines: lines)
        XCTAssertEqual(hints.zonePlaces.count, 1)
        XCTAssertEqual(hints.zonePlaces.first?.places.count, 8, "a request carries a handful, however many lines ask")
        XCTAssertEqual(Set(hints.zonePlaces.first?.places.map(\.english) ?? []).count, 8, "and none twice")
        XCTAssertFalse(hints.zonePlaces.first?.places.contains { $0.english == "Gullwing Wharf" } ?? true, "the first lines come first")
        // The same place asked for by several lines counts once.
        let repeated = store.hints(forLines: Array(repeating: GlossaryLine(text: "at the tavern", channelLabel: Self.reach), count: 12))
        XCTAssertEqual(repeated.zonePlaces.first?.places.map(\.english), ["Saltbreeze Tavern"])

        // What goes out with the lines of one request is bounded the same way: the first lines keep theirs.
        let messages = ["ironbeak and saltbreeze", "hello there all", "korvendal and thornridge", "ambermill, fleet, district", "wharf", "excav and the tavern"]
            .map { chat($0) }
        let sent = LLMTranslator.incomingPlaces(for: messages, among: LLMTranslator.incomingHints(for: messages, glossary: store), glossary: store)
        XCTAssertEqual(sent.map { $0?.places.count ?? 0 }, [3, 0, 2, 3, 0, 0])
        XCTAssertTrue(sent[4] == nil && sent[5] == nil, "a line the bound leaves nothing for carries nothing, not an empty list")
        // Only what can have places is asked about: lines of a zone's channel, while the bound has room.
        let spy = StubGlossary()
        spy.stubHints.zonePlaces = [GlossaryZonePlaces(zone: GlossaryPair(korean: "안개 마루터", english: "Mistral Reach"), places: (1...3).map {
            GlossaryPlaceHint(korean: "장소 \($0)", english: "Place \($0)", written: "p\($0)")
        })]
        let asked = [chat("one"), chat("guild talk", label: nil, channel: .guild), chat("two"), chat("yelled", label: Self.reach, channel: .yell),
                     chat("three"), chat("four")]
        XCTAssertEqual(LLMTranslator.incomingPlaces(for: asked, among: spy.stubHints, glossary: spy).map { $0?.places.count ?? 0 }, [3, 0, 3, 0, 2, 0])
        XCTAssertEqual(spy.askedFor, [["one"], ["two"], ["three"]])
        XCTAssertEqual(sent[3]?.places.map(\.written), ["ambermill", "fleet", "district"])
        XCTAssertEqual(LLMTranslator.placesPerRequest, 8)
        let alone = LLMTranslator.incomingPlaces(for: [messages[5]], among: LLMTranslator.incomingHints(for: [messages[5]], glossary: store), glossary: store)
        XCTAssertEqual(alone.map { $0?.places.map(\.written) }, [["tavern", "excav"]], "a line asked about alone gets what the request found")
    }

    // MARK: To the model

    private func translator(_ glossary: GlossaryProviding) -> ClaudeTranslator {
        var tuning = ClaudeTranslator.Tuning()
        tuning.sleep = { _ in }
        return ClaudeTranslator(apiKey: "sk-ant-test", glossary: glossary, usage: nil, session: StubURLProtocol.session(), tuning: tuning)
    }

    private func reply(_ text: String) -> String {
        let answer = #"{"translations": [{"n": 1, "text": "\#(text)"}], "note": ""}"#
        let object: [String: Any] = ["id": "msg_test", "type": "message", "role": "assistant", "model": "claude-haiku-5-5",
                                     "content": [["type": "text", "text": answer]], "stop_reason": "end_turn",
                                     "usage": ["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 0,
                                               "cache_creation_input_tokens": 0]]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func sentPayload(_ index: Int) throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.requests[index].body) as? [String: Any])
        let content = try XCTUnwrap((root["messages"] as? [[String: Any]])?.first?["content"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
    }

    private func sentLines(_ index: Int) throws -> [[String: Any]] {
        try XCTUnwrap(try sentPayload(index)["lines"] as? [[String: Any]])
    }

    func testRequestTiesPlacesToTheirZoneInBothLanguages() async throws {
        let store = try makeStore()
        StubURLProtocol.install { _, _ in .init(json: self.reply("쇠부리 발굴현장 퀘스트 2명 구함")) }
        let context = TranslationRequestContext(reader: .korean, flavor: .classic, model: .haiku)
        let line = chat("LF2M for the IB site quest", label: "1. 공개 - 안개 마루터")
        _ = try await translator(store).translateIncoming([line], context: context)
        // The careful retranslation gets the same places.
        _ = try await translator(store).retranslate(line, previous: nil, context: context)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        for request in 0..<2 {
            let lines = try sentLines(request)
            XCTAssertEqual(lines.count, 1)
            let places = try XCTUnwrap(lines[0]["zone_places"] as? [String: Any], "request \(request)")
            XCTAssertEqual(places["zone"] as? [String: String], ["ko": "안개 마루터", "en": "Mistral Reach"])
            XCTAssertEqual(places["places"] as? [[String: String]],
                           [["for": "IB site", "ko": "쇠부리 발굴현장", "en": "Ironbeak Excavation Site"]])
            XCTAssertNil((try sentPayload(request)["glossary"] as? [String: Any])?["zone_places"], "with the line, not in the glossary")
        }
        // The key is written out where it stands: behind the text of its line.
        let hints = LLMTranslator.incomingHints(for: [line], glossary: store)
        let user = TranslationPrompt.userMessage(task: .incoming, reader: .korean, flavor: .classic, hints: hints, recent: [],
                                                 lines: [TranslationPrompt.line(1, from: line, places: hints.zonePlaces.first)])
        XCTAssertTrue(user.contains(#""channel":"public channel (1. 공개 - 안개 마루터)","sender":"Dornhal","text":"LF2M for the IB site quest","zone_places":{"zone":{"ko":"안개 마루터","en":"Mistral Reach"},"places":[{"for":"IB site","ko":"쇠부리 발굴현장","en":"Ironbeak Excavation Site"}]}}"#), user)

        // Lines of several kinds asked for together: those that carry places go in a request
        // of their own, behind the others, each with its own places and only its own. A line
        // that found no place, one of another zone, one that is not from a zone's channel and
        // a typed emote carry none, also when they have the very words another line's place
        // was found by, and they do not travel with a line that has places.
        StubURLProtocol.install { _, _ in .init(json: self.reply("ㅎㅇ")) }
        let batch = [chat("hello everyone here"), chat("LF2M for the IB site quest"), chat("anyone at the tavern?"),
                     chat("LF2M for the IB site quest", label: Self.wood), chat("LF2M for the IB site quest", label: nil, channel: .guild),
                     chat("/me waves at the tavern")]
        _ = try await translator(store).translateIncoming(batch, context: context)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        func placesSent(_ request: Int) throws -> [[String]?] {
            try sentLines(request).map { line in
                ((line["zone_places"] as? [String: Any])?["places"] as? [[String: String]])?.map { $0["for"] ?? "" }
            }
        }
        XCTAssertEqual(try sentLines(0).map { $0["text"] as? String },
                       ["hello everyone here", "LF2M for the IB site quest", "LF2M for the IB site quest", "waves at the tavern"])
        XCTAssertEqual(try placesSent(0), [nil, nil, nil, nil])
        XCTAssertEqual(try sentLines(1).map { $0["text"] as? String }, ["LF2M for the IB site quest", "anyone at the tavern?"])
        XCTAssertEqual(try placesSent(1), [["IB site"], ["tavern"]])
        XCTAssertEqual(LLMTranslator.incomingPlaces(for: batch, among: LLMTranslator.incomingHints(for: batch, glossary: store), glossary: store)
            .map { $0?.zone.english }, [nil, "Mistral Reach", "Mistral Reach", nil, nil, nil])

        // No place anywhere: no such key, and nothing is asked line by line.
        StubURLProtocol.install { _, _ in .init(json: self.reply("ㅎㅇ")) }
        _ = try await translator(store).translateIncoming([chat("hello everyone here"), chat("LF2M for the IB site quest", label: nil, channel: .guild)], context: context)
        XCTAssertEqual(try sentLines(0).compactMap { $0["zone_places"] }.count, 0)
        let stub = StubGlossary()
        _ = LLMTranslator.incomingPlaces(for: batch, among: stub.stubHints, glossary: stub)
        XCTAssertEqual(stub.askedFor, [])
    }

    func testRequestBoundsThePlaces() {
        func places(_ zone: Int, _ count: Int) -> GlossaryZonePlaces {
            GlossaryZonePlaces(zone: GlossaryPair(korean: "지역\(zone)", english: "Zone \(zone)"),
                               places: (0..<count).map { GlossaryPlaceHint(korean: "장소\(zone)-\($0)", english: "Place \(zone)-\($0)", written: "p\($0)") })
        }
        var lines = (1...5).map { TranslationPrompt.Line(number: $0, channel: "public channel", sender: "Dornhal", text: "line \($0)", zonePlaces: places($0, 3)) }
        lines.insert(TranslationPrompt.Line(number: 9, channel: "guild", sender: "Dornhal", text: "no places"), at: 1)
        var counts: [Int] = []
        for value in TranslationPrompt.lineValues(lines) {
            guard case .object(let fields) = value else { return XCTFail() }
            guard let sent = fields.first(where: { $0.key == "zone_places" })?.value else { counts.append(0); continue }
            XCTAssertEqual(fields.map(\.key).suffix(2), ["text", "zone_places"])
            guard case .object(let entry) = sent, case .array(let found)? = entry.first(where: { $0.key == "places" })?.value else { return XCTFail() }
            XCTAssertEqual(entry.map(\.key), ["zone", "places"])
            for place in found {
                guard case .object(let names) = place else { return XCTFail() }
                XCTAssertEqual(names.map(\.key), ["for", "ko", "en"], "the words of the line first, then both names")
            }
            counts.append(found.count)
        }
        XCTAssertEqual(TranslationPrompt.maxZonePlaces, 8)
        XCTAssertEqual(counts, [3, 0, 3, 2, 0, 0], "a request carries a handful: the first lines keep theirs, and no line an empty list")

        // The glossary of the request holds the four lists it always did.
        var hints = GlossaryHints()
        hints.zonePlaces = [places(1, 2)]
        XCTAssertFalse(hints.isEmpty)
        XCTAssertNil(TranslationPrompt.glossaryValue(hints))
        hints.names = [GlossaryPair(korean: "혈투의 전장", english: "Dire Maul")]
        guard case .object(let lists)? = TranslationPrompt.glossaryValue(hints) else { return XCTFail() }
        XCTAssertEqual(lists.map(\.key), ["names"])
        XCTAssertNil(TranslationPrompt.glossaryValue(GlossaryHints()))
    }

    func testPromptDescribesThePlacesAndForbidsInventingOne() throws {
        let prompt = TranslationPrompt.system
        XCTAssertTrue(prompt.contains("\"glossary\" can contain four lists"))
        // The frozen prompt says nothing of places: the requests without them (nearly all)
        // are told what they were told before places existed, but for one sentence.
        XCTAssertFalse(prompt.contains("zone_places"))
        XCTAssertEqual(LLMTranslator.systemPromptByteCount, prompt.utf8.count)

        // What a request with places is told in addition.
        let note = TranslationPrompt.zonePlacesNote
        XCTAssertTrue(note.hasPrefix("# Zone places\n\nIn this request a line can carry \"zone_places\":"), note)
        // What it is, how much it is worth, when to use it, in which language, and what to do with the rest.
        XCTAssertTrue(note.contains("it was said in a zone's own channel (its \"channel\" names the zone)"), note)
        XCTAssertTrue(note.contains("places of that zone - \"zone\" and its \"places\" -"), note)
        XCTAssertTrue(note.contains("whose name shares a word with the line"), note)
        XCTAssertTrue(note.contains("Each place has \"ko\", \"en\" and \"for\": the words of the line it was found by"), note)
        XCTAssertTrue(note.contains("weak evidence, and it is about that one line only"), note)
        XCTAssertTrue(note.contains("when the line speaks of a place and no glossary entry explains those words"), note)
        XCTAssertTrue(note.contains("official name in the reader's language"), note)
        XCTAssertTrue(note.contains("the name alone, nothing added to it and the words it stands for not repeated"), note)
        XCTAssertTrue(note.contains("An entry that does not fit the line is ignored."), note)
        XCTAssertLessThan(note.utf8.count, 900, "kept short")
        XCTAssertEqual(LLMTranslator.zonePlacesNoteByteCount, note.utf8.count)

        // An abbreviation of a place that nothing resolves stays as typed.
        XCTAssertTrue(prompt.contains("An abbreviation or short code of a place that neither the glossary nor sure game knowledge resolves likewise stays exactly as typed inside the translated sentence; it is never replaced by a place of another zone or expansion."))
        XCTAssertTrue(prompt.contains("do NOT invent an official-sounding name"), "the rule it extends is still there")
        XCTAssertFalse(prompt.contains("KV Ruins"), "no example that leaves an ordinary word in English: the next rule says to translate those")
    }

    /// The system prompt of request `index` as it was sent: its pieces, and which of them
    /// carry the cache breakpoint.
    private func sentSystem(_ index: Int) throws -> [(text: String, cached: Bool)] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.requests[index].body) as? [String: Any])
        return try XCTUnwrap(root["system"] as? [[String: Any]]).map { (($0["text"] as? String) ?? "", $0["cache_control"] != nil) }
    }

    func testLinesWithPlacesTravelApartWithTheirOwnNote() async throws {
        let store = try makeStore()
        let context = TranslationRequestContext(reader: .korean, flavor: .classic, model: .haiku)
        let plain = [chat("the server is down again, cant log in"), chat("hello everyone here"),
                     chat("LF2M for the IB site quest", label: Self.wood)]
        let placed = [chat("LF2M for the IB site quest"), chat("anyone at the tavern?")]
        let batch = [plain[0], placed[0], plain[1], placed[1], plain[2]]
        XCTAssertEqual(LLMTranslator.incomingRequests(for: batch, glossary: store).map { $0.map(\.id) }, [plain.map(\.id), placed.map(\.id)])
        XCTAssertEqual(LLMTranslator.incomingRequests(for: plain, glossary: store).count, 1)
        XCTAssertEqual(LLMTranslator.incomingRequests(for: placed, glossary: store).count, 1)
        XCTAssertEqual(LLMTranslator.incomingRequests(for: [], glossary: store).count, 0)

        // Each line gets the answer of its own request, whatever number it had there.
        StubURLProtocol.install { _, body in
            let text = String(decoding: body, as: UTF8.self)
            let answers = text.contains("zone_places")
                ? [(1, "쇠부리 발굴현장 퀘스트 2명 구함"), (2, "소금바람 선술집에 누구 있어요?")]
                : [(1, "서버 또 터졌네"), (2, "다들 안녕"), (3, "IB site 퀘스트 2명 구함")]
            let list = answers.map { #"{"n": \#($0.0), "text": "\#($0.1)"}"# }.joined(separator: ", ")
            let object: [String: Any] = ["type": "message", "role": "assistant", "stop_reason": "end_turn",
                                         "content": [["type": "text", "text": #"{"translations": [\#(list)], "note": ""}"#]],
                                         "usage": ["input_tokens": 10, "output_tokens": 5]]
            return .init(json: String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!)
        }
        let out = try await translator(store).translateIncoming(batch, context: context)
        XCTAssertEqual(batch.map { out[$0.id]?.text }, ["서버 또 터졌네", "쇠부리 발굴현장 퀘스트 2명 구함", "다들 안녕", "소금바람 선술집에 누구 있어요?", "IB site 퀘스트 2명 구함"])
        XCTAssertEqual(StubURLProtocol.requests.count, 2)

        // The request without places: the frozen prompt and nothing else, no word of places anywhere.
        let first = try sentSystem(0)
        XCTAssertEqual(first.map(\.text), [TranslationPrompt.system])
        XCTAssertEqual(first.map(\.cached), [true])
        XCTAssertFalse(String(decoding: StubURLProtocol.requests[0].body, as: UTF8.self).contains("zone_places"))
        XCTAssertEqual(try sentLines(0).map { $0["text"] as? String }, plain.map(\.body))
        // The request with places: the same frozen prompt as the cached piece, the note behind it.
        let second = try sentSystem(1)
        XCTAssertEqual(second.map(\.text), [TranslationPrompt.system, TranslationPrompt.zonePlacesNote])
        XCTAssertEqual(second.map(\.cached), [true, false], "the breakpoint stays behind the frozen prompt")
        XCTAssertEqual(try sentLines(1).map { $0["text"] as? String }, placed.map(\.body))
        XCTAssertEqual(try sentLines(1).filter { $0["zone_places"] != nil }.count, 2, "every line of it has places of its own")

        // A careful retranslation of a line with places gets the note too; of another line, not.
        _ = try await translator(store).retranslate(placed[0], previous: nil, context: context)
        _ = try await translator(store).retranslate(plain[0], previous: nil, context: context)
        XCTAssertEqual(try sentSystem(2).count, 2)
        XCTAssertEqual(try sentSystem(3).count, 1)

        // One of the two requests failing does not lose what the other translated.
        StubURLProtocol.install { _, body in
            String(decoding: body, as: UTF8.self).contains("zone_places") ? .init(status: 400, json: "{}") : .init(json: self.reply("다들 안녕"))
        }
        let half = try await translator(store).translateIncoming([plain[1], placed[0]], context: context)
        XCTAssertEqual(half[plain[1].id]?.text, "다들 안녕")
        XCTAssertNil(half[placed[0].id])
        // The other way round: the request without places fails, and the one with places is
        // still made and answered.
        StubURLProtocol.install { _, body in
            String(decoding: body, as: UTF8.self).contains("zone_places") ? .init(json: self.reply("쇠부리 발굴현장 퀘스트 2명 구함")) : .init(status: 400, json: "{}")
        }
        let otherHalf = try await translator(store).translateIncoming([plain[1], placed[0]], context: context)
        XCTAssertEqual(otherHalf[placed[0].id]?.text, "쇠부리 발굴현장 퀘스트 2명 구함")
        XCTAssertNil(otherHalf[plain[1].id])
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        // Both failing is a failure.
        StubURLProtocol.install { _, _ in .init(status: 400, json: "{}") }
        do {
            _ = try await translator(store).translateIncoming([plain[1], placed[0]], context: context)
            XCTFail("expected an error")
        } catch {}
    }

    /// Whoever wants to know how each request ended hands them over one at a time
    /// (`Translating.incomingRequests`, as the app's queue does): each group is then one
    /// request, and what went wrong with it is thrown instead of leaving its lines without
    /// an answer.
    func testEachRequestHandedOverAloneFailsAsItself() async throws {
        let store = try makeStore()
        let context = TranslationRequestContext(reader: .korean, flavor: .classic, model: .haiku)
        let plain = [chat("the server is down again, cant log in"), chat("hello everyone here")]
        let placed = [chat("LF2M for the IB site quest"), chat("anyone at the tavern?")]
        let batch = [plain[0], placed[0], plain[1], placed[1]]
        // Asked the way the queue asks, which knows the translator only as a `Translating`.
        let asked: Translating = translator(store)
        let requests = asked.incomingRequests(for: batch)
        XCTAssertEqual(requests.map { $0.map(\.id) }, [plain.map(\.id), placed.map(\.id)])
        guard requests.count == 2 else { return }
        XCTAssertEqual(requests.map { $0.map(\.id) }, LLMTranslator.incomingRequests(for: batch, glossary: store).map { $0.map(\.id) })
        for request in requests {
            XCTAssertEqual(translator(store).incomingRequests(for: request).map { $0.map(\.id) }, [request.map(\.id)], "asked about again, a request is one request")
        }
        XCTAssertEqual(translator(store).incomingRequests(for: []).count, 0)

        // A rate limit on the request with places, the other one answered.
        StubURLProtocol.install { _, body in
            let text = String(decoding: body, as: UTF8.self)
            guard !text.contains("zone_places") else { return .init(status: 429, json: #"{"type": "error", "error": {"type": "rate_limit_error", "message": "slow down"}}"#) }
            let object: [String: Any] = ["type": "message", "role": "assistant", "stop_reason": "end_turn",
                                         "content": [["type": "text", "text": #"{"translations": [{"n": 1, "text": "서버 또 터졌네"}, {"n": 2, "text": "다들 안녕"}], "note": ""}"#]],
                                         "usage": ["input_tokens": 10, "output_tokens": 5]]
            return .init(json: String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!)
        }
        let first = try await translator(store).translateIncoming(requests[0], context: context)
        XCTAssertEqual(plain.map { first[$0.id]?.text }, ["서버 또 터졌네", "다들 안녕"])
        do {
            _ = try await translator(store).translateIncoming(requests[1], context: context)
            XCTFail("expected the rate limit")
        } catch let error as TranslationError {
            XCTAssertEqual(error, .rateLimited, "the failure of that request, as what it was")
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "one request each")

        // A translator that sends whatever it is given in one request says so.
        let fallback = MyMemoryTranslator(session: StubURLProtocol.session())
        XCTAssertEqual(fallback.incomingRequests(for: batch).map { $0.map(\.id) }, [batch.map(\.id)])
        XCTAssertEqual(fallback.incomingRequests(for: []).count, 0)
    }

    func testRequestsWithPlacesStayWithinTheBound() throws {
        let store = try makeStore()
        // Six lines with two or three places each: more than one request carries.
        let lines = ["ironbeak and saltbreeze", "korvendal and thornridge", "ambermill, fleet, district", "hello there all", "wharf",
                     "excav and the tavern", "blackthistle and the plateau"].map { chat($0) }
        let requests = LLMTranslator.incomingRequests(for: lines, glossary: store)
        XCTAssertEqual(requests.map { $0.map(\.body) }, [
            ["hello there all"],
            ["ironbeak and saltbreeze", "korvendal and thornridge", "ambermill, fleet, district"],
            ["wharf", "excav and the tavern", "blackthistle and the plateau"],
        ])
        for request in requests.dropFirst() {
            let places = LLMTranslator.incomingPlaces(for: request, among: LLMTranslator.incomingHints(for: request, glossary: store), glossary: store)
            XCTAssertFalse(places.contains { $0 == nil }, "no line lost its places to the bound")
            XCTAssertLessThanOrEqual(places.reduce(0) { $0 + ($1?.places.count ?? 0) }, LLMTranslator.placesPerRequest)
        }
        for request in requests {
            XCTAssertEqual(LLMTranslator.incomingRequests(for: request, glossary: store).map { $0.map(\.body) }, [request.map(\.body)],
                           "each of them, asked about again, is one request")
        }
        // Typed emotes are sent without their channel, so they take no places and none of the bound.
        let emotes = ["/me walks from ironbeak to saltbreeze", "/me then on to korvendal and thornridge", "/me and ambermill", "2 more for the IB site, healer pls"]
            .map { chat($0) }
        let sent = LLMTranslator.incomingPlaces(for: emotes, among: LLMTranslator.incomingHints(for: emotes, glossary: store), glossary: store)
        XCTAssertEqual(sent.map { $0?.places.map(\.written) }, [nil, nil, nil, ["IB site"]])
        XCTAssertEqual(LLMTranslator.incomingRequests(for: emotes, glossary: store).map(\.count), [3, 1])
    }

    func testOtherProvidersCarryTheNoteBehindTheFrozenPrompt() throws {
        func object(_ value: JSONValue) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.serialized().utf8)) as? [String: Any])
        }
        let note = TranslationPrompt.zonePlacesNote
        let openAI = try object(OpenAIBackend.requestBody(modelID: "gpt-5.6", system: TranslationPrompt.system, addendum: note, user: "{}",
                                                          careful: false, features: [.explicitCache]))
        let developer = try XCTUnwrap(((openAI["input"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        XCTAssertEqual(developer.map { $0["text"] as? String }, [TranslationPrompt.system, note])
        XCTAssertNotNil(developer[0]["prompt_cache_breakpoint"])
        XCTAssertNil(developer[1]["prompt_cache_breakpoint"])
        let plain = try object(OpenAIBackend.requestBody(modelID: "gpt-5.6", system: TranslationPrompt.system, user: "{}", careful: false, features: []))
        XCTAssertEqual((((plain["input"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])?.count, 1)

        let gemini = try object(GeminiBackend.requestBody(modelID: "gemini-4-flash", system: TranslationPrompt.system, addendum: note, user: "{}",
                                                          careful: false, features: []))
        XCTAssertEqual(gemini["system_instruction"] as? String, TranslationPrompt.system + "\n\n" + note)
        let bare = try object(GeminiBackend.requestBody(modelID: "gemini-4-flash", system: TranslationPrompt.system, user: "{}", careful: false, features: []))
        XCTAssertEqual(bare["system_instruction"] as? String, TranslationPrompt.system)
    }

    // MARK: Around the request

    func testAConformerWithoutZoneDataKeepsWorking() {
        // The protocol's default: the texts are asked about, the channel is not.
        let stub = StubGlossary()
        stub.stubHints.names = [GlossaryPair(korean: "혈투의 전장", english: "Dire Maul")]
        let hints = stub.hints(forLines: [GlossaryLine(text: "LF tank DM", channelLabel: Self.reach), GlossaryLine(text: "second line")])
        XCTAssertEqual(hints, stub.stubHints)
        XCTAssertEqual(stub.askedFor, [["LF tank DM", "second line"]])
        XCTAssertNil(stub.placeZone(for: chat("LF2M for the IB site quest")))
    }

    func testPlaceZoneTellsWhichLinesDependOnWhereTheyWereSaid() throws {
        let store = try makeStore()
        // The zone goes into the key of a remembered translation (TranslationMemo): the same
        // words name another place, or none, in the next zone's channel.
        XCTAssertEqual(store.placeZone(for: chat("anyone at the abbey or the tavern?")), "Mistral Reach")
        XCTAssertEqual(store.placeZone(for: chat("anyone at the abbey or the tavern?", label: "1. 공개 - 안개 마루티")), "Mistral Reach",
                       "however the label was read")
        XCTAssertEqual(store.placeZone(for: chat("anyone at the abbey or the tavern?", label: "1. 공개 - 바람골 숲")), "Windgap Wood")
        XCTAssertNil(store.placeZone(for: chat("anyone at the abbey or the tavern?", label: "1. General - Kezra")))
        XCTAssertNil(store.placeZone(for: chat("anyone at the abbey or the tavern?", label: "2. 거래 - 도시")))
        XCTAssertNil(store.placeZone(for: chat("anyone at the abbey or the tavern?", label: nil, channel: .yell)))
        // A line without a place of the zone reads the same everywhere.
        XCTAssertNil(store.placeZone(for: chat("LFM need 2 healers tonight")))
        XCTAssertNil(store.placeZone(for: chat("LFM [Raid on the Tavern] 2 more")))
        // A typed emote is sent without places: no zone goes with what is kept for it.
        let emote = chat("/me walks from the abbey to the tavern")
        XCTAssertNil(store.placeZone(for: emote))
        XCTAssertEqual(LLMTranslator.incomingPlaces(for: [emote], among: LLMTranslator.incomingHints(for: [emote], glossary: store), glossary: store).map { $0?.zone.english }, [nil])
    }

    func testCheckFileLinesMayCarryTheirChannelLabel() {
        let now = Date(timeIntervalSince1970: 100)
        func parse(_ line: String) -> ChatMessage? { ChatLineFile.message(from: line, now: now) }

        // The forms the files have always had.
        let plain = parse("LF2M for the IB site quest")
        XCTAssertEqual(plain?.channel, .publicChannel)
        XCTAssertEqual(plain?.channelLabel, ChatLineFile.defaultPublicLabel)
        XCTAssertNil(plain?.sender)
        XCTAssertEqual(plain?.body, "LF2M for the IB site quest")
        let guild = parse("guild\tDornhal\tanyone on?")
        XCTAssertEqual([guild?.channel.rawValue, guild?.sender, guild?.body, guild?.channelLabel], ["guild", "Dornhal", "anyone on?", nil])
        XCTAssertEqual(parse("publicChannel\tDornhal\twts stuff")?.channelLabel, ChatLineFile.defaultPublicLabel)
        XCTAssertEqual(parse("yell\t\thelp")?.sender, nil)
        XCTAssertEqual(parse("party\tDornhal\ta\tb")?.body, "a b", "tabs in the body are spaces")
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("   "))
        XCTAssertNil(parse("# a comment"))
        XCTAssertNil(parse("guild\tDornhal\t  "))
        XCTAssertEqual(parse("nochannel\tDornhal\ttext")?.channel, .publicChannel, "not a channel: the whole line is the body")
        XCTAssertEqual(parse("nochannel\tDornhal\ttext")?.body, "nochannel\tDornhal\ttext")

        // New: the label in square brackets behind the channel.
        let zoned = parse("publicChannel[1. General - Mistral Reach]\tDornhal\tLF2M for the IB site quest")
        XCTAssertEqual(zoned?.channel, .publicChannel)
        XCTAssertEqual(zoned?.channelLabel, "1. General - Mistral Reach")
        XCTAssertEqual(zoned?.sender, "Dornhal")
        XCTAssertEqual(zoned?.body, "LF2M for the IB site quest")
        XCTAssertEqual(zoned?.firstSeen, now)
        XCTAssertEqual(parse("publicChannel [ 3. 수비 - 안개 마루터 ]\t\tinc")?.channelLabel, "3. 수비 - 안개 마루터")
        XCTAssertEqual(parse("publicChannel[]\t\tinc")?.channelLabel, ChatLineFile.defaultPublicLabel)
        XCTAssertEqual(parse("guild[길드]\tDornhal\thi")?.channelLabel, "길드")
        XCTAssertEqual(parse("nochannel[1. General - Mistral Reach]\tDornhal\ttext")?.channelLabel, ChatLineFile.defaultPublicLabel)
        XCTAssertEqual(ChatLineFile.channelField("publicChannel[2. 거래 - 도시]")?.label, "2. 거래 - 도시")
        XCTAssertNil(ChatLineFile.channelField("[1. General]"))
    }

    // MARK: The shipped files (skipped while data/ is not generated yet)

    private static var dataFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data", isDirectory: true)
    }

    private func shippedStore(_ flavor: GameFlavor) throws -> GlossaryStore {
        let files = DictionaryFiles.names(for: flavor)
        guard FileManager.default.fileExists(atPath: Self.dataFolder.appendingPathComponent(files.zonePlaces).path) else {
            throw XCTSkip("data/\(files.zonePlaces) is not there")
        }
        // Read through a link; nothing is copied or modified.
        try FileManager.default.removeItem(at: paths.dataDirectory)
        try FileManager.default.createSymbolicLink(at: paths.dataDirectory, withDestinationURL: Self.dataFolder)
        return GlossaryStore(paths: paths, flavor: flavor)
    }

    func testShippedPlacesFindAZoneAndItsPlace() throws {
        for flavor in [GameFlavor.classic, .retail] {
            let store = try shippedStore(flavor)
            XCTAssertEqual(store.loadWarnings, [])
            XCTAssertGreaterThan(store.placeZoneCount, 150, "\(flavor)")
            let loch = GlossaryPair(korean: "모단 호수", english: "Loch Modan")
            for label in ["1. 공개 - 모단 호수", "3. 수비 - 모단 호수", "1. General - Loch Modan", "공개 - 모단 호수", "1. 공개 - 모단 호스",
                          "1. General - Loch Modon"] {
                XCTAssertEqual(store.zone(forChannelLabel: label), loch, "\(flavor) \(label)")
            }
            XCTAssertEqual(store.zone(forChannelLabel: "1. 공개 - 타나리스")?.english, "Tanaris")
            for label in ["2. 거래 - 도시", "4. 파티찾기", "1. 공개 - 모단 바다", "1. General - Nowhere At All"] {
                XCTAssertNil(store.zone(forChannelLabel: label), "\(flavor) \(label)")
            }
            // An abbreviation nothing explains, next to a word of one place of the zone.
            let hints = store.hints(forLines: [GlossaryLine(text: "2 more for IE site, healer pls", channelLabel: "1. 공개 - 모단 호수")])
            XCTAssertEqual(hints.zonePlaces, [GlossaryZonePlaces(zone: loch, places: [
                GlossaryPlaceHint(korean: "아이언밴드의 발굴현장", english: "Ironband's Excavation Site", written: "IE site")])], "\(flavor)")
            XCTAssertEqual(offered(store, "2 more for IE site, healer pls", in: "1. 공개 - 타나리스"), [], "\(flavor): no such place there")
            XCTAssertEqual(offered(store, "pirates at lost rigger, need 2", in: "1. General - Tanaris"), ["Lost Rigger Cove"], "\(flavor)")
            XCTAssertEqual(offered(store, "horde at steamwh", in: "1. General - Tanaris"), ["Steamwheedle Port"], "\(flavor)")
            try startOver()
        }
    }

    func testShippedPlacesStayQuietForOrdinaryChat() throws {
        // The general channels of three cities and two zones; none of these lines speaks of a place there.
        let labels = ["1. 공개 - 스톰윈드", "1. 공개 - 아이언포지", "1. General - Orgrimmar", "1. 공개 - 타나리스", "1. General - Loch Modan"]
        let quiet = [
            "trade you my old one for the green one", "park your alt at the bank and keep going", "great, lost my hearth at sea again",
            "the black one drops from the last boss", "anyone want to trade? keep the change", "LF mage for a portal, will tip",
            "WTS belt and dagger, cheap", "LF1M healer SM cath", "LFM UBRS need tank and healer", "thanks for the help everyone, see you tomorrow",
            "dont camp the quest mobs please", "any tailor or blacksmith on?", "is the server down or is it just me", "LFM [Trouble at the Docks] need 2",
            "what level do i need for the next zone", "wts [Runecloth Bag] 90s", "this path is bugged, use the other one",
        ]
        for flavor in [GameFlavor.classic, .retail] {
            let store = try shippedStore(flavor)
            for label in labels {
                XCTAssertNotNil(store.zone(forChannelLabel: label), "\(flavor) \(label)")
                for line in quiet {
                    XCTAssertEqual(offered(store, line, in: label), [], "\(flavor) \(label): \(line)")
                }
            }
            // Ordinary words that begin a longer word of some place's name, in every zone there is.
            let everyZone = Set(GlossaryParser.parseZonePlaces(try XCTUnwrap(GlossaryParser.readText(
                Self.dataFolder.appendingPathComponent(DictionaryFiles.names(for: flavor).zonePlaces)))).map(\.zone.english))
            XCTAssertGreaterThan(everyZone.count, 150)
            let pieces = "need plate dps, split the loot, wrong stage, speed run, thick skull, can you craft it, protect the healer, "
                + "extra spot, stock up, rough night, honey, actual event, crush them, broad daylight, jewel, hatch a plan"
            for zone in everyZone {
                XCTAssertEqual(offered(store, pieces, in: "1. General - \(zone)"), [], "\(flavor) \(zone)")
            }
            // The wing of the dungeon is explained by the dictionary; the city's square stays out of it.
            let wing = store.hints(forLines: [GlossaryLine(text: "LF1M healer SM cath", channelLabel: "1. 공개 - 스톰윈드")])
            if flavor == .classic { XCTAssertTrue(wing.abbreviations.contains { $0.abbr == "cath" }) }
            XCTAssertEqual(wing.zonePlaces, [], "\(flavor)")
            try startOver()
        }
    }

    /// The game tables hold a second area named like a zone on the map of a raid or a
    /// scenario, with copies of the places of the zones next door under it. A channel is
    /// named after the zone itself: the places of the namesake are not listed for it.
    func testShippedPlacesAreNotThoseOfANamesakeOnAnotherMap() throws {
        for flavor in [GameFlavor.classic, .retail] {
            let file = Self.dataFolder.appendingPathComponent(DictionaryFiles.names(for: flavor).zonePlaces)
            guard let text = GlossaryParser.readText(file) else { throw XCTSkip("data/\(file.lastPathComponent) is not there") }
            let rows = GlossaryParser.parseZonePlaces(text)
            func places(of zone: String) -> Set<String> {
                Set(rows.filter { $0.zone.english == zone }.compactMap { $0.place?.english })
            }
            for (zone, own, foreign, home) in [
                ("Duskwood", "Raven Hill", ["Fargodeep Mine", "Tower of Azora", "The Stonefield Farm", "Brackwell Pumpkin Patch"], "Elwynn Forest"),
                ("The Hinterlands", "Aerie Peak", ["Darrowshire", "Lake Mereldar", "The Undercroft"], "Eastern Plaguelands"),
                ("Feralas", "Camp Mojache", ["Gelkis Village", "Mannoroc Coven", "Valley of Bones"], "Desolace"),
                ("Ashenvale", "Astranaar", ["Talrendis Point", "Haldarr Encampment", "Shadowsong Shrine"], "Azshara"),
            ] {
                let listed = places(of: zone)
                XCTAssertTrue(listed.contains(own), "\(flavor): \(zone) keeps \(own)")
                XCTAssertEqual(listed.intersection(foreign), [], "\(flavor): \(zone)")
                XCTAssertTrue(places(of: home).isSuperset(of: foreign), "\(flavor): \(home) has \(foreign)")
            }
            if flavor == .retail {
                // The zone of the open world, not the scenario of the same name with the lower
                // ID; and a top area before a sub-area that bears its name.
                XCTAssertTrue(places(of: "Broken Shore").contains("Aalgen Point"))
                XCTAssertFalse(places(of: "Broken Shore").contains("Tomb Approach"))
                XCTAssertTrue(places(of: "Voidstorm").contains("Bastion of Might"))
            }
        }
        let store = try shippedStore(.classic)
        XCTAssertEqual(offered(store, "LF2M fargodeep", in: "1. 공개 - 그늘숲"), [])
        XCTAssertEqual(offered(store, "LF2M fargodeep", in: "1. 공개 - 엘윈 숲"), ["Fargodeep Mine"])
        XCTAssertEqual(offered(store, "any group for darrowshire", in: "1. General - The Hinterlands"), [])
        XCTAssertEqual(offered(store, "any group for darrowshire", in: "1. General - Eastern Plaguelands").first, "Darrowshire")
    }

    /// What reviewers of the shipped tables found a place for: a point of the compass, a
    /// short word and an everyday or item word in front of or in the name of some place.
    func testShippedPlacesTakeNoShortOrEverydayWordForAPlace() throws {
        let store = try shippedStore(.classic)
        for (zone, line) in [
            ("Redridge Mountains", "horde inc SE tower"), ("Redridge Mountains", "1 sec keep the adds off me"),
            ("Redridge Mountains", "one sec keep going"), ("Westfall", "rare is up at the SE farm"),
            ("Elwynn Forest", "kobolds at the SE lake drop it"), ("Elwynn Forest", "eh mine is better"),
            ("Loch Modan", "troggs at the SE mine"), ("Arathi Highlands", "horde raid at SE keep"), ("Wetlands", "meh keep going, we almost had it"),
            ("Blasted Lands", "na keep it"), ("Wetlands", "took a survey of the guild, nobody wants to raid"), ("Wetlands", "sundown already, gotta go"),
            ("Stormwind City", "dwarven rifle for sale"), ("Stormwind City", "LF dwarven priest for fear ward"), ("Dun Morogh", "WTS helm of the bear"),
            ("Duskwood", "pumpkin spice, estate sale, tranquil shot, this server is rotting"), ("Redridge Mountains", "highway to hell"),
            ("Ashenvale", "LF2M satyr horns quest"), ("Stranglethorn Vale", "WTB cape with agi"), ("The Barrens", "thorn buff pls"),
        ] {
            let label = "1. General - \(zone)"
            XCTAssertNotNil(store.zone(forChannelLabel: label), label)
            XCTAssertEqual(offered(store, line, in: label), [], "\(zone): \(line)")
        }
        // A code is still a code, where it is written like one.
        XCTAssertEqual(offered(store, "2 more for IE site, healer pls", in: "1. General - Loch Modan"), ["Ironband's Excavation Site"])
        XCTAssertEqual(offered(store, "is the site group full? IE site here", in: "1. General - Loch Modan"), ["Ironband's Excavation Site"])
        XCTAssertEqual(offered(store, "2 more for ie site, healer pls", in: "1. General - Loch Modan"), [])
        XCTAssertEqual(offered(store, "LF2M IE SITE NEED HEALER", in: "1. General - Loch Modan"), [])
        XCTAssertEqual(offered(store, "LF3M Strom keep", in: "1. General - Arathi Highlands"), ["Stromgarde Keep"])
        // The places the line names come before those that merely share a word with it.
        XCTAssertEqual(offered(store, "crocs in the marsh, mosshide and bluegill, saltspray", in: "1. General - Wetlands"),
                       ["Bluegill Marsh", "Mosshide Fen", "Saltspray Glen"])
        XCTAssertEqual(store.hints(forLines: [GlossaryLine(text: "crocs in the marsh by bluegill", channelLabel: "1. General - Wetlands")])
            .zonePlaces.first?.places.first?.written, "bluegill", "found by its own word, not by the one three places share")
    }

    func testShippedPlacesListAPlaceUnderEveryAreaAboveIt() throws {
        for flavor in [GameFlavor.classic, .retail] {
            let file = Self.dataFolder.appendingPathComponent(DictionaryFiles.names(for: flavor).zonePlaces)
            guard let text = GlossaryParser.readText(file) else { throw XCTSkip("data/\(file.lastPathComponent) is not there") }
            let rows = GlossaryParser.parseZonePlaces(text)
            func zones(of place: String) -> Set<String> {
                Set(rows.filter { $0.place?.english == place }.map(\.zone.english))
            }
            // The later clients hang the harbour town under the cape, and the cape under the vale.
            XCTAssertEqual(zones(of: "Booty Bay"), ["Stranglethorn Vale", "The Cape of Stranglethorn"], "\(flavor)")
            XCTAssertTrue(zones(of: "The Cape of Stranglethorn").contains("Stranglethorn Vale"), "\(flavor)")
            XCTAssertEqual(zones(of: "Anvilmar"), ["Dun Morogh", "Coldridge Valley"], "\(flavor)")
            // No zone is a place of itself, and no place is listed twice for a zone.
            XCTAssertFalse(rows.contains { $0.place?.english.lowercased() == $0.zone.english.lowercased() }, "\(flavor)")
            let listed = rows.compactMap { row in row.place.map { row.zone.english.lowercased() + "\t" + $0.english.lowercased() } }
            XCTAssertEqual(listed.count, Set(listed).count, "\(flavor)")
            // One Korean name per zone on the rows with places.
            var korean: [String: Set<String>] = [:]
            for row in rows where row.place != nil { korean[row.zone.english, default: []].insert(row.zone.korean) }
            XCTAssertFalse(korean.values.contains { $0.count > 1 }, "\(flavor)")
        }
        // The classic clients disagree on the Korean name of a few zones; a label may show either.
        let classic = try shippedStore(.classic)
        XCTAssertEqual(classic.zone(forChannelLabel: "1. 공개 - 어둠의 해안")?.english, "Darkshore")
        XCTAssertEqual(classic.zone(forChannelLabel: "1. 공개 - 어둠해안"), classic.zone(forChannelLabel: "1. 공개 - 어둠의 해안"))
    }

    func testShippedPlacesFollowTheNamingRulesOfTheOfficialNames() throws {
        for flavor in [GameFlavor.classic, .retail] {
            let files = DictionaryFiles.names(for: flavor)
            guard let text = GlossaryParser.readText(Self.dataFolder.appendingPathComponent(files.zonePlaces)),
                  let official = GlossaryParser.readText(Self.dataFolder.appendingPathComponent(files.officialNames)) else {
                throw XCTSkip("data/\(files.zonePlaces) is not there")
            }
            let rows = GlossaryParser.parseZonePlaces(text)
            XCTAssertGreaterThan(rows.count, 3000, "\(flavor)")
            // A category label of a client list is no zone.
            let labels: Set<String> = ["Continent", "City", "Home Interior", "Islands"]
            XCTAssertEqual(rows.filter { labels.contains($0.zone.english) }.map(\.zone.english), [], "\(flavor)")
            // Test, unused and untranslated areas are left out, as they are from the official names.
            func junk(_ pair: GlossaryPair) -> Bool {
                pair.korean == pair.english || pair.english.contains("UNUSED") || pair.english.contains("[") || pair.english.contains("TEST")
                    || pair.english.contains("(TEMP)") || pair.korean.range(of: "[A-Za-z]{4,}", options: .regularExpression) != nil
            }
            XCTAssertEqual(rows.filter { junk($0.zone) || ($0.place.map(junk) ?? false) }.map { "\($0.zone.english) / \($0.place?.english ?? "")" }, [], "\(flavor)")
            // Where the clients of a flavor name a place differently in Korean, the first listed
            // client's name stands - the same one the official names have.
            let hammerfall = rows.filter { $0.zone.english == "Arathi Highlands" && $0.place?.english == "Hammerfall" }.compactMap { $0.place?.korean }
            let named = GlossaryParser.parseOfficialNames(official).filter { $0.kind == "subzone" && $0.english == "Hammerfall" }.map(\.korean)
            XCTAssertEqual(hammerfall, flavor == .classic ? ["해머폴"] : ["망치 주둔지"], "\(flavor)")
            XCTAssertEqual(hammerfall, named, "\(flavor)")
        }
    }

    func testPlaceLookupStaysFast() throws {
        let store = try shippedStore(.classic)
        let lines = [
            GlossaryLine(text: "LFM UBRS need tank and healer, have key", channelLabel: "1. General - Tanaris"),
            GlossaryLine(text: "LF2M for the pirates at steamwheedle, then the noxious bugs", channelLabel: "1. 공개 - 타나리스"),
            GlossaryLine(text: "anyone at the gadget arena or rigger cove?", channelLabel: "1. General - Tanarls"),
            GlossaryLine(text: "thanks for the help everyone, see you tomorrow", channelLabel: "1. 공개 - 모단 호스"),
        ]
        XCTAssertFalse(store.hints(forLines: [lines[1]]).zonePlaces.isEmpty)
        XCTAssertFalse(store.hints(forLines: [lines[2]]).zonePlaces.isEmpty, "a misread label is resolved on every line")
        let rounds = 50
        let start = Date()
        for _ in 0..<rounds { for line in lines { _ = store.hints(forLines: [line]) } }
        let perLine = Date().timeIntervalSince(start) / Double(rounds * lines.count)
        XCTAssertLessThan(perLine, 0.005, "hints took \(perLine * 1000) ms per line")
        print("Zone places: hints \(String(format: "%.3f", perLine * 1000)) ms per line")
    }
}
