import XCTest
import CoreGraphics
@testable import RunespeakCore

// Which recognition model is believed for which part of a row (koKR client). The readings are
// hand-built the way the two models deliver them: the Korean model with a box per glyph, the
// Latin/Cyrillic model with one box per word. All names are invented.

/// A row as drawn on screen: every space-separated word of the true text has a slot.
private struct ScreenRow {
    let slots: [ClosedRange<CGFloat>]
    static let height: CGFloat = 40

    init(_ truth: String, x: CGFloat = 76) {
        var slots: [ClosedRange<CGFloat>] = []
        var cursor = x
        for word in truth.split(separator: " ") {
            let width = CGFloat(TextFold.columns(word)) * 17
            slots.append(cursor...(cursor + width))
            cursor += width + 9
        }
        self.slots = slots
    }

    /// A reading with as many words as the row has, word for word in the row's slots.
    /// `wordBoxes`: every glyph of a word carries the extent of the whole word (the Latin model).
    func read(_ text: String, wordBoxes: Bool = false) -> [OCRGlyph] {
        let words = text.split(separator: " ").map(String.init)
        precondition(words.count == slots.count, "\(words.count) words for \(slots.count) slots: \(text)")
        return read(words.enumerated().map { ($0.element, $0.offset...$0.offset) }, wordBoxes: wordBoxes)
    }

    /// A reading whose words cover the given runs of slots (a model may split or join words).
    func read(_ words: [(String, ClosedRange<Int>)], wordBoxes: Bool = false) -> [OCRGlyph] {
        var out: [OCRGlyph] = []
        for (text, span) in words {
            let lo = slots[span.lowerBound].lowerBound, hi = slots[span.upperBound].upperBound
            let chars = Array(text)
            let columns = CGFloat(max(1, TextFold.columns(text)))
            var cursor = lo
            for (n, c) in chars.enumerated() {
                let width = (hi - lo) * CGFloat(TextFold.columns(String(c))) / columns
                let extent = wordBoxes ? (lo, hi) : (cursor, cursor + width)
                out.append(OCRGlyph(character: c, minX: extent.0, maxX: extent.1, spaceBefore: n == 0 && !out.isEmpty))
                cursor += width
            }
        }
        return out
    }
}

private func text(_ choice: ScriptChoice.LatinChoice) -> String {
    switch choice {
    case .korean(let g): return "korean|" + ScriptChoice.text(ScriptChoice.mendSpeakerBracket(g))
    case .cyrillic(let g, _): return "cyrillic|" + ScriptChoice.text(g)
    case .latinFallback(let g, _): return "latin|" + ScriptChoice.text(g)
    case .unreadable: return "unreadable"
    }
}

private func hasForeignLetters(_ s: String) -> Bool {
    s.contains { let k = ScriptChoice.script($0); return k == .cyrillic || k == .greek }
}

final class ScriptChoiceKoreanBodyTests: XCTestCase {
    private let h = ScreenRow.height

