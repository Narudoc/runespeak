import Foundation

// Fuzzy comparison of OCR'd screen lines. Two reads of the same on-screen line differ by
// confusable glyphs, dropped punctuation and spacing, so lines are compared on a "skeleton":
// lowercased, punctuation/space-free, Hangul decomposed to jamo, look-alike glyphs folded.

enum TextFold {
    /// Comparison skeleton of `text` as Unicode scalar values.
    static func skeleton<S: StringProtocol>(_ text: S) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(text.utf8.count)
        // NFD splits Hangul syllables into jamo (a misread syllable then costs one edit out of
        // three instead of a whole character) and separates accents, which are dropped below.
        for scalar in text.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            var v = scalar.value
            if v >= 0xFF01 && v <= 0xFF5E { v -= 0xFEE0 }          // full-width ASCII
            if v >= 0x41 && v <= 0x5A { v += 0x20 }                 // full-width capitals after mapping
            if v < 0x80 {
                switch v {
                case 0x30: out.append(0x6F)                         // 0 → o
                case 0x31, 0x69, 0x6C: out.append(0x6C)             // 1, i, l → l
                case 0x32...0x39, 0x61...0x7A: out.append(v)
                case 0x3F, 0x21: out.append(v)                      // "?" and "!" are whole messages in chat
                default: break
                }
            } else {
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                     .decimalNumber, .letterNumber, .otherNumber:
                    out.append(v)
                default:
                    break
                }
            }
        }
        return out
    }

    /// Skeleton that never comes out empty for visible text: a body made only of punctuation
    /// ("...", "^^") is compared on its raw characters instead.
    static func bodySkeleton<S: StringProtocol>(_ text: S) -> [UInt32] {
        let s = skeleton(text)
        if !s.isEmpty { return s }
        return text.unicodeScalars.filter { !$0.properties.isWhitespace }.map(\.value)
    }

    @inline(__always) static func isDigit(_ v: UInt32) -> Bool { v >= 0x32 && v <= 0x39 }

    /// Edit distance, or nil when it exceeds `limit`. A substitution involving a digit costs 2:
    /// "Pull in 5" / "Pull in 4" are different messages far more often than one misread digit.
    static func distance(_ a: ArraySlice<UInt32>, _ b: ArraySlice<UInt32>, limit: Int) -> Int? {
        let n = a.count, m = b.count
        if abs(n - m) > limit { return nil }
        if n == 0 { return m <= limit ? m : nil }
        if m == 0 { return n <= limit ? n : nil }
        let big = limit + 1
        var prev = [Int](repeating: big, count: m + 1)
        var cur = [Int](repeating: big, count: m + 1)
        for j in 0...min(m, limit) { prev[j] = j }
        let a0 = a.startIndex, b0 = b.startIndex
        for i in 1...n {
            let lo = max(1, i - limit), hi = min(m, i + limit)
            if lo > hi { return nil }
            cur[lo - 1] = (lo == 1 && i <= limit) ? i : big
            var rowMin = cur[lo - 1]
            let ca = a[a0 + i - 1]
            for j in lo...hi {
                let cb = b[b0 + j - 1]
                let sub: Int
                if ca == cb { sub = prev[j - 1] }
                else { sub = prev[j - 1] + ((isDigit(ca) || isDigit(cb)) ? 2 : 1) }
                let v = min(big, min(sub, min(prev[j] + 1, cur[j - 1] + 1)))
                cur[j] = v
                if v < rowMin { rowMin = v }
            }
            if hi < m { cur[hi + 1] = big }
            if rowMin > limit { return nil }
            swap(&prev, &cur)
        }
        return prev[m] <= limit ? prev[m] : nil
    }

    static func distance(_ a: [UInt32], _ b: [UInt32], limit: Int) -> Int? {
        distance(a[...], b[...], limit: limit)
    }

    /// Screen columns: wide (CJK/Hangul/full-width) glyphs take two.
    static func columns<S: StringProtocol>(_ text: S) -> Int {
        var n = 0
        for u in text.unicodeScalars {
            let v = u.value
            if isWide(v) {
                n += 2
            } else if u.properties.generalCategory == .nonspacingMark || v == 0xFE0F || v == 0x200D {
                continue
            } else {
                n += 1
            }
        }
        return n
    }

    static func isWide(_ v: UInt32) -> Bool {
        (v >= 0x1100 && v <= 0x11FF) || (v >= 0x2E80 && v <= 0xA4CF) || (v >= 0xAC00 && v <= 0xD7A3)
            || (v >= 0xF900 && v <= 0xFAFF) || (v >= 0xFF00 && v <= 0xFF60) || (v >= 0x20000 && v <= 0x3FFFF)
    }
}

