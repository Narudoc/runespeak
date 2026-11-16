import Foundation

extension LanguageGate {

    /// Whether `text` (a chat body) is worth sending to the translator for this reader.
    public static func needsTranslation(_ text: String, reader: ReaderLanguage) -> Bool {
        let stripped = stripNoise(text)
        // What OCR makes of text it cannot read is no language: a translator can only hand it
        // back, and it would be shown as a translation.
        if isDebris(stripped) { return false }
        let counts = ScriptCounts(stripped)
        switch reader {
        case .korean: return koreanReaderNeeds(counts)
        case .english: return englishReaderNeeds(counts)
        }
    }

    /// Whether a chat message is worth sending to the translator for this reader: language the
    /// reader does not read, in a message that is whole. Rows that went out without their
    /// header row (`ChatMessage.isFragment`) are the end of a sentence without its beginning:
    /// translated alone they come out as something nobody said, so they wait for the whole
    /// message, which replaces them.
    public static func needsTranslation(_ message: ChatMessage, reader: ReaderLanguage) -> Bool {
        if message.isFragment { return false }
        return needsTranslation(message.body, reader: reader)
    }

    /// True when `text` (a chat body, or a whole row) is what OCR makes of text it cannot read
    /// rather than something a player typed: letters of several scripts inside one word
    /// ("7ЛУ", "UХЕyоu"), stroke marks ("|", "™", "»"), letters and digits in no pattern chat
    /// uses ("CE024", "E82t91"). Links are left out of the judgement. One such token among
    /// words that read as language ("| need help") does not make a line unreadable.
    public static func isUnreadable(_ text: String) -> Bool {
        isDebris(stripNoise(text))
    }

    /// True when nothing is left of `text` once its links are taken out: a row or a message
    /// made of links only, including a link whose brackets did not all survive OCR.
    public static func isOnlyLinks(_ text: String) -> Bool {
        guard text.contains("[") || text.contains("]") else { return false }
        return !stripNoise(text).contains { $0.isLetter || $0.isNumber }
    }

    enum TokenKind { case word, amount, code, neutral, junk }

    private static func scriptClass(_ u: Unicode.Scalar) -> Character {
        switch u.value {
        case 0x30...0x39: return "d"
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: return (u.value == 0xD7 || u.value == 0xF7) ? "s" : "L"
        case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3131...0x318E: return "H"
        case 0x400...0x52F: return "C"
        case 0x370...0x3FF: return "G"
        case 0x3040...0x30FF, 0x3400...0x9FFF: return "J"
        default: return u.properties.isAlphabetic ? "O" : "s"
        }
    }

    private static let units: Set<String> = [
        "g", "s", "c", "k", "x", "h", "m", "v", "gp", "sp", "cp", "ea", "st", "nd", "rd", "th", "lvl", "min", "sec", "hr",
        "dkp", "pt", "pts", "kg", "ms", "am", "pm",
    ]
    /// Marks OCR writes for strokes it cannot read; none of them is typed in chat. ("*!@#$%^&"
    /// are the game's own profanity mask and are not in this list.)
    private static let debrisMarks: Set<Character> = [
        "|", "™", "»", "«", "‡", "£", "¦", "§", "¶", "©", "®", "°", "¬", "¢", "¥", "€", "†", "₴", "•", "·", "¤",
    ]
    private static let edgeMarks: Set<Character> = [
        ".", ",", "!", "?", "~", "…", ":", ";", "'", "\"", "(", ")", "*", "^", "-", "+", "<", ">", "/", "=", "@", "#", "$", "%", "&", "_",
        "’", "‘", "“", "”", "¿", "¡",
    ]