    /// The dominant shape of the user's chat: Korean tag, Latin name, short Korean body, the
    /// name's closing bracket read as "j". The Latin model's digits and Cyrillic for the Hangul
    /// must never replace it, however sure that model is of them.
    func testShortKoreanBodiesAreFinalWhateverTheLatinModelSays() {
        let cases: [(truth: String, korean: String, latin: [(String, ClosedRange<Int>)])] = [
            ("[길드] [Brann Oakheart]: 와 재밌겠다", "[길드] [Brann Oakheartj: 와 재밌겠다",
             [("[25]", 0...0), ("[Brann", 1...1), ("Oakheart]:", 2...2), ("2", 3...3), ("9024", 4...4)]),
            ("[길드] [Mira Fenwick]: 그거 법사님", "[길드] [Mira Fenwickj: 그거 법사님",
             [("[·5][Mira", 0...1), ("Fenwick]:", 2...2), ("14", 3...3), ("|У", 4...4)]),
            ("[길드] [Mira Fenwick]: 왜 안오시는...", "[길드] [Mira Fenwickj: 왜 안오시는...",
             [("[25][Mira", 0...1), ("Fenwick]:", 2...2), ("|", 3...3), ("20N...", 4...4)]),
            ("[길드] [Odo Marsh]: 비싼템인데 ㄷㄷ", "[길드] [Odo Marshl: 비싼템인데 ㄷㄷ",
             [("[dk", 0...1), ("Marsh]:", 2...2), ("CE024|", 3...3), ("EE", 4...4)]),
            ("[길드] [Odo Marsh]: 그럴거면 저도 불러요!!", "[길드] [Odo Marshl: 그럴거면 저도 불러요!!",
             [("[][do", 0...1), ("Marsh]", 2...2), ("АНZИ4ФЕ0Ч241", 3...4), ("!!", 5...5)]),
            ("[길드] [Odo Marsh]: 우편함확인해도안들어왔네 ㅠㅠ", "[길드] [Odo Marshj: 우편함확인해도안들어왔네 ㅠㅠ",
             [("[a5]", 0...0), ("[Odo", 1...1), ("Marsh]:", 2...2), ("Nm", 3...3), ("SO|8ЖЕЧ||&", 4...4)]),
            ("[길드] [Odo Marsh]: 20렙 3개 구함", "[길드] [Odo Marshj: 20렙 3개 구함",
             [("[25]", 0...0), ("[Odo", 1...1), ("Marsh]:", 2...2), ("204", 3...3), ("37H", 4...4), ("7ЛУ", 5...5)]),
        ]
        for c in cases {
            let row = ScreenRow(c.truth)
            let korean = row.read(c.korean)
            // Sure of the row: settled without asking anyone.
            XCTAssertTrue(ScriptChoice.isSettledKorean(korean, confidence: 1), c.truth)
            XCTAssertEqual(ScriptChoice.text(ScriptChoice.mendSpeakerBracket(korean)), c.truth)
            // Asked all the same (for the name's bracket), or unsure of the row: the body stays.
            for (koreanConfidence, latinConfidence) in [(1.0, 1.0), (0.5, 1.0), (0.5, 0.3), (0.3, 1.0)] {
                let choice = ScriptChoice.chooseLatin(korean: korean, koreanConfidence: koreanConfidence,
                                                      latin: row.read(c.latin, wordBoxes: true), latinConfidence: latinConfidence, height: h)
                XCTAssertEqual(text(choice), "korean|" + c.truth, "\(c.truth) at \(koreanConfidence)/\(latinConfidence)")
            }
        }
    }

    func testKoreanBodyWithAnItemLinkOrAnEnglishWordIsSettled() {
        for truth in ["[길드] [Odo Marsh]: [조잡한 연마석] 팔아요", "[길드] [Odo Marsh]: 오늘 MC 가실분", "[파티] [Odo Marsh]: 버프 plz ㅠㅠ",
                      "경험치 250을 획득했습니다.", "[조잡한 연마석]을 만들었습니다.", "말라깽이 토르벤의 말: 어서 오게나"] {
            XCTAssertTrue(ScriptChoice.isSettledKorean(ScreenRow(truth).read(truth), confidence: 1), truth)
        }
    }

    /// English with one Korean word in it is not a Korean message: it may be shown to the Latin
    /// model, which may mend its brackets and digits but never the Korean word.
    func testEnglishBodyWithOneKoreanWordKeepsThatWord() {
        let truth = "[1. 공개 - 저습지] [Odo Marsh]: lol that 탱커 is so good"
        let row = ScreenRow(truth)
        let korean = row.read("[1. 공개 - 저습지] [Odo Marshj: lol that 탱커 is so g00d")
        XCTAssertFalse(ScriptChoice.isSettledKorean(korean, confidence: 1))
        let latin = row.read([("[1.", 0...0), ("2M|", 1...1), ("-", 2...2), ("X|AX|]", 3...3), ("[Odo", 4...4), ("Marsh]:", 5...5), ("lol", 6...6),
                              ("that", 7...7), ("E7H", 8...8), ("is", 9...9), ("so", 10...10), ("good", 11...11)], wordBoxes: true)
        for confidence in [1.0, 0.5] {
            let choice = ScriptChoice.chooseLatin(korean: korean, koreanConfidence: confidence, latin: latin, latinConfidence: 1, height: h)
            XCTAssertEqual(text(choice), "korean|" + truth)
        }
    }