/// Skeleton of one screen line (or one whole message), split into the parts that identify it:
/// the channel tag, the speaker and the body. The short, information-carrying name and body are
/// compared separately so that the long shared "[Guild] [Name]:" prefix cannot hide a difference.
struct LineKey: Hashable {
    let tag: [UInt32]
    let name: [UInt32]
    let body: [UInt32]
    /// False when no "[Channel] [Name]:" style header was recognised; everything is in `body` then.
    let hasHeader: Bool

    init(text: String, parsed: ParsedChatLine) {
        if parsed.hasPrefix {
            tag = TextFold.skeleton(parsed.headerTag)
            name = TextFold.skeleton(parsed.headerName)
            body = TextFold.bodySkeleton(parsed.body)
            hasHeader = true
        } else {
            tag = []
            name = []
            body = TextFold.bodySkeleton(text)
            hasHeader = false
        }
    }

    /// The key of a row that could not be read at all: it resembles nothing, not even the
    /// same row in another frame. `serial` tells such keys apart.
    init(unreadable serial: UInt32) {
        tag = []
        name = []
        body = [0x10FFFF, 0x10FFFE, 0x110000 &+ serial]
        hasHeader = false
    }

    var count: Int { tag.count + name.count + body.count }
    var whole: [UInt32] { tag + name + body }
}

enum LineMatch: Equatable {
    case none
    /// Plausibly the same line read badly; only used when the neighbours agree.
    case loose
    /// Same line. `quality` 0...1.
    case strict(Double)

    var isStrict: Bool { if case .strict = self { return true } else { return false } }
}

enum LineSimilarity {
    private static func strictLimit(_ n: Int) -> Int { n < 4 ? 0 : max(1, n / 5) }
    private static func looseLimit(_ n: Int) -> Int { n < 3 ? 0 : max(1, (n * 2) / 5) }

    /// Distance of one part and whether it is within the strict limit; nil when beyond loose.
    private static func part(_ a: [UInt32], _ b: [UInt32]) -> (d: Int, strict: Bool)? {
        if a == b { return (0, true) }
        let n = max(a.count, b.count)
        guard let d = TextFold.distance(a, b, limit: looseLimit(n)) else { return nil }
        return (d, d <= strictLimit(n))
    }

    static func compare(_ a: LineKey, _ b: LineKey) -> LineMatch {
        let n = max(a.count, b.count)
        if n == 0 { return .none }
        if a == b { return .strict(1) }
        if abs(a.count - b.count) > looseLimit(n) + 2 { return .none }

        // A header whose name group was lost to OCR has the name in its body: compared part by
        // part it would look like another line altogether.
        if a.hasHeader && b.hasHeader && a.name.isEmpty == b.name.isEmpty {
            guard let c = part(a.body, b.body) else { return .none }
            let longBody = min(a.body.count, b.body.count) >= 6
            let t = part(a.tag, b.tag)
            let s = part(a.name, b.name)
            if let t, let s, t.strict && s.strict && c.strict {
                return .strict(1 - Double(t.d + s.d + c.d) / Double(n))
            }
            // The channel tag is the part OCR damages most and tells lines apart least: with
            // the same speaker saying the same (non-trivial) thing, a mangled tag changes nothing.
            if let s, s.strict && c.strict && longBody {
                return .strict(max(0.5, 0.9 - Double(s.d + c.d) / Double(n)))
            }
            if t != nil && s != nil { return .loose }
            // Short names (two CJK characters) are easily half misread.
            if c.strict && longBody,
               TextFold.distance(a.name, b.name, limit: max(1, max(a.name.count, b.name.count) / 2)) != nil {
                return .loose
            }
            return .none
        }
        // One read lost its header to OCR damage: fall back to the whole line, more cautiously
        // because name and body can no longer be told apart.
        let wa = a.whole, wb = b.whole
        let loose = n < 3 ? 0 : max(1, n / 3)
        guard let d = TextFold.distance(wa, wb, limit: loose) else { return .none }
        let strict = n < 4 ? 0 : max(1, n / 6)
        return d <= strict ? .strict(1 - Double(d) / Double(n)) : .loose
    }

    /// Stricter than `compare`: whether two whole messages are one message read twice, as opposed
    /// to the same person saying something similar again.
    static func isSameMessage(_ a: LineKey, _ b: LineKey) -> Bool {
        if a == b { return true }
        guard a.hasHeader == b.hasHeader else { return false }
        func close(_ x: [UInt32], _ y: [UInt32]) -> Bool {
            let n = max(x.count, y.count)
            let limit = n < 6 ? 0 : max(1, n / 10)
            return x == y || TextFold.distance(x, y, limit: limit) != nil
        }
        return close(a.tag, b.tag) && close(a.name, b.name) && close(a.body, b.body)
    }
}