    static func kind(ofToken token: Substring) -> TokenKind {
        var core = Substring(token)
        while let f = core.first, edgeMarks.contains(f) { core = core.dropFirst() }
        while let l = core.last, edgeMarks.contains(l) { core = core.dropLast() }
        if core.isEmpty { return token.contains(where: { debrisMarks.contains($0) }) ? .junk : .neutral }
        let hasDebris = core.contains { debrisMarks.contains($0) }
        var classes = ""
        var runs = 0
        var last: Character = " "
        for u in core.precomposedStringWithCanonicalMapping.unicodeScalars {
            if u == "'" || u == "’" || u == "-" || debrisMarks.contains(Character(u)) { continue }
            let c = scriptClass(u)
            if c != last { runs += 1; last = c }
            if !classes.contains(c) { classes.append(c) }
        }
        let letters = classes.filter { "LHCGJO".contains($0) }
        // Scripts no one mixes inside a word: Cyrillic or Greek next to Latin, digits or Hangul.
        if (classes.contains("C") || classes.contains("G")) && classes.count > 1 { return .junk }
        // Any other alphabet (Thai, Arabic, Hebrew ...) is a word on its own and debris in a mix.
        if classes.contains("O") { return letters.count > 1 || classes.contains("d") ? .junk : .word }
        if hasDebris {
            // "he||o": bars for l or I inside a Latin word. Anything else with such a mark is debris.
            let onlyBars = core.allSatisfy { !debrisMarks.contains($0) || $0 == "|" }
            return onlyBars && classes == "L" && core.filter({ $0 != "|" }).count >= 3 ? .word : .junk
        }
        if classes.contains("s") {
            if (letters.isEmpty && !classes.contains("d")) || runs <= 3 { return .neutral }
            // Typed punctuation that joins what are tokens of their own ("500g+tip", "1.5g",
            // "1h+shield", "aq20+zg20"): each part is judged by itself.
            let parts = core.split(whereSeparator: { edgeMarks.contains($0) && $0 != "'" && $0 != "’" && $0 != "-" })
            guard parts.count >= 2, parts.count <= 4 else { return .junk }
            let kinds = parts.map { kind(ofToken: $0) }
            if kinds.contains(.junk) { return .junk }
            return kinds.contains(.word) ? .word : (kinds.contains(.code) ? .code : .neutral)
        }
        if letters.isEmpty { return .amount }                                   // digits only
        if !classes.contains("d") {                                               // letters only
            if letters.count == 1 { return core.count >= 2 || letters == "H" || letters == "J" ? .word : .neutral }
            // "DPS구함", "MC가실분", "有人打MC吗": Latin terms inside Korean, Chinese or Japanese.
            return letters.allSatisfy({ "LHJ".contains($0) }) ? .word : .junk
        }
        // Letters and digits.
        let text = core.lowercased()
        if classes.contains("H") { return runs <= 3 ? .amount : .junk }           // "20렙", "3개씩", "t2셋"
        if classes.contains("J") { return runs <= 3 ? .amount : .junk }
        let digits = text.prefix { $0.isNumber }
        let tail = text.dropFirst(digits.count)
        if !digits.isEmpty, tail.allSatisfy({ $0.isLetter }), units.contains(String(tail)) { return .amount }   // "50g", "2s", "60s"
        if text.range(of: #"^(\d+[gsc])+$"#, options: .regularExpression) != nil { return .amount }       // "5g50s"
        if runs >= 4 { return .junk }                                             // "E82t91"
        // "LF2M", "t2", "5v5", "2h", "ony8", "x2": a few letters around one or two digits.
        if text.range(of: #"^[a-z]{1,5}\d{1,2}[a-z]{0,2}$|^\d{1,2}[a-z]{1,3}\d{0,2}$"#, options: .regularExpression) != nil,
           text.filter(\.isNumber).count <= 2 { return .code }
        // "2nite", "4ever", "brd5man": small letters around one digit or two, as people type
        // them. (What OCR makes of Hangul it cannot read is capitals and digits: "20N", "54Hg".)
        if runs <= 3, text.filter(\.isNumber).count <= 2, text.filter(\.isLetter).count >= 3,
           core.allSatisfy({ !$0.isLetter || $0.isLowercase }) { return .code }
        return .junk
    }

    /// `text` with links already removed. True when what is left is debris and not language.
    static func isDebris(_ text: String) -> Bool {
        var words = 0, junk = 0, wordChars = 0, junkChars = 0
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "/" }) {
            switch kind(ofToken: token) {
            case .word: words += 1; wordChars += token.count
            case .junk: junk += 1; junkChars += token.count
            default: break
            }
        }
        guard junk > 0 else { return false }
        return words == 0 || junkChars >= wordChars
    }

    // MARK: - Decisions