    func testBracketInFrontOfTheSpeakerColonIsMended() {
        func mend(_ s: String) -> String { ScriptChoice.text(ScriptChoice.mendSpeakerBracket(ScreenRow(s).read(s))) }
        XCTAssertEqual(mend("[길드] [Brann Oakheartj: 그거"), "[길드] [Brann Oakheart]: 그거")
        XCTAssertEqual(mend("[길드][Brann Oakheartl: 그거"), "[길드][Brann Oakheart]: 그거")
        XCTAssertEqual(mend("[1. 공개 - 저습지] [Odo Marsh1: that owl pet is so"), "[1. 공개 - 저습지] [Odo Marsh]: that owl pet is so")
        // Nothing to mend: the name is closed, there is no name, the colon is a clock's.
        for s in ["[길드] [Brann Oakheart]: 그거 l: 3", "[길드] 그거 법사님l: 네", "[21:04] [길드] [Brann Oakheart]: 12:30에 봐요", "cute where is it from"] {
            XCTAssertEqual(mend(s), s)
        }
        // A clock time in front of the header is not the speaker colon.
        XCTAssertEqual(mend("[21:04] [Brann Oakheartj: 그거"), "[21:04] [Brann Oakheart]: 그거")
        XCTAssertEqual(mend("[21:04] 그거 법사님"), "[21:04] 그거 법사님")
    }

    /// The Latin model tells a bracket read as "l" from a name that ends in "l" in front of a
    /// bracket that was not read at all.
    func testLatinModelDecidesTheNameBracket() {
        let h = ScreenRow.height
        var row = ScreenRow("[길드] [Wren Thrall]: need 1 more dps")
        var choice = ScriptChoice.chooseLatin(korean: row.read("[길드] [Wren Thrall: need 1 more dps"), koreanConfidence: 1,
                                              latin: row.read("[25] [Wren Thrall]: need 1 more dps", wordBoxes: true), latinConfidence: 1, height: h)
        XCTAssertEqual(text(choice), "korean|[길드] [Wren Thrall]: need 1 more dps")
        row = ScreenRow("[길드] [Wren Hale]: need 1 more dps")
        choice = ScriptChoice.chooseLatin(korean: row.read("[길드] [Wren Halel: need 1 more dps"), koreanConfidence: 1,
                                          latin: row.read("[25] [Wren Hale]: need 1 more dps", wordBoxes: true), latinConfidence: 1, height: h)
        XCTAssertEqual(text(choice), "korean|[길드] [Wren Hale]: need 1 more dps")
        // A dotless i from the Latin model is a thin stroke without a dot: "l".
        row = ScreenRow("[길드] [Wren Tharl]: 아까 법사님")
        choice = ScriptChoice.chooseLatin(korean: row.read("[길드] [Wren Tharil: 아까 법사님"), koreanConfidence: 0.5,
                                          latin: row.read("[E] [Wren Tharı]: oø ЛЛУ", wordBoxes: true), latinConfidence: 1, height: h)
        XCTAssertEqual(text(choice), "korean|[길드] [Wren Tharl]: 아까 법사님")
    }
}

final class ScriptChoiceForeignScriptTests: XCTestCase {
    private let h = ScreenRow.height

