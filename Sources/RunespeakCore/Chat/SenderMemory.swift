import Foundation

/// Remembers how speaker names were read, to mend the commonest OCR slip on them: the thin
/// glyphs next to a bracket. "[Thrall]" comes out now and then as "Thral", "Thralll" (the
/// bracket read as a letter) or "[aina]" for "[Jaina]". A name is replaced only by a reading
/// that was seen more often and differs by one such glyph or by letter case.
struct SenderMemory {
    private var counts: [String: Int] = [:]
    private static let capacity = 600

    /// Glyphs OCR confuses with each other and with "[" / "]".
    private static let thin: Set<Character> = ["l", "I", "1", "|", "i", "j", "J", "t", "!"]

    mutating func reset() { counts.removeAll() }

    /// Records the reading and returns the name to use for it.
    mutating func resolve(_ name: String) -> String {
        let own = counts[name] ?? 0
        var best: (name: String, count: Int)?
        if SenderMemory.isLatin(name) {
            // The thin capital that begins a later word of a name is dropped by OCR now and
            // then and never made up, and what is left is a name nobody has: "Some ames" is
            // "Some James" as soon as that reading is known, however often it was seen, and
            // "Some James" is never taken for "Some ames". (Two names that are both names,
            // "Kai" and "Kali", go by how often each was seen like any other pair.)
            if let whole = counts.keys.filter({ SenderMemory.lacksWordInitial(name, of: $0) }).max(by: { counts[$0]! < counts[$1]! }) {
                counts[name] = own + 1
                return whole
            }
            for (known, count) in counts where count > own && count > (best?.count ?? 0) && known != name {
                if SenderMemory.lacksWordInitial(known, of: name) { continue }
                if SenderMemory.confusable(name, known) { best = (known, count) }
            }
        }
        counts[name] = own + 1
        if counts.count > SenderMemory.capacity {
            // Names seen once are the cheapest to forget.
            counts = counts.filter { $0.value > 1 }
        }
        return best?.name ?? name
    }

    private static func isLatin(_ name: String) -> Bool {
        name.count >= 3 && name.unicodeScalars.allSatisfy { $0.value < 0x250 }
    }

    /// Round letters OCR takes for each other in a name, mostly under an accent it cannot
    /// write ("Mǒrn" comes out as "Morn" and as "Mdrn", "Nadric" as "Nacric"). One of the two
    /// must be a consonant: two names that differ in a vowel are as often two people.
    private static let round: Set<Character> = ["a", "c", "d", "o"]
    private static let roundConsonants: Set<Character> = ["c", "d"]

    /// True when `short` is `whole` without the thin capital that begins one of its later
    /// words, so that the word begins with a small letter in `short`. Not the first glyph of
    /// the name or its last, where a bracket read as a letter can add one, and not a letter
    /// inside a word: with or without that one both readings are names somebody can have.
    static func lacksWordInitial(_ short: String, of whole: String) -> Bool {
        let s = Array(short), w = Array(whole)
        guard w.count == s.count + 1, s.count >= 3 else { return false }
        var i = 0
        while i < s.count, s[i] == w[i] { i += 1 }
        guard i > 0, i < w.count - 1, thin.contains(w[i]), w[i].isUppercase, w[i - 1] == " " || w[i - 1] == "-",
              s[i].isLowercase else { return false }
        return Array(w[(i + 1)...]) == Array(s[i...])
    }

    static func confusable(_ a: String, _ b: String) -> Bool {
        if a.lowercased() == b.lowercased() { return true }
        let x = Array(a), y = Array(b)
        if x.count == y.count {
            var differing: (Character, Character)?
            for (p, q) in zip(x, y) where p != q {
                if differing != nil { return false }
                differing = (p, q)
            }
            guard let (p, q) = differing else { return false }
            if thin.contains(p) && thin.contains(q) { return true }
            // One round letter for another, in a name long enough not to be someone else's.
            return x.count >= 8 && round.contains(p) && round.contains(q) && (roundConsonants.contains(p) || roundConsonants.contains(q))
        }
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        guard long.count == short.count + 1 else { return false }
        // The one extra glyph of the longer reading has to be a thin one.
        var i = 0
        while i < short.count, long[i] == short[i] { i += 1 }
        guard thin.contains(long[i]) || (i > 0 && long[i] == long[i - 1] && thin.contains(long[i])) else { return false }
        return Array(long[(i + 1)...]) == Array(short[i...])
    }
}