    private static func koreanReaderNeeds(_ c: ScriptCounts) -> Bool {
        // Scripts a Korean reader cannot be expected to read at all.
        if c.cyrillic >= 2 || c.kana >= 2 || c.otherLetters >= 2 { return true }
        if c.han >= 2 && c.han > c.hangul { return true }

        let words = c.meaningfulLatinWords
        if words.isEmpty { return false }
        if c.hangul == 0 { return true }
        // Korean sentence with a few game terms ("오늘 MC 가실분 DPS 2명") reads fine as is; a
        // foreign sentence with a Korean word or two does not.
        return words.count >= 4 && c.latin * 2 >= c.hangul * 3
    }

    private static func englishReaderNeeds(_ c: ScriptCounts) -> Bool {
        if c.hangul >= 1 || c.han >= 1 || c.kana >= 1 { return true }
        // "ㅋㅋ", "ㄱㄱ": meaningless to an English reader; a lone jamo is more likely OCR noise.
        if c.jamo >= 2 || c.cyrillic >= 2 { return true }
        return false
    }

    // MARK: - Noise removal

    /// Drops what carries no language: item/spell links, raid-target markers, URLs.
    private static func stripNoise(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var depthSquare = 0, depthCurly = 0
        // A "[" without a closing "]" on the line is not a link (OCR damage, emoticon): keep the text.
        let chars = text
        var i = chars.startIndex
        while i < chars.endIndex {
            let ch = chars[i]
            switch ch {
            case "[", "［", "【":
                if depthSquare == 0 {
                    if let close = chars[chars.index(after: i)...].firstIndex(where: { $0 == "]" || $0 == "］" || $0 == "】" }),
                       chars.distance(from: i, to: close) <= 80 {
                        depthSquare = 1
                    } else {
                        out.append(" ")
                        // "LFG[The Old Iron": a link that runs on past the end of the text. The
                        // capitalised words behind the bracket are its name.
                        var rest = chars[chars.index(after: i)...]
                        var end = rest.startIndex
                        var taken = 0
                        while let word = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
                              isLinkWord(word, first: taken == 0) {
                            end = word.endIndex
                            rest = chars[end...]
                            taken += 1
                        }
                        if taken > 0 {
                            i = end
                            continue
                        }
                    }
                } else {
                    depthSquare += 1
                }
            case "]", "］", "】":
                if depthSquare > 0 {
                    depthSquare -= 1
                    if depthSquare == 0 { out.append(" ") }
                } else {
                    // "Vow][Bring Back a Ring]": the end of a link that began before the text. The
                    // capitalised words in front of the bracket are its name. (":]" is a face.)
                    if let last = out.last, last.isLetter || last.isNumber {
                        var words = out.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                        var dropped = 0
                        while let word = words.last, isLinkWord(Substring(word), first: false),
                              dropped > 0 || word.first?.isUppercase == true {
                            words.removeLast()
                            dropped += 1
                        }
                        if dropped > 0 { out = words.joined(separator: " ") }
                    }
                    out.append(" ")
                }
            case "{":
                // {star}, {rt1}, {해골}
                if depthSquare == 0, depthCurly == 0,
                   let close = chars[i...].firstIndex(of: "}"), chars.distance(from: i, to: close) <= 12 {
                    depthCurly = 1
                } else if depthSquare == 0 {
                    out.append(" ")
                }
            case "}":
                if depthCurly > 0 { depthCurly = 0; out.append(" ") } else if depthSquare == 0 { out.append(" ") }
            default:
                if depthSquare == 0 && depthCurly == 0 { out.append(ch) }
            }
            i = chars.index(after: i)
        }
        // URLs and Discord-style handles.
        let tokens = out.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        let kept = tokens.filter { t in
            let l = t.lowercased()
            return !(l.hasPrefix("http://") || l.hasPrefix("https://") || l.hasPrefix("www.") || l.contains("://"))
        }
        return kept.joined(separator: " ")
    }

    /// A word a link's name is made of: capitalised, or one of the small words between
    /// capitalised ones ("Hand of Ragnaros").
    private static func isLinkWord(_ word: Substring, first: Bool) -> Bool {
        guard let head = word.first else { return false }
        if head.isUppercase { return true }
        if first { return false }
        return ["of", "the", "a", "an", "and", "to", "in", "for", "on", "de", "la"].contains(word.lowercased())
    }