    /// Mixed-script junk read for a Korean row with a short name in it: Cyrillic and
    /// accented letters where the name and the Hangul are.
    func testCyrillicJunkForAKoreanRowIsRejected() {
        let row = ScreenRow("[길드] [Hale Mory]: 더있나?")
        let korean = row.read("[길드] [Hale Moryl: 더있나?")
        let latin = row.read([("[₴Е][Наlе", 0...1), ("Мỗу]:", 2...2), ("£яЧ?", 3...3)], wordBoxes: true)
        let choice = ScriptChoice.chooseLatin(korean: korean, koreanConfidence: 0.5, latin: latin, latinConfidence: 1, height: h)
        XCTAssertEqual(text(choice), "korean|[길드] [Hale Mory]: 더있나?")
        XCTAssertFalse(hasForeignLetters(text(choice)))
    }

    func testGenuineRussianIsAccepted() {
        let truth = "[길드] [Иван]: привет всем, кто идёт в рейд"
        let row = ScreenRow(truth)
        // The Korean model's guess at Cyrillic: Latin soup it is not sure of.
        let korean = row.read("[길드] [VBaH]: npuBeT BceM, KTO ugeT B peug")
        let latin = row.read("[25] [Иван]: привет всем, кто идёт в рейд", wordBoxes: true)
        let choice = ScriptChoice.chooseLatin(korean: korean, koreanConfidence: 0.3, latin: latin, latinConfidence: 1, height: h)
        XCTAssertEqual(text(choice), "cyrillic|" + truth)
        // Skipped by the Korean model altogether.
        let alone = ScriptChoice.chooseLatin(korean: [], koreanConfidence: 0, latin: row.read("[Иван]: привет всем, кто идёт в рейд сегодня",
                                                                                               wordBoxes: true), latinConfidence: 1, height: h)
        if case .cyrillic = alone {} else { XCTFail("a row of Cyrillic the Korean model skipped: \(alone)") }
        // The same letters from a row the Korean model read, for sure, as Korean: never.
        let sure = ScriptChoice.chooseLatin(korean: ScreenRow("[길드] [Иван]: 그거 법사님 준비 하신 거").read("[길드] [VBaH]: 그거 법사님 준비 하신 거"),
                                            koreanConfidence: 1, latin: latin, latinConfidence: 1, height: h)
        XCTAssertTrue(text(sure).hasPrefix("korean|"))
    }

    func testLookAlikesInsideLatinWordsAreFoldedAndStraysDropped() {
        func clean(_ s: String) -> String { ScriptChoice.text(ScriptChoice.withoutStrayScripts(ScreenRow(s).read(s))) }
        // "В", "о", "Н", "у", "М" below are Cyrillic.
        XCTAssertEqual(clean("[길드] [Вorin Вramble]: hellо there"), "[길드] [Borin Bramble]: hello there")
        XCTAssertEqual(clean("[Нale Мorn]: gg"), "[Hale Morn]: gg")
        // What only Cyrillic or Greek has cannot stand in such a row.
        XCTAssertFalse(hasForeignLetters(clean("[길드] [Brann Oakheart]: ачю UХЕyоu")))
        XCTAssertFalse(hasForeignLetters(clean("[길드] [Brann Oakheart]: 7ЛУ t Ф1.")))
        XCTAssertFalse(hasForeignLetters(clean("[길드] [Brann Oakheart]: Ωmega λ")))
        XCTAssertEqual(clean("[길드] [Brann Oakheart]: 그거 법사님"), "[길드] [Brann Oakheart]: 그거 법사님")
    }

