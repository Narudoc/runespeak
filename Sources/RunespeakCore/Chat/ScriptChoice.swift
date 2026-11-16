import Foundation
import CoreGraphics

/// One glyph of an OCR reading with its horizontal extent in image pixels. A recognition model
/// that only reports word boxes gives all glyphs of a word the same extent.
public struct OCRGlyph: Sendable, Equatable {
    public var character: Character
    public var minX: CGFloat
    public var maxX: CGFloat
    public var spaceBefore: Bool

    public init(character: Character, minX: CGFloat, maxX: CGFloat, spaceBefore: Bool) {
        self.character = character; self.minX = minX; self.maxX = maxX; self.spaceBefore = spaceBefore
    }

    /// Where the glyph "starts" for deciding which side of a seam it is on. Not the centre:
    /// some models stretch a bracket's box over the space that follows it.
    public var anchorX: CGFloat { minX + (maxX - minX) * 0.25 }
}

/// Which recognition model is believed for which part of a chat row of a Korean client.
///
/// Three models read a row, none of them all scripts: Korean + Latin (the first pass over
/// every frame), Latin + Cyrillic, and Chinese/Japanese + Latin. Each one answers with
/// confident nonsense for a script it does not know: the Latin model writes digits, bars and
/// Cyrillic letters where Hangul stands, the Korean model a soup of Latin letters where
/// Cyrillic stands. The rules, in the order they are applied:
///
///  1. The Korean reading is the base. A message it read as Korean is final (`isSettledKorean`):
///     no other model can read Hangul, so none is asked.
///  2. The Korean model takes the "]" in front of the speaker colon for a thin letter on about
///     every other row ("[Some Namej: text"). That is mended in the text
///     (`mendSpeakerBracket`); a bracket that does not pair up is no reason by itself to
///     distrust the row.
///  3. Where the Latin model is asked, it may only *refine* words the Korean model read without
///     Hangul (`refine`): a bracket where the Korean reading has a thin letter, a letter where
///     it has a look-alike digit, an accent it dropped. A word the two models read differently
///     in any other way stays as the Korean model read it.
///  4. Another model replaces the Korean reading of the message only when the Korean model
///     could not read the row (`chooseLatin`): low confidence, no Korean words. Cyrillic is
///     believed only as whole words on such a row; Cyrillic letters inside Latin words are
///     look-alikes and are folded back (`foldLookAlikes`), and a reading that still mixes
///     scripts after that is thrown away.
///  5. Hangul on a row the Korean model was unsure of is believed unless the Latin model
///     reads the same stretch as plain words (`hangulIsMisreadLatin`): that is a row of
///     Latin text with something drawn over it.
///  6. Whatever is left of scripts that cannot stand in a row (a Cyrillic or Greek letter in a
///     row not accepted under 4) never leaves the recogniser (`withoutStrayScripts`).
public enum ScriptChoice {

    public enum Script: Sendable { case hangul, han, kana, cyrillic, greek, latin, other }

    public static func script(_ c: Character) -> Script {
        guard let u = c.unicodeScalars.first?.value else { return .other }
        switch u {
        case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: return .hangul
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: return .han
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .kana
        case 0x0400...0x052F: return .cyrillic
        case 0x0370...0x03FF, 0x1F00...0x1FFF: return .greek
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: return .latin
        default: return .other
        }
    }

    public static func count(_ glyphs: [OCRGlyph], _ scripts: Script...) -> Int {
        glyphs.reduce(0) { $0 + (scripts.contains(script($1.character)) ? 1 : 0) }
    }

    public static func text(_ glyphs: [OCRGlyph]) -> String {
        var s = ""
        for (i, g) in glyphs.enumerated() {
            if g.spaceBefore, i > 0 { s.append(" ") }
            s.append(g.character)
        }
        return s
    }

