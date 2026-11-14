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
            for (known, count) in counts where count > own && count > (best?.count ?? 0) && known != name {
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
            return thin.contains(p) && thin.contains(q)
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