    /// The reverse failure: a row of Latin text with something drawn over it, read by the
    /// Korean model as a few syllables it is not sure of. The Latin model, sure of itself,
    /// reads plain words there. For real Hangul it never does.
    func testHangulGuessedIntoLatinTextGivesWay() {
        let truth = "[1. 공개 - 저습지] [Odo Marsh]: hold the line with us"
        let row = ScreenRow(truth)
        let korean = row.read("[1. 공개 - 저습지] [Odo Marsh]: [* tt 몸가릇 릅러 효끝]")
        let latin = row.read("[1. 2M| - X|AX|] [Odo Marsh]: hold the line with us", wordBoxes: true)
        let choice = ScriptChoice.chooseLatin(korean: korean, koreanConfidence: 0.5, latin: latin, latinConfidence: 1, height: h)
        guard case .latinFallback(let glyphs, let confidence) = choice else { return XCTFail("\(choice)") }
        XCTAssertEqual(ScriptChoice.text(glyphs), truth)
        XCTAssertLessThanOrEqual(confidence, 0.5, "a row both models had trouble with is no sure read")
        // A real Korean reply the model was unsure of, and three letters the Latin model is sure of.
        let reply = ScreenRow("[길드] [Odo Marsh]: 법사는 그렇죠 뭐")
        let kept = ScriptChoice.chooseLatin(korean: reply.read("[길드] [Odo Marsh]: 법사는 그렇죠 뭐"), koreanConfidence: 0.5,
                                            latin: reply.read("[25] [Odo Marsh]: SFE aau dA", wordBoxes: true), latinConfidence: 1, height: h)
        XCTAssertEqual(text(kept), "korean|[길드] [Odo Marsh]: 법사는 그렇죠 뭐")
    }
}

final class ScriptChoiceRefineTests: XCTestCase {
    private let h = ScreenRow.height

    private func refined(_ truth: String, korean: String, latin: String) -> String {
        let row = ScreenRow(truth)
        return ScriptChoice.text(ScriptChoice.refine(row.read(korean), with: row.read(latin, wordBoxes: true), height: h))
    }

    func testLinkBracketsReadAsThinLetters() {
        XCTAssertEqual(refined("[1. 공개] [Odo Marsh]: LFG[The Old Iron", korean: "[1. 공개] [Odo Marshl: LFGlThe Old Iron",
                               latin: "[1. 3|] [Odo Marsh]: LFG[The Old Iron"),
                       "[1. 공개] [Odo Marsh]: LFG[The Old Iron")
        XCTAssertEqual(refined("Vow][Bring Back a Ring][The Marrow Span]", korean: "Vow][Bring Back a RingllThe Marrow Spanl",
                               latin: "Vow][Bring Back a Ring][The Marrow Span]"),
                       "Vow][Bring Back a Ring][The Marrow Span]")
        // One stroke where two brackets stand.
        XCTAssertEqual(refined("Vow][Bring Back a Ring][The Marrow Span]", korean: "Vowl[Bring Back a RinglThe Marrow Span]",
                               latin: "Vow][Bring Back a Ring][The Marrow Span]"),
                       "Vow][Bring Back a Ring][The Marrow Span]")
        // The Latin model has no bracket there either: nothing is taken from it.
        XCTAssertEqual(refined("Ring][The", korean: "RingllThe", latin: "RingIIThe"), "RingllThe")
    }

    func testDigitsReadForLettersAndLettersForDigits() {
        XCTAssertEqual(refined("good", korean: "g00d", latin: "good"), "good")
        XCTAssertEqual(refined("good", korean: "800d", latin: "good"), "good")
        XCTAssertEqual(refined("need LF2M now", korean: "need LFZM now", latin: "need LF2M now"), "need LF2M now")
        // What chat really writes with digits stays, whatever the other model makes of it.
        XCTAssertEqual(refined("wts 50g LF2M 5v5 t2 60s", korean: "wts 50g LF2M 5v5 t2 60s", latin: "wts sog LFZM svs tz bos"),
                       "wts 50g LF2M 5v5 t2 60s")
    }

    func testAccentsCaseAndThinLetters() {
        XCTAssertEqual(refined("¿alguien para más daño?", korean: "talguien para mas dano?", latin: "¿alguien para más daño?"),
                       "¿alguien para más daño?")
        XCTAssertEqual(refined("[Dorn Ironvale]: summon", korean: "[Dorn lronvale]: Summon", latin: "[Dorn Ironvale]: summon"),
                       "[Dorn Ironvale]: summon")
        XCTAssertEqual(refined("[Sylvanas]: omw, 2 min", korean: "[Syvanas]: omw 2 min", latin: "[Sylvanas]: omw, 2 min"),
                       "[Sylvanas]: omw, 2 min")
    }