    public static func bracketsBalanced(_ glyphs: [OCRGlyph]) -> Bool {
        var depth = 0
        for g in glyphs {
            if g.character == "[" { depth += 1 }
            if g.character == "]" { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0
    }

    /// Glyph index ranges of the space-separated words of a reading.
    public static func words(_ glyphs: [OCRGlyph]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for i in glyphs.indices where i > 0 && glyphs[i].spaceBefore {
            out.append(start..<i)
            start = i
        }
        if start < glyphs.count { out.append(start..<glyphs.count) }
        return out
    }

    // MARK: - Parts of a Korean reading

    /// Index ranges of a low-confidence Korean reading that are still trustworthy: the parts of a
    /// koKR chat line that are Korean whatever the speaker's language — the channel tag
    /// ("[길드]", "[2. 거래]"), a Korean speaker name, and the verb phrase before the colon
    /// ("님의 귓속말:", "의 외침:", "의 말:").
    public static func trustedKoreanRanges(_ g: [OCRGlyph]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        guard !g.isEmpty else { return ranges }
        var i = 0

        func closingBracket(from start: Int) -> Int? {
            var j = start + 1
            while j < g.count, j - start <= 26 {
                if g[j].character == "]" { return j }
                if g[j].character == "[" { return nil }
                j += 1
            }
            return nil
        }
        /// Hangul words directly after index `from`, ending in a colon ("님의 귓속말:").
        func verbPhrase(from start: Int) -> Int? {
            var j = start
            var hangul = 0
            while j < g.count, j - start <= 10 {
                if g[j].character == ":" { return hangul >= 1 ? j : nil }
                guard script(g[j].character) == .hangul else { return nil }
                hangul += 1
                j += 1
            }
            return nil
        }

        if g[0].character == "[", let end = closingBracket(from: 0) {
            let inner = Array(g[1..<end])
            if isChannelTag(inner) || isKoreanName(inner) { ranges.append(0..<(end + 1)) }
            i = end + 1
        }
        if i < g.count, let colon = verbPhrase(from: i) {
            ranges.append(i..<(colon + 1))
            i = colon + 1
        } else if i > 0, i < g.count, g[i].character == "[", let end = closingBracket(from: i) {
            if isKoreanName(Array(g[(i + 1)..<end])) {
                var upper = end + 1
                if upper < g.count, g[upper].character == ":" { upper += 1 }
                ranges.append(i..<upper)
                i = upper
                if i < g.count, let colon = verbPhrase(from: i) { ranges.append(i..<(colon + 1)) }
            } else if let colon = verbPhrase(from: end + 1) {
                ranges.append((end + 1)..<(colon + 1))
            }
        }

        // A speaker phrase is trusted wherever it stands: the bracket before it may have been
        // misread ("[Garroshl의 외침:").
        if !ranges.contains(where: { r in g[r].contains { $0.character == ":" } }) {
            var j = 0
            scan: while j < g.count, j < 40 {
                guard script(g[j].character) == .hangul else { j += 1; continue }
                var end = j
                while end < g.count, script(g[end].character) == .hangul { end += 1 }
                if end < g.count, g[end].character == ":",
                   speakerPhrases.contains(String(g[j..<end].map(\.character))),
                   !ranges.contains(where: { $0.overlaps(j..<(end + 1)) }) {
                    ranges.append(j..<(end + 1))
                    ranges.sort { $0.lowerBound < $1.lowerBound }
                    break scan
                }
                j = end
            }
        }

        // Adjacent ranges read better as one.
        var merged: [Range<Int>] = []
        for r in ranges {
            if let last = merged.last, last.upperBound == r.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<r.upperBound
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// koKR CHAT_*_GET phrases between the speaker and the message, spaces removed.
    private static let speakerPhrases: Set<String> = [
        "님의귓속말", "의귓속말", "에게귓속말", "님에게귓속말", "의외침", "의말", "님의말", "님의외침",
    ]

    /// "길드", "2. 거래", "1. 일반 - 오그리마", "공격대 경보".
    private static func isChannelTag(_ inner: [OCRGlyph]) -> Bool {
        var rest = inner[...]
        // Optional channel number.
        var digits = 0
        while let f = rest.first, f.character.isASCII, f.character.isNumber, digits < 2 { rest = rest.dropFirst(); digits += 1 }
        if digits > 0 {
            guard rest.first?.character == "." else { return false }
            rest = rest.dropFirst()
        }
        var hangul = 0
        for g in rest {
            if script(g.character) == .hangul { hangul += 1 } else if g.character != "-" && g.character != "·" { return false }
        }
        return hangul >= 2
    }

    /// Hangul only, optionally "이름-서버".
    private static func isKoreanName(_ inner: [OCRGlyph]) -> Bool {
        guard inner.count >= 2, inner.count <= 20 else { return false }
        return inner.allSatisfy { script($0.character) == .hangul || $0.character == "-" }
            && count(inner, .hangul) >= 2
    }

    /// Glyphs of a Korean reading outside its trusted ranges.
    public static func untrustedPart(of korean: [OCRGlyph]) -> [OCRGlyph] {
        let kept = trustedKoreanRanges(korean)
        return korean.indices.filter { i in !kept.contains { $0.contains(i) } }.map { korean[$0] }
    }

    /// True when the text is Korean rather than the Korean model's guess at another script:
    /// guesses are a soup of symbols, digits and the odd syllable.
    public static func looksKorean(_ glyphs: [OCRGlyph]) -> Bool {
        var hangul = 0, other = 0
        for g in glyphs {
            switch script(g.character) {
            case .hangul: hangul += 1
            case .latin: break                      // names, "raid", "dps" inside Korean sentences
            default:
                let c = g.character
                if c == "[" || c == "]" || c == ":" || c == "." || c == "," || c == "?" || c == "!" || c == "~" { break }
                other += 1
            }
        }
        return hangul >= 2 && hangul * 10 >= (hangul + other) * 7
    }

    /// Index of the speaker colon: the first colon of the row that does not sit inside a
    /// clock time ("21:04").
    static func speakerColon(_ g: [OCRGlyph], within limit: Int = 72) -> Int? {
        for (i, glyph) in g.enumerated() where i < limit && glyph.character == ":" {
            let digitBefore = i > 0 && g[i - 1].character.isNumber
            let digitAfter = i + 1 < g.count && g[i + 1].character.isNumber && !g[i + 1].spaceBefore
            if digitBefore && digitAfter { continue }
            return i
        }
        return nil
    }

    /// Glyphs of the message itself as the Korean model read it: outside the trusted header
    /// parts (channel tag, Korean name, speech phrase) and, on a row that opens like a header,
    /// behind the speaker colon.
    public static func koreanBody(of g: [OCRGlyph]) -> [OCRGlyph] {
        let trusted = trustedKoreanRanges(g)
        var from = 0
        if let first = g.first, first.character == "[" {
            if let r = trusted.last(where: { r in g[r].contains { $0.character == ":" } }) {
                from = r.upperBound
            } else if let colon = speakerColon(g) {
                from = colon + 1
            }
        }
        return g.indices.filter { i in i >= from && !trusted.contains { $0.contains(i) } }.map { g[$0] }
    }

    /// Whole words of Hangul that outweigh the Latin around them: Korean, or Korean with game
    /// terms in it. Not a stray syllable at the end of a Latin word ("500g늃").
    public static func hasKoreanWords(_ body: [OCRGlyph]) -> Bool {
        var koreanWords = 0, hangul = 0, latinOutsideLinks = 0, depth = 0
        for range in words(body) {
            var h = 0, l = 0
            for g in body[range] {
                if g.character == "[" { depth += 1 }
                if g.character == "]" { depth = max(0, depth - 1) }
                switch script(g.character) {
                case .hangul: h += 1
                case .latin: l += 1; if depth == 0 { latinOutsideLinks += 1 }
                default: break
                }
            }
            hangul += h
            if (h >= 1 && l == 0) || (h >= 2 && h >= l) { koreanWords += 1 }
        }
        return koreanWords >= 1 && hangul * 4 >= latinOutsideLinks
    }

    /// Korean by its looks alone, whatever the model's confidence: what a guess at Cyrillic,
    /// Han or kana (symbols, digits, a syllable here and there) is not.
    public static func isShapedLikeKorean(_ body: [OCRGlyph]) -> Bool {
        hasKoreanWords(body) && looksKorean(body)
    }

    /// True when the Korean model read the message of the row as Korean in a reading it is
    /// sure of: the row needs no other model, and no other model could read it.
    public static func isSettledKorean(_ glyphs: [OCRGlyph], confidence: Double) -> Bool {
        confidence >= sure && hasKoreanWords(koreanBody(of: glyphs))
    }

    /// Whether the Chinese/Japanese model's reading of a row is to be believed over the Korean
    /// model's, which was unsure of the row. Each model writes at most one letter of its own
    /// script for a glyph of the other's and symbols, digits or Latin letters for the rest: on
    /// a Chinese row the Korean model guesses fewer syllables ("쏙카-T,튜 노쬐" for seven Han)
    /// than the other model reads Han, and on a Korean row it is the other way round ("20렙 3개
    /// 구함" against "20g 37日 予計"). `foreign`: the other model's part of the spliced row.
    public static func isChineseOrJapanese(korean: [OCRGlyph], foreign: [OCRGlyph]) -> Bool {
        let theirs = count(foreign, .han, .kana)
        // Han guesses for Latin text come out as a letter here and there; real Chinese or
        // Japanese fills the line.
        guard theirs >= 1, theirs * 3 >= count(foreign, .latin) else { return false }
        let syllables = koreanBody(of: korean).filter { (0xAC00...0xD7A3).contains($0.character.unicodeScalars.first?.value ?? 0) }.count
        return syllables < 2 || theirs > syllables
    }

    /// The Korean model's confidence for text it reads well; it answers 0.5 or 0.3 for text it
    /// has to guess at.
    public static let sure = 0.9

    // MARK: - Brackets read as thin letters

    /// Glyphs the Korean model writes for "[" or "]" next to Latin letters.
    static let bracketLookAlikes: Set<Character> = ["l", "I", "j", "J", "1", "|", "!", "i", "(", ")", "{", "}"]

    /// "[Some Namej: text" → "[Some Name]: text": the bracket in front of the speaker colon,
    /// read as a thin letter, with the name's opening bracket still unclosed.
    public static func mendSpeakerBracket(_ glyphs: [OCRGlyph]) -> [OCRGlyph] {
        guard let first = glyphs.first, first.character == "[", let colon = speakerColon(glyphs, within: 60), colon >= 3 else { return glyphs }
        var depth = 0
        for g in glyphs[..<colon] {
            if g.character == "[" { depth += 1 }
            if g.character == "]" { depth -= 1 }
        }
        let mark = glyphs[colon - 1], before = glyphs[colon - 2]
        guard depth == 1, !mark.spaceBefore, !glyphs[colon].spaceBefore, "jlI1i|!J".contains(mark.character),
              before.character != "[", before.character.isLetter || before.character.isNumber else { return glyphs }
        var out = glyphs
        out[colon - 1].character = "]"
        return out
    }

    /// True when a word of the row looks like a link whose brackets were read as letters:
    /// "LFGlThe Old Iron", "RingllThe", "Vowl[Bring" (a thin letter or two between a letter and
    /// the capital that starts a word, or glued to a bracket). All-capital words ("MILITIAS")
    /// and ordinary names ("McIntyre") do not match.
    public static func hasLinkLookAlike(_ glyphs: [OCRGlyph]) -> Bool {
        let thin: Set<Character> = ["l", "I", "j", "1", "|"]
        for range in words(glyphs) {
            let w = Array(glyphs[range].map(\.character))
            guard w.count >= 4 else { continue }
            // "Ringi[The": a small letter caught between a word and the bracket of a link.
            for n in 2..<w.count where w[n] == "[" && n + 1 < w.count && w[n + 1].isUppercase {
                if "i!".contains(w[n - 1]), w[n - 2].isLetter { return true }
            }
            var i = 1
            while i < w.count {
                guard thin.contains(w[i]) else { i += 1; continue }
                var end = i
                while end + 1 < w.count, thin.contains(w[end + 1]), end - i < 1 { end += 1 }
                let before = w[i - 1]
                // Glued to a bracket: "l[", "]l".
                if before == "]" || (end + 1 < w.count && w[end + 1] == "[") { return true }
                // ("MILITIAS" has no small letter behind the capital that follows its "I".)
                if end + 2 < w.count, before.isLetter, w[end + 1].isUppercase, w[end + 2].isLowercase { return true }
                i = end + 1
            }
        }
        return false
    }

    /// True when a word mixes digits into letters the way a misread does ("g00d", "800d") and
    /// not the way chat does ("50g", "LF2M", "5v5", "t2"): worth a second opinion.
    public static func hasDigitLookAlike(_ glyphs: [OCRGlyph]) -> Bool {
        words(glyphs).contains { range in
            let w = String(glyphs[range].map(\.character)).trimmingCharacters(in: .punctuationCharacters)
            return isDigitMisreadCandidate(Array(w))
        }
    }

    private static let amountUnits: Set<String> = [
        "g", "s", "c", "k", "x", "h", "m", "v", "gp", "sp", "cp", "ea", "st", "nd", "rd", "th", "lvl", "min", "sec", "hr", "ms", "pt", "pts",
    ]

    /// Lower-case letters with look-alike digits between or in front of them. Capitals around a
    /// digit are codes ("LF2M", "UBRS10"), digits behind letters are sizes and tiers ("ony8",
    /// "t2"), digits in front of a unit are amounts ("50g", "2nd").
    static func isDigitMisreadCandidate(_ w: [Character]) -> Bool {
        guard w.count >= 3, w.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        let digits = w.filter(\.isNumber).count
        let letters = w.count - digits
        guard digits >= 1, letters >= 1, let last = w.last, last.isLetter else { return false }
        guard w.allSatisfy({ $0.isNumber || $0.isLowercase }) else { return false }
        let lead = w.prefix { $0.isNumber }
        if !lead.isEmpty {
            let tail = String(w.dropFirst(lead.count))
            if tail.allSatisfy(\.isLetter), amountUnits.contains(tail) { return false }
            return tail.allSatisfy(\.isLetter)
        }
        return letters >= 2
    }

    // MARK: - Look-alikes of other scripts

    /// Cyrillic and Greek letters and the Latin letters drawn the same way.
    static let latinTwinOf: [Character: Character] = [
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T",
        "У": "Y", "Х": "X", "І": "I", "Ј": "J", "Ѕ": "S",
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s",
        "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K", "Μ": "M", "Ν": "N", "Ο": "O",
        "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X", "ο": "o", "ν": "v", "ι": "i", "κ": "k", "ρ": "p", "υ": "u",
    ]
    private static let latinTwins = Set(latinTwinOf.values)

    /// Words of two letters or more: those that can only be Cyrillic, and those that mix
    /// letters only Cyrillic has with letters only Latin has or with digits.
    public static func scriptWords(_ glyphs: [OCRGlyph]) -> (cyrillic: Int, mixed: Int, total: Int) {
        var cyrillic = 0, mixed = 0, total = 0
        for range in words(glyphs) {
            var onlyCyrillic = 0, onlyLatin = 0, letters = 0, digits = 0
            for g in glyphs[range] {
                let c = g.character
                if c.isNumber { digits += 1 }
                switch script(c) {
                case .cyrillic: letters += 1; if latinTwinOf[c] == nil { onlyCyrillic += 1 }
                case .latin: letters += 1; if !latinTwins.contains(c) { onlyLatin += 1 }
                default: break
                }
            }
            guard letters >= 2 else { continue }
            total += 1
            if onlyCyrillic >= 1, onlyLatin >= 1 || digits >= 1 { mixed += 1 } else if onlyCyrillic >= 1 { cyrillic += 1 }
        }
        return (cyrillic, mixed, total)
    }

    /// Cyrillic and Greek look-alikes inside a word that is otherwise Latin become the Latin
    /// letters ("Вorin" with a Cyrillic В).
    public static func foldLookAlikes(_ glyphs: [OCRGlyph]) -> [OCRGlyph] {
        var out = glyphs
        for range in words(glyphs) {
            var onlyForeign = 0, onlyLatin = 0, twins = 0
            for g in glyphs[range] {
                switch script(g.character) {
                case .cyrillic, .greek: if latinTwinOf[g.character] == nil { onlyForeign += 1 } else { twins += 1 }
                case .latin: if !latinTwins.contains(g.character) { onlyLatin += 1 }
                default: break
                }
            }
            guard twins > 0, onlyForeign == 0, onlyLatin >= 1 else { continue }
            for i in range { if let twin = latinTwinOf[out[i].character] { out[i].character = twin } }
        }
        return out
    }

    /// The reading without what cannot stand in it: Cyrillic and Greek look-alikes become the
    /// Latin letters wherever a word has no letter that only those scripts have, and any other
    /// letter of the two scripts is dropped. For rows that were not accepted as Cyrillic text.
    public static func withoutStrayScripts(_ glyphs: [OCRGlyph]) -> [OCRGlyph] {
        guard glyphs.contains(where: { let s = script($0.character); return s == .cyrillic || s == .greek }) else { return glyphs }
        var out: [OCRGlyph] = []
        out.reserveCapacity(glyphs.count)
        var pendingSpace = false
        for range in words(glyphs) {
            let foreignOnly = glyphs[range].contains {
                let s = script($0.character)
                return (s == .cyrillic || s == .greek) && latinTwinOf[$0.character] == nil
            }
            for i in range {
                var g = glyphs[i]
                let s = script(g.character)
                if s == .cyrillic || s == .greek {
                    guard !foreignOnly, let twin = latinTwinOf[g.character] else {
                        if g.spaceBefore { pendingSpace = true }
                        continue
                    }
                    g.character = twin
                }
                if pendingSpace { g.spaceBefore = true; pendingSpace = false }
                out.append(g)
            }
        }
        if !out.isEmpty { out[0].spaceBefore = false }
        return out
    }

    // MARK: - Second opinion, word by word

    private static let digitTwins: [Character: Set<Character>] = [
        "0": ["o", "O", "Q", "D"], "1": ["l", "I", "i"], "2": ["z", "Z"], "5": ["s", "S"], "6": ["b", "G"],
        "8": ["g", "B", "S", "a"], "9": ["g", "q"],
    ]

    /// `k` rewritten with what `l` knows better, when the two are one word read by two models:
    /// equal but for brackets against thin letters, letters against look-alike digits, accents
    /// and case. Nil when they differ in any other way, or in nothing that `l` knows better.
    /// Each element: the character and the index in `k` it stands for (nil: inserted).
    /// `midWord`: `k` is not all of the word the Korean model read there but begins inside it
    /// (the first letters of that word stand outside the box of `l`): a letter `l` has in
    /// front of it is then one of those, not one the Korean model lost.
    /// `inName`: the word stands in front of the speaker colon, where a word that begins with
    /// "J" is part of a name and has a capital.
    static func mergeEquivalent(_ k: [Character], _ l: [Character], midWord: Bool = false, inName: Bool = false)
        -> [(character: Character, source: Int?)]? {
        mergeLetterByLetter(k, l, midWord: midWord, inName: inName) ?? mergeAroundBrackets(k, l)
    }

    /// Two links that follow each other inside one word ("Ring][The"): the Korean model writes
    /// one or two thin letters for the pair of brackets and now and then loses the capital
    /// behind them ("RingllThe", "RinglThe", "Ringilhe"), while the Latin model reads at least
    /// one of the brackets ("RingI[The", "Ring|[The"). Where the two readings agree on the
    /// letters in front of that spot and behind it, what stands between them is the Latin
    /// model's: nothing but brackets, strokes and at most one capital on its side, nothing but
    /// thin letters on the other.
    static func mergeAroundBrackets(_ k: [Character], _ l: [Character]) -> [(character: Character, source: Int?)]? {
        var p = 0
        while p < k.count, p < l.count, k[p] == l[p] { p += 1 }
        var s = 0
        while s < k.count - p, s < l.count - p, k[k.count - 1 - s] == l[l.count - 1 - s] { s += 1 }
        let km = Array(k[p..<(k.count - s)]), lm = Array(l[p..<(l.count - s)])
        guard p >= 2, s >= 2, k[..<p].allSatisfy(\.isLetter), !km.isEmpty, km.count <= 3, lm.count >= 2, lm.count <= 3,
              lm.contains(where: { $0 == "[" || $0 == "]" }),
              km.allSatisfy({ bracketLookAlikes.contains($0) }) else { return nil }
        var capitals = 0
        for (n, c) in lm.enumerated() {
            if c == "[" || c == "]" || c == "|" || c == "I" || c == "l" || c == "!" { continue }
            // The capital that opens the second link, right behind its bracket.
            guard c.isUppercase, n > 0, lm[n - 1] == "[", n == lm.count - 1 else { return nil }
            capitals += 1
        }
        // A second link opens there: with a capital, on either side of the seam.
        guard capitals == 1 || l[l.count - s].isUppercase else { return nil }
        var out: [(character: Character, source: Int?)] = []
        for i in 0..<p { out.append((k[i], i)) }
        for (n, c) in lm.enumerated() { out.append((c, n < km.count ? p + n : nil)) }
        for i in (k.count - s)..<k.count { out.append((k[i], i)) }
        return out
    }

    private static func mergeLetterByLetter(_ k: [Character], _ l: [Character], midWord: Bool = false, inName: Bool = false)
        -> [(character: Character, source: Int?)]? {
        var out: [(character: Character, source: Int?)] = []
        var i = 0, j = 0
        var refined = false
        var digitFixes = 0
        func isBracket(_ c: Character) -> Bool { c == "[" || c == "]" }
        func base(_ c: Character) -> Character? {
            guard !c.isASCII, script(c) == .latin,
                  let first = String(c).decomposedStringWithCanonicalMapping.unicodeScalars.first else { return nil }
            return Character(first)
        }
        var letterToDigit = 0
        while j < l.count {
            let lc = l[j]
            guard i < k.count else {
                // A comma or full stop at the end of a word, too faint for the Korean model, or
                // the bracket that closes a link, which it skips where the colour changes
                // behind it ("of Will] yet?").
                if j == l.count - 1, lc == "," || lc == "." || lc == "]", let last = out.last, last.character.isLetter || last.character.isNumber {
                    out.append((lc, nil)); j += 1
                    refined = true
                    continue
                }
                return nil
            }
            let kc = k[i]
            if kc == lc {
                out.append((kc, i)); i += 1; j += 1
            } else if lc == "]", kc == ":", j + 1 < l.count, l[j + 1] == ":", let last = out.last, last.character.isLetter {
                // "[Some Namel: text" where the "l" is the name's own and the bracket behind it
                // was not read at all.
                out.append((lc, nil)); j += 1
                refined = true
            } else if lc == "]", j == l.count - 1 || l[j + 1] == ":", "il1I".contains(kc), i + 2 < k.count,
                      bracketLookAlikes.contains(k[i + 1]), k[i + 2] == ":", let last = out.last, last.character.isLowercase {
                // "[Some Namil:" against "[Some Nam]:": two thin strokes where the other model
                // has only the bracket. A dotted "i" it would have read; what it ran into its
                // bracket is an "l", and the second stroke is the bracket.
                out.append(("l", i)); out.append((lc, i + 1)); i += 2; j += 1
                refined = true
            } else if lc == "]", j + 1 < l.count, l[j + 1] == ":", kc.isLetter, i + 1 < k.count, k[i + 1] == ":",
                      let last = out.last, last.character.isLetter {
                // "[Some Nameg:": the bracket in front of the speaker colon read as a letter
                // that is no thin one. (Were the letter the name's own, the other model would
                // have it in front of its bracket.)
                out.append((lc, i)); i += 1; j += 1
                refined = true
            } else if j == i, j == 0 || (j == 1 && l[0] == "["), !midWord, lc.isUppercase, l.count == k.count + 1,
                      l[j + 1] == kc, kc.isLowercase {
                // The capital a word begins with, run into the small letter behind it ("orvik"
                // for "Jorvik", "[ora" for "[Jora": the Korean model does that to a thin capital).
                out.append((lc, nil)); j += 1
                refined = true
            } else if lc == "[", j == 0, l.count > 1, l[1] == kc, kc.isLetter {
                // The bracket that opens a name, not read at all.
                out.append((lc, nil)); j += 1
                refined = true
            } else if isBracket(lc), bracketLookAlikes.contains(kc) || isBracket(kc) {
                out.append((lc, i)); i += 1; j += 1
                refined = true
                // "]["  where the Korean model saw one stroke.
                if j < l.count, isBracket(l[j]), !(i < k.count && (bracketLookAlikes.contains(k[i]) || isBracket(k[i]))) {
                    out.append((l[j], nil)); j += 1
                }
            } else if kc.isNumber, lc.isLetter, digitTwins[kc]?.contains(lc) == true {
                out.append((lc, i)); i += 1; j += 1
                refined = true
                digitFixes += 1
            } else if lc.isNumber, kc.isLetter, digitTwins[lc]?.contains(kc) == true {
                // The other way round, in a code ("LFZM" for "LF2M"); checked below.
                out.append((lc, i)); i += 1; j += 1
                refined = true
                letterToDigit += 1
            } else if (kc == "." || kc == ","), lc == "." || lc == "," {
                out.append((lc, i)); i += 1; j += 1
                refined = true
            } else if "liIj".contains(lc), j + 1 < l.count, l[j + 1] == kc, kc.isLetter, j > 0 {
                // A thin letter inside a word that the Korean model ran into its neighbour
                // ("Syvanas" for "Sylvanas").
                out.append((lc, nil)); j += 1
                refined = true
            } else if let b = base(lc), b == kc || String(b).lowercased() == String(kc).lowercased() {
                out.append((lc, i)); i += 1; j += 1
                refined = true
            } else if "lI|1".contains(kc),
                      (lc == "I" && (j == 0 || !l[j - 1].isLetter || l[j - 1].isUppercase))
                        || (lc == "l" && ((j > 0 && l[j - 1].isLowercase) || (j + 1 < l.count && l[j + 1].isLowercase))) {
                // "l" for "I" and the other way round, where the word around it tells which.
                out.append((lc, i)); i += 1; j += 1
                refined = true
            } else if lc == "\u{131}", "ilI|1".contains(kc) {
                // A dotless i from the Latin model: a thin stroke with no dot over it.
                out.append(("l", i)); i += 1; j += 1
                refined = true
            } else if String(kc).lowercased() == String(lc).lowercased() {
                // Case alone. Letters drawn alike small and large ("w", "s", "o") the Korean
                // model tells apart by size only, and gets wrong: the Latin model's case is
                // taken for those. For any other letter neither is the better judge.
                // (Not where it makes a word no one writes: "ROwan".)
                let oddCapital = lc.isUppercase && j > 0 && l[j - 1].isUppercase && j + 1 < l.count && l[j + 1].isLowercase
                // The capital "J" a name begins with is another such letter to the Korean
                // model, which also writes "j" for a bracket ("jorvikj:" for "Jorvik]:").
                let leadingJ = inName && kc == "j" && lc == "J" && !midWord && (j == 0 || !l[j - 1].isLetter)
                    && j + 1 < l.count && l[j + 1].isLowercase
                if "cosuvwxz".contains(String(kc).lowercased()) || leadingJ, !oddCapital {
                    out.append((lc, i))
                    refined = true
                } else {
                    out.append((kc, i))
                }
                i += 1; j += 1
            } else if lc == "|", "lI1!ij".contains(kc) {
                // The Latin model's own mark for a stroke it could not name.
                out.append((kc, i)); i += 1; j += 1
            } else if lc == "¿" || lc == "¡" {
                // The Korean model has no such mark: it drops it or writes a letter for it.
                if j + 1 < l.count, l[j + 1] == kc || kc.isPunctuation {
                    out.append((lc, nil)); j += 1
                    if kc.isPunctuation, !(j < l.count && l[j] == kc) { i += 1 }
                } else {
                    out.append((lc, i)); i += 1; j += 1
                }
                refined = true
            } else {
                return nil
            }
        }
        // The speaker colon, which the other model lost behind the bracket it did read.
        if i == k.count - 1, k[i] == ":", refined, out.last?.character == "]" { out.append((":", i)); i += 1 }
        guard i == k.count, refined else { return nil }
        if letterToDigit > 0 {
            // Only a word that comes out as a code of capitals around a digit or two.
            let word = String(out.map(\.character)).trimmingCharacters(in: .punctuationCharacters)
            guard word.range(of: #"^[A-Z]{1,5}[0-9]{1,2}[A-Z]{0,3}$"#, options: .regularExpression) != nil else { return nil }
        }
        if digitFixes > 0 {
            // Digits become letters only in a word that looks misread, and only when the word
            // that comes out has no digit left.
            let core = Array(String(k).trimmingCharacters(in: .punctuationCharacters))
            guard isDigitMisreadCandidate(core), !out.contains(where: { $0.character.isNumber }) else { return nil }
        }
        return out
    }

    /// The Korean reading with the words the Latin model knows better (see `mergeEquivalent`).
    /// Words are paired by where they stand; a word of the Latin reading that covers Hangul, or
    /// that has letters of another script in it, is ignored.
    public static func refine(_ korean: [OCRGlyph], with other: [OCRGlyph], height: CGFloat) -> [OCRGlyph] {
        compare(korean, with: other, height: height).refined
    }

    /// What `compare` found: the refined reading, how many words of Latin letters the two
    /// models both read, and how many of those they read differently in a way that is no
    /// misreading of a known kind.
    struct Comparison {
        var refined: [OCRGlyph]
        var differing = 0
        var compared = 0
    }

    /// `refine`, and how many words of the Latin reading stand where the Korean model read
    /// another word of Latin letters and digits that is no misreading of a known kind.
    static func compare(_ korean: [OCRGlyph], with other: [OCRGlyph], height: CGFloat) -> Comparison {
        guard !korean.isEmpty, !other.isEmpty else { return Comparison(refined: korean) }
        var differing = 0, compared = 0
        let latin = foldLookAlikes(other)
        // The boxes the Latin model gives its words reach half a space past them on either
        // side: a glyph belongs to the word its centre lies in.
        let tolerance: CGFloat = 0
        // Where each glyph of the Korean reading stands. A glyph the model gave no box of its
        // own (it then carries the extent of the whole row) stands between its neighbours.
        var centres = korean.map { ($0.minX + $0.maxX) / 2 }
        let placed = korean.map { $0.maxX - $0.minX <= 3 * height }
        for i in korean.indices where !placed[i] {
            let before = korean[..<i].indices.last { placed[$0] }.map { korean[$0].maxX }
            let after = korean[(i + 1)...].indices.first { placed[$0] }.map { korean[$0].minX }
            centres[i] = ((before ?? after ?? centres[i]) + (after ?? before ?? centres[i])) / 2
        }
        // Where the header of the row ends, when it has one.
        let nameEnd = speakerColon(korean)
        // Replacements by range of `korean`, applied back to front.
        var edits: [(range: Range<Int>, glyphs: [OCRGlyph])] = []
        var cursor = 0
        for word in words(latin) {
            let w = latin[word]
            guard !w.contains(where: { let s = script($0.character); return s != .latin && s != .other }) else { continue }
            let minX = w.map(\.minX).min() ?? 0, maxX = w.map(\.maxX).max() ?? 0
            guard maxX > minX else { continue }
            var lo: Int?, hi: Int?
            for i in cursor..<korean.count {
                let a = centres[i]
                if a < minX - tolerance { continue }
                if a > maxX + tolerance { break }
                if lo == nil { lo = i }
                hi = i
            }
            guard let lo, let hi else { continue }
            var range = lo..<(hi + 1)
            // The first letter of the Korean model's word may stand a pixel or two outside
            // the other model's box ("J" + "orvikl:" against "Jorvik]:"). When the two words are
            // one word with that letter, it belongs to the pair; in no case is it a letter the
            // Korean model lost, to be written a second time.
            let midWord = lo > cursor && !korean[lo].spaceBefore && korean[lo - 1].character.isLetter
            if midWord {
                var start = lo
                while start > cursor, !korean[start].spaceBefore, korean[start - 1].character.isLetter { start -= 1 }
                let wider = Array(korean[start..<(hi + 1)]).map(\.character)
                let other = w.map(\.character)
                if wider == other || mergeEquivalent(wider, other) != nil { range = start..<(hi + 1) }
            }
            cursor = hi + 1
            let k = Array(korean[range])
            guard !k.contains(where: { let s = script($0.character); return s == .hangul || s == .han || s == .kana }) else { continue }
            if w.filter({ script($0.character) == .latin }).count >= 2 { compared += 1 }
            if k.map(\.character) == w.map(\.character) { continue }
            guard let merged = mergeEquivalent(k.map(\.character), w.map(\.character), midWord: midWord && range.lowerBound == lo,
                                               inName: nameEnd.map { range.lowerBound < $0 } ?? false) else {
                differing += 1
                continue
            }
            var glyphs: [OCRGlyph] = []
            for (n, m) in merged.enumerated() {
                if let source = m.source {
                    var g = k[source]
                    g.character = m.character
                    glyphs.append(g)
                } else {
                    let x = glyphs.last?.maxX ?? k[min(n, k.count - 1)].minX
                    glyphs.append(OCRGlyph(character: m.character, minX: x, maxX: x, spaceBefore: false))
                }
            }
            if let first = glyphs.indices.first {
                // A letter written in front of the word takes over the space in front of it.
                if merged[0].source == nil, let moved = merged.firstIndex(where: { $0.source == 0 }) { glyphs[moved].spaceBefore = false }
                glyphs[first].spaceBefore = k[0].spaceBefore
            }
            edits.append((range, glyphs))
        }
        guard !edits.isEmpty else { return Comparison(refined: korean, differing: differing, compared: compared) }
        var out = korean
        for edit in edits.reversed() { out.replaceSubrange(edit.range, with: edit.glyphs) }
        return Comparison(refined: out, differing: differing, compared: compared)
    }

    // MARK: - Splicing two readings of a row

    /// Keeps the trusted Korean parts of `korean` and takes everything else from `other`.
    ///
    /// The two readings are aligned on the bracket or colon that ends a trusted part when both
    /// models saw it (their boxes for the same glyph overlap), and by x position otherwise.
    public static func splice(korean k: [OCRGlyph], other o: [OCRGlyph], height: CGFloat) -> [OCRGlyph] {
        let kept = trustedKoreanRanges(k)
        guard !kept.isEmpty, !o.isEmpty else { return o }

        // Kept small: glyph boxes are often those of the whole word, so the bracket that closes
        // the NEXT word ("[길드] [Иван]") starts only a space away from the mark looked for, and
        // taking it for the twin drops the speaker's name.
        let tolerance = height * 0.15

        /// Index in `o` (at or after `from`) of the glyph that is the same mark as `mark`.
        func twin(of mark: OCRGlyph, from: Int) -> Int? {
            var best: Int? = nil
            var bestGap = CGFloat.greatestFiniteMagnitude
            var j = from
            while j < o.count {
                if o[j].character == mark.character {
                    let gap = max(0, max(o[j].minX - mark.maxX, mark.minX - o[j].maxX))
                    if gap <= tolerance, gap < bestGap { bestGap = gap; best = j }
                }
                j += 1
            }
            return best
        }

        var out: [OCRGlyph] = []
        var cursor = 0
        for range in kept {
            let first = k[range.lowerBound], last = k[range.upperBound - 1]
            var start: Int
            if range.lowerBound == 0 {
                start = 0
            } else if k[range.lowerBound - 1].character == "]", let j = twin(of: k[range.lowerBound - 1], from: cursor) {
                start = j + 1
            } else {
                start = o[cursor...].firstIndex { $0.anchorX >= first.minX - 1 } ?? o.count
            }
            start = max(start, cursor)

            var end: Int
            if last.character == "]" || last.character == ":", let j = twin(of: last, from: start) {
                end = j + 1
            } else {
                // The Korean model stretches a closing bracket's box over the gap that follows.
                var edge = last.maxX
                if last.character == "]" || last.character == ":" {
                    edge = min(edge, last.minX + height * 0.35)
                }
                end = o[start...].firstIndex { $0.anchorX >= edge - 1 } ?? o.count
            }
            out += o[cursor..<start]
            out += k[range]
            cursor = max(end, start)
        }
        out += o[cursor...]
        return out
    }

    /// Glyphs of a spliced line that did not come from the Korean reading.
    public static func foreignPart(of spliced: [OCRGlyph], korean: [OCRGlyph]) -> [OCRGlyph] {
        let kept = trustedKoreanRanges(korean)
        guard !kept.isEmpty else { return spliced }
        var own: [OCRGlyph] = []
        for r in kept { own += korean[r] }
        // Kept glyphs are copied verbatim, so position and character identify them.
        return spliced.filter { g in
            !own.contains { $0.character == g.character && $0.minX == g.minX && $0.maxX == g.maxX }
        }
    }

    /// True when the Latin model read the message of the row exactly as the Korean model did
    /// (the Korean tag, which it cannot read, aside): two models that agree letter for letter
    /// are as good as one that is sure.
    public static func agree(korean: [OCRGlyph], latin: [OCRGlyph], height: CGFloat) -> Bool {
        guard !korean.isEmpty, !latin.isEmpty, count(untrustedPart(of: korean), .latin) >= 2 else { return false }
        let spliced = splice(korean: korean, other: foldLookAlikes(latin), height: height)
        return spliced.map(\.character) == korean.map(\.character)
    }

    // MARK: - The choice between the Korean and the Latin/Cyrillic reading of a row

    public enum LatinChoice: Equatable {
        /// The Korean reading stands, with the words the Latin model knew better.
        case korean([OCRGlyph])
        /// Cyrillic text: the row as spliced from the Korean tag and the Latin model's message.
        case cyrillic([OCRGlyph], confidence: Double)
        /// Latin text the Korean model could not read: used unless the row turns out to be
        /// Chinese or Japanese.
        case latinFallback([OCRGlyph], confidence: Double)
        /// Neither reading can be believed (the Korean model saw nothing, and the other one
        /// wrote something that is no text of any script it reads).
        case unreadable
    }

    /// Whether the Hangul the Korean model wrote into the message of a row it was unsure of is
    /// Latin text read wrong: the Latin model, sure of itself, reads the same stretch as
    /// several plain words. For real Hangul it writes digits, bars and stray letters there.
    static func hangulIsMisreadLatin(korean k: [OCRGlyph], latin l: [OCRGlyph], latinConfidence: Double, height: CGFloat) -> Bool {
        guard latinConfidence >= sure else { return false }
        let trusted = trustedKoreanRanges(k)
        let hangul = k.indices.filter { i in script(k[i].character) == .hangul && !trusted.contains { $0.contains(i) } }
        guard let first = hangul.first, let last = hangul.last else { return false }
        let from = k[first].minX - height * 0.2, to = k[last].maxX + height * 0.2
        var clean = 0, letters = 0
        for range in words(l) {
            let w = l[range]
            let mid = ((w.map(\.minX).min() ?? 0) + (w.map(\.maxX).max() ?? 0)) / 2
            guard mid >= from, mid <= to else { continue }
            let core = String(w.map(\.character)).trimmingCharacters(in: .punctuationCharacters)
            guard !core.isEmpty else { continue }
            // One word that is not plain letters and the stretch is no Latin text.
            guard core.count >= 2, core.allSatisfy({ script($0) == .latin || $0 == "'" || $0 == "’" || $0 == "-" }) else { return false }
            clean += 1
            letters += core.count
        }
        return clean >= 3 && letters >= 10
    }

    /// Whether a reading is a row of chat as it stands: a header that parses, or plain words,
    /// with brackets that pair up and nothing in it that is debris.
    public static func readsAsChat(_ glyphs: [OCRGlyph], locale: ClientLocale = .koKR) -> Bool {
        let mended = mendSpeakerBracket(glyphs)
        guard bracketsBalanced(mended) else { return false }
        let text = self.text(mended)
        let parsed = ChatLineParser.parse(text, locale: locale)
        if parsed.isDamagedHeader { return false }
        if parsed.hasPrefix, parsed.sender == nil { return false }
        let said = parsed.hasPrefix ? parsed.body : text
        return !LanguageGate.isUnreadable(said) && said.filter(\.isLetter).count >= 2
    }

    /// Decides what a row is, given the Korean model's reading of it and the Latin/Cyrillic
    /// model's (rules 3 to 5 of `ScriptChoice`). `korean` may be empty: a row the Korean model
    /// skipped. A Korean reading that is a row of chat as it stands (`readsAsChat`) is kept
    /// even when the model was unsure of it, unless the other model, sure of itself, read
    /// several of its words differently.
    public static func chooseLatin(korean: [OCRGlyph], koreanConfidence: Double, latin: [OCRGlyph], latinConfidence: Double,
                                   height: CGFloat) -> LatinChoice {
        let soundKorean: ([OCRGlyph]) -> Bool = { readsAsChat($0) }
        guard !latin.isEmpty else { return korean.isEmpty ? .unreadable : .korean(korean) }
        let spliced = korean.isEmpty ? latin : splice(korean: korean, other: latin, height: height)
        let foreign = foreignPart(of: spliced, korean: korean)
        let body = koreanBody(of: korean)
        let koreanShaped = isShapedLikeKorean(body)

        // Cyrillic is text only as whole words, on a row the Korean model could not read and
        // saw no Korean in. The Latin model writes Cyrillic letters for anything it cannot read.
        let cyrillic = count(foreign, .cyrillic)
        if cyrillic >= 2, cyrillic * 4 >= count(foreign, .latin), koreanConfidence < sure, !koreanShaped {
            let words = scriptWords(foreign)
            if words.cyrillic >= 1, words.cyrillic >= 3 * words.mixed {
                return .cyrillic(spliced, confidence: latinConfidence)
            }
        }
        guard !korean.isEmpty else {
            let folded = foldLookAlikes(latin)
            guard count(folded, .cyrillic, .greek) == 0 else { return .unreadable }
            if latinConfidence >= sure, count(folded, .latin) >= 3, bracketsBalanced(folded) {
                return .latinFallback(folded, confidence: latinConfidence)
            }
            return .unreadable
        }

        let comparison = compare(korean, with: latin, height: height)
        let refined = comparison.refined, differing = comparison.differing
        if koreanConfidence >= sure { return .korean(refined) }

        // Unsure of the row. Hangul in the message is something only this model can have read,
        // unless the other one reads plain words in its place.
        let hasHangul = count(untrustedPart(of: korean), .hangul) > 0
        if hasHangul, !hangulIsMisreadLatin(korean: korean, latin: latin, latinConfidence: latinConfidence, height: height) {
            return .korean(refined)
        }
        // A Latin reading replaces the Korean one only if it is sure of itself, is Latin
        // through and through and does not drop part of the row.
        let folded = splice(korean: korean, other: foldLookAlikes(latin), height: height)
        let taken = foreignPart(of: folded, korean: korean)
        // Plain letters the Korean model reads as well as the other one, and its reading is
        // the one every other row of the chat comes from: it stays when it is a row of chat as
        // it stands. Accented letters it cannot write at all (Spanish, Portuguese, French,
        // German): such a row is the Latin model's, like a Cyrillic one.
        let accented = taken.contains { !$0.character.isASCII && script($0.character) == .latin }
        // One word read differently is one model's slip, and nothing says whose. Several, or
        // the only word there is ("eood" on a wrapped row that reads "good"), are the model
        // that was unsure of the row struggling with it.
        let struggling = latinConfidence >= sure && (differing >= 2 || (differing == 1 && comparison.compared == 1))
        if !hasHangul, !accented, !struggling, soundKorean(refined) { return .korean(refined) }
        let complete = folded.count * 10 >= korean.count * 9
        if latinConfidence >= sure, count(taken, .latin) >= 3, count(taken, .cyrillic, .greek) == 0,
           complete, bracketsBalanced(folded) {
            return .latinFallback(folded, confidence: min(latinConfidence, hasHangul ? koreanConfidence : latinConfidence))
        }
        return .korean(refined)
    }
}
