import Foundation

extension LanguageGate {

    /// Whether `text` (a chat body) is worth sending to the translator for this reader.
    public static func needsTranslation(_ text: String, reader: ReaderLanguage) -> Bool {
        let counts = ScriptCounts(stripNoise(text))
        switch reader {
        case .korean: return koreanReaderNeeds(counts)
        case .english: return englishReaderNeeds(counts)
        }
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
                    }
                } else {
                    depthSquare += 1
                }
            case "]", "］", "】":
                if depthSquare > 0 {
                    depthSquare -= 1
                    if depthSquare == 0 { out.append(" ") }
                } else {
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