    /// A word the two models read differently for no known reason stays as the Korean model
    /// read it: every other row of the chat comes from that model, and a name must not change
    /// its spelling from one row to the next.
    func testAWordReadDifferentlyIsNotTakenOver() {
        XCTAssertEqual(refined("[Dorn Bramble]: GO TO", korean: "[Dorn Bramble]: GO TO", latin: "[Darn Bramble]: GO TO"), "[Dorn Bramble]: GO TO")
        let row = ScreenRow("[1. 공개 - 저습지] [Dorn Bramble]: GO TO THE GATE")
        let korean = row.read("[1. 공개 - 저습지] [Dorn Bramble]: GO TO THE GATE")
        // Unsure of the row, sound as it stands, one word apart: kept.
        var choice = ScriptChoice.chooseLatin(korean: korean, koreanConfidence: 0.5,
                                              latin: row.read("[1. 2M| - X|AX|] [Darn Bramble]: GO TO THE GATE", wordBoxes: true), latinConfidence: 1, height: h)
        XCTAssertEqual(text(choice), "korean|[1. 공개 - 저습지] [Dorn Bramble]: GO TO THE GATE")
        // The only word of a row, which the Korean model was unsure of and the other is not.
        let lone = ScreenRow("good")
        choice = ScriptChoice.chooseLatin(korean: lone.read("eood"), koreanConfidence: 0.5, latin: lone.read("good", wordBoxes: true),
                                          latinConfidence: 1, height: h)
        XCTAssertEqual(text(choice), "latin|good")
        choice = ScriptChoice.chooseLatin(korean: lone.read("eood"), koreanConfidence: 1, latin: lone.read("good", wordBoxes: true),
                                          latinConfidence: 1, height: h)
        XCTAssertEqual(text(choice), "korean|eood", "sure of the row: the word stays")
        // Several words apart: the model that was unsure is the one that struggled.
        choice = ScriptChoice.chooseLatin(korean: row.read("[1. 공개 - 저습지] [Dorn Bramble]: GC TC THE GATF"), koreanConfidence: 0.5,
                                          latin: row.read("[1. 2M| - X|AX|] [Dorn Bramble]: GO TO THE GATE", wordBoxes: true), latinConfidence: 1, height: h)
        XCTAssertEqual(text(choice), "latin|[1. 공개 - 저습지] [Dorn Bramble]: GO TO THE GATE")
    }

    /// A header row the Korean model was unsure of, with both brackets of the name read as
    /// letters and the dash of the channel tag as a tilde: the Latin model reads the name group
    /// soundly, and the row is a sound header at once (it used to wait, and its wrapped row
    /// went out alone).
    func testDamagedNameGroupOfAHeaderRowIsMendedAtOnce() {
        let truth = "[1. 공개 ~ 저습지] [Dorn Flint]: that owl pet is so"
        let row = ScreenRow(truth)
        let choice = ScriptChoice.chooseLatin(korean: row.read("[1. 공개 ~ 저습지] iDorn Flintj: that owl pet is so"), koreanConfidence: 0.5,
                                              latin: row.read("[1. 2H| - X1X|] [Dorn Flint]: that owl pet is so", wordBoxes: true),
                                              latinConfidence: 1, height: h)
        XCTAssertEqual(text(choice), "korean|" + truth)
        let parsed = ChatLineParser.parse(truth, locale: .koKR)
        XCTAssertTrue(parsed.hasPrefix && !parsed.isDamagedHeader)
        XCTAssertEqual(parsed.sender, "Dorn Flint")
        XCTAssertEqual(parsed.channel, .publicChannel)
    }