    // MARK: - Script statistics

    struct ScriptCounts {
        var hangul = 0        // complete syllables
        var jamo = 0          // ㅋㅋ, ㄱㄱ
        var latin = 0
        var cyrillic = 0
        var han = 0
        var kana = 0
        var otherLetters = 0  // Greek, Thai, Arabic, Hebrew ...
        var latinWords: [String] = []

        init(_ text: String) {
            var word = ""
            func flush(_ word: inout String, _ words: inout [String]) {
                if !word.isEmpty { words.append(word); word = "" }
            }
            for u in text.precomposedStringWithCanonicalMapping.unicodeScalars {
                var v = u.value
                if v >= 0xFF21 && v <= 0xFF5A { v -= 0xFEE0 }   // full-width Latin
                switch v {
                case 0xAC00...0xD7A3:
                    hangul += 1; flush(&word, &latinWords)
                case 0x1100...0x11FF, 0x3131...0x318E, 0xA960...0xA97F, 0xD7B0...0xD7FF, 0xFFA0...0xFFDC:
                    jamo += 1; flush(&word, &latinWords)
                case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF:
                    if v == 0xD7 || v == 0xF7 { flush(&word, &latinWords); continue }
                    latin += 1
                    word.unicodeScalars.append(UnicodeScalar(v) ?? u)
                case 0x27, 0x2019:
                    // Apostrophes stay inside a word ("don't").
                    if word.isEmpty { continue }
                case 0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
                    cyrillic += 1; flush(&word, &latinWords)
                case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                    // The prolonged sound mark and middle dot also decorate Korean chat ("ㅋㅋー").
                    // The same goes for the handful of kana that kaomoji are drawn with: ¯\_(ツ)_/¯, ヽ(´ー`)ノ
                    if ![0x30FC, 0x30FB, 0x30A0, 0x30C4, 0x30CE, 0x30FD, 0x30FE, 0x30B7, 0x309E, 0x3063, 0x30C3].contains(v) { kana += 1 }
                    flush(&word, &latinWords)
                case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF:
                    han += 1; flush(&word, &latinWords)
                default:
                    flush(&word, &latinWords)
                    if v >= 0x370, u.properties.isAlphabetic,
                       u.properties.generalCategory != .nonspacingMark, u.properties.generalCategory != .modifierLetter {
                        otherLetters += 1
                    }
                }
            }
            flush(&word, &latinWords)
        }

        /// Latin words that are language rather than universal chat noise.
        var meaningfulLatinWords: [String] {
            latinWords.filter { w in
                let l = w.lowercased()
                if l.count < 2 { return false }
                if ScriptCounts.universal.contains(l) { return false }
                return !ScriptCounts.universal.contains(ScriptCounts.squeezed(l))
            }
        }

        /// "looool" → "lol", "hahahaha" → "haha", "ggggg" → "gg".
        static func squeezed(_ word: String) -> String {
            let chars = Array(word)
            // Collapse a repeated one- or two-letter unit ("hahaha", "kkkk", "jajaja").
            for unit in 1...2 where chars.count > unit * 2 {
                let head = Array(chars.prefix(unit))
                var ok = true
                for (n, c) in chars.enumerated() where c != head[n % unit] { ok = false; break }
                if ok { return String(head) + String(head) }
            }
            // Collapse runs of the same letter down to one ("looool" → "lol", "okkk" → "ok").
            var out: [Character] = []
            for c in chars where out.last != c { out.append(c) }
            return String(out)
        }

        // Tokens every WoW player reads without help, whatever their language.
        static let universal: Set<String> = [
            "gg", "ggs", "ggwp", "wp", "gz", "gj", "lol", "lul", "lel", "lmao", "lmfao", "rofl", "kek", "xd", "xdd",
            "ok", "okay", "k", "kk", "o7", "zz", "zzz", "hm", "hmm", "ha", "haha", "hehe", "hoho", "jaja", "kkkk",
            "oh", "ah", "uh", "eh", "ooh", "aah", "omg", "wow", "owo", "uwu", "afk", "brb", "np", "ty", "thx",
            "hi", "yo", "bb", "ez", "rip", "oof", "ugh", "meh", "yay", "ya", "ye", "no", "na", "go", "ho", "he",
        ]
    }
}