    /// The Chinese/Japanese model's guess at small or noisy Hangul is not taken for Chinese:
    /// it reads fewer Han than the Korean model read syllables.
    func testKoreanIsNotTakenForChinese() {
        func glyphs(_ s: String) -> [OCRGlyph] { ScreenRow(s).read(s) }
        let korean = glyphs("[길드] [Wren Tharl]: 20렙 3개 구함")
        XCTAssertFalse(ScriptChoice.isChineseOrJapanese(korean: korean, foreign: glyphs("TWren Thar:20g 37日 予計")))
        // The Korean model's guesses at Han and kana have a syllable here and there.
        XCTAssertTrue(ScriptChoice.isChineseOrJapanese(korean: glyphs("[길드] [JJE]: 리>-##쁜# #분마디"), foreign: glyphs("[小明]: 有人一起打副本吗?我是治疗")))
        XCTAssertTrue(ScriptChoice.isChineseOrJapanese(korean: glyphs("[D5회]님의 귓속말: 쏙카-T,튜 노쬐"), foreign: glyphs("[阿強]: 等我一下,馬上到")))
        XCTAssertTrue(ScriptChoice.isChineseOrJapanese(korean: glyphs("[파티] [72): K3LKDWLTLWD"), foreign: glyphs("[タケシ]: よろしくお願いします")))
        XCTAssertTrue(ScriptChoice.isChineseOrJapanese(korean: [], foreign: glyphs("[小明]: 有人一起打副本吗")))
        // Latin text with a Han guess in it is neither.
        XCTAssertFalse(ScriptChoice.isChineseOrJapanese(korean: glyphs("need 1 more dps for mara"), foreign: glyphs("need l rnore dps 三 for maara")))
    }

    func testTwoModelsThatAgreeAreAsGoodAsOneThatIsSure() {
        let row = ScreenRow("[1. 공개 - 저습지] [Dorn Bramble]: GO TO THE GATE")
        let korean = row.read("[1. 공개 - 저습지] [Dorn Bramble]: GO TO THE GATE")
        XCTAssertTrue(ScriptChoice.agree(korean: korean, latin: row.read("[1. 2M| - X|AX|] [Dorn Bramble]: GO TO THE GATE", wordBoxes: true), height: h))
        XCTAssertFalse(ScriptChoice.agree(korean: korean, latin: row.read("[1. 2M| - X|AX|] [Darn Bramble]: GO TO THE GATE", wordBoxes: true), height: h))
        let reply = ScreenRow("[길드] [Odo Marsh]: 법사는")
        XCTAssertFalse(ScriptChoice.agree(korean: reply.read("[길드] [Odo Marsh]: 법사는"), latin: reply.read("[25] [Odo Marsh]: SFE", wordBoxes: true), height: h))
    }

    func testWhichRowsGetASecondOpinion() {
        func glyphs(_ s: String) -> [OCRGlyph] { ScreenRow(s).read(s) }
        for s in ["LFGlThe Old Iron", "LFGIThe Old Iron", "a RingllThe Marrow", "Vowl[Bring Back", "Ring]lThe Marrow", "Ringi[The"] {
            XCTAssertTrue(ScriptChoice.hasLinkLookAlike(glyphs(s)), s)
        }
        for s in ["GO TO THE GATE MILITIAS", "ALL WILLING SOLDIERS", "McIntyre says hi", "WTS [Iron Bar]", "Hello all", "ILvl 20 lfg", "its over"] {
            XCTAssertFalse(ScriptChoice.hasLinkLookAlike(glyphs(s)), s)
        }
        for s in ["g00d", "so g00d!", "800d"] { XCTAssertTrue(ScriptChoice.hasDigitLookAlike(glyphs(s)), s) }
        for s in ["wts 50g", "LF2M", "5v5", "t2 set", "ony8", "60s", "2nd", "1k", "100%", "20렙"] {
            XCTAssertFalse(ScriptChoice.hasDigitLookAlike(glyphs(s)), s)
        }
    }
}

/// The first letter of a name where the two models' boxes do not line up, and the capital "J",
/// which the Korean model runs into a bracket or writes small.
final class ScriptChoiceNameStartTests: XCTestCase {
    private let h = ScreenRow.height

    /// A glyph per box, 17 px a glyph and 9 px a space, from x = 76.
    private func glyphByGlyph(_ text: String) -> [OCRGlyph] {
        var out: [OCRGlyph] = []
        var x: CGFloat = 76
        var space = false
        for c in text {
            if c == " " { x += 9; space = true; continue }
            out.append(OCRGlyph(character: c, minX: x, maxX: x + 17, spaceBefore: space && !out.isEmpty))
            x += 17
            space = false
        }
        return out
    }

    /// Words with one box each, as the Latin model gives them.
    private func wordByWord(_ words: [(String, CGFloat, CGFloat)]) -> [OCRGlyph] {
        var out: [OCRGlyph] = []
        for (text, lo, hi) in words {
            for (n, c) in text.enumerated() {
                out.append(OCRGlyph(character: c, minX: lo, maxX: hi, spaceBefore: n == 0 && !out.isEmpty))
            }
        }
        return out
    }

    /// "[Sly" stands at 76...144, the "J" at 153...170 (centre 161.5), the rest of the word
    /// behind it. The other model's box for "Jorvik]:" begins at 163: a pixel and a half right
    /// of that centre. The "J" is the word's own first letter and is not written a second time.
    func testFirstLetterJustOutsideTheOtherModelsBoxIsNotDoubled() {
        let korean = glyphByGlyph("[Sly Jorvikl: hold the line")
        let latin = wordByWord([("[Sly", 76, 144), ("Jorvik]:", 163, 289), ("hold", 298, 366), ("the", 375, 426), ("line", 435, 503)])
        XCTAssertEqual(ScriptChoice.text(ScriptChoice.refine(korean, with: latin, height: h)), "[Sly Jorvik]: hold the line")
        // The other model read another word there: nothing is taken from it, and nothing is added.
        let other = wordByWord([("[Sly", 76, 144), ("Korvik]:", 163, 289), ("hold", 298, 366), ("the", 375, 426), ("line", 435, 503)])
        XCTAssertEqual(ScriptChoice.text(ScriptChoice.refine(korean, with: other, height: h)), "[Sly Jorvikl: hold the line")
        // A word that really lost its capital still gets it.
        let lost = glyphByGlyph("[Sly orvikl: hold the line")
        let whole = wordByWord([("[Sly", 76, 144), ("Jorvik]:", 153, 272), ("hold", 281, 349), ("the", 358, 409), ("line", 418, 486)])
        XCTAssertEqual(ScriptChoice.text(ScriptChoice.refine(lost, with: whole, height: h)), "[Sly Jorvik]: hold the line")
    }

    /// The capital "J" of a name written small, with the bracket behind the name written as a
    /// "j" too; and the "J" behind the opening bracket not read at all.
    func testCapitalJOfAName() {
        func refined(_ truth: String, korean: String, latin: String) -> String {
            let row = ScreenRow(truth)
            return ScriptChoice.text(ScriptChoice.refine(row.read(korean), with: row.read(latin, wordBoxes: true), height: h))
        }
        XCTAssertEqual(refined("[Sly Jorvik]: hold the line", korean: "[Sly jorvikj: hold the line", latin: "[Sly Jorvik]: hold the line"),
                       "[Sly Jorvik]: hold the line")
        XCTAssertEqual(refined("[Jora Fennick]: hold the line", korean: "[ora Fennick]: hold the line", latin: "[Jora Fennick]: hold the line"),
                       "[Jora Fennick]: hold the line")
        XCTAssertEqual(ChatLineParser.parse("[1. 공개 - 저습지] [Jora Fennick]: hold the line", locale: .koKR).sender, "Jora Fennick")
        // In running text the Korean model's small "j" stays: "jk" is not "Jk".
        XCTAssertEqual(refined("jk lol", korean: "jk lol", latin: "JK lol"), "jk lol")
        XCTAssertEqual(refined("[Odo Marsh]: just joking", korean: "[Odo Marsh]: just joking", latin: "[Odo Marsh]: just Joking"),
                       "[Odo Marsh]: just joking", "behind the speaker colon the Korean model's small letter stays")
    }
}
