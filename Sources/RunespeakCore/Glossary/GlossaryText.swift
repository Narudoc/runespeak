import Foundation

/// Script family of one normalised unit. Decides where a dictionary key may start and end:
/// `word`/`digit` scripts are written with spaces, so keys must sit on token boundaries;
/// Hangul takes particles glued to the end of a name; `cjk` scripts have no word boundaries at all.
enum GlossaryScript: UInt8, Sendable {
    case word      // Latin, Cyrillic, Greek ... (alphabetic, space separated)
    case digit
    case hangul
    case cjk       // Han, kana, Thai
}

/// A text reduced to the units dictionary keys are made of: letters and digits only, case/width/
/// diacritics folded, with spacing and punctuation remembered only as "there was a gap here".
/// Dictionary keys and chat text go through the same reduction, so "Dire Maul", "diremaul" and
/// "DIRE  MAUL" all become the key "diremaul".
struct GlossaryUnits: Sendable {
    /// Folded scalars, separators removed.
    var scalars: [Unicode.Scalar] = []
    var scripts: [GlossaryScript] = []
    /// True when a separator (space, punctuation) stood between this unit and the previous one.
    var gapBefore: [Bool] = []
    /// 1 = written upper-case, 2 = written lower-case, 0 = caseless.
    var caseFlag: [UInt8] = []
    /// Index of the source scalar in `raw`.
    var rawIndex: [Int32] = []
    /// Source scalars, ASCII lower-cased and full-width forms narrowed (for literal checks like "8/8").
    var raw: [Unicode.Scalar] = []

    var count: Int { scalars.count }

    init(_ text: String, keepRaw: Bool = true) {
        let source = GlossaryUnits.isPlainASCII(text) ? text : text.precomposedStringWithCanonicalMapping
        let estimated = source.utf8.count
        scalars.reserveCapacity(estimated)
        scripts.reserveCapacity(estimated)
        gapBefore.reserveCapacity(estimated)
        caseFlag.reserveCapacity(estimated)
        rawIndex.reserveCapacity(estimated)
        if keepRaw { raw.reserveCapacity(estimated) }

        var pendingGap = true
        var index: Int32 = 0
        for original in source.unicodeScalars {
            var sc = original
            var v = sc.value
            // Full-width ASCII block → ASCII, ideographic space → space.
            if v >= 0xFF01 && v <= 0xFF5E, let narrow = Unicode.Scalar(v - 0xFEE0) {
                sc = narrow; v = sc.value
            }
            defer { index += 1 }

            if v < 0x80 {
                if v >= 0x61 && v <= 0x7A {
                    if keepRaw { raw.append(sc) }
                    append(sc, .word, 2, &pendingGap, index)
                } else if v >= 0x41 && v <= 0x5A {
                    let lower = Unicode.Scalar(UInt8(v | 0x20))
                    if keepRaw { raw.append(lower) }
                    append(lower, .word, 1, &pendingGap, index)
                } else if v >= 0x30 && v <= 0x39 {
                    if keepRaw { raw.append(sc) }
                    append(sc, .digit, 0, &pendingGap, index)
                } else {
                    if keepRaw { raw.append(sc) }
                    // Apostrophes vanish inside words: Un'Goro = Ungoro, Onyxia's = Onyxias.
                    if v != 0x27 && v != 0x60 { pendingGap = true }
                }
                continue
            }

            if keepRaw { raw.append(sc) }

            if (v >= 0xAC00 && v <= 0xD7A3) || (v >= 0x3131 && v <= 0x318E) || (v >= 0x1100 && v <= 0x11FF) {
                append(sc, .hangul, 0, &pendingGap, index)
                continue
            }
            if GlossaryUnits.isSpaceless(v) {
                append(sc, .cjk, 0, &pendingGap, index)
                continue
            }
            // Typographic apostrophes behave like the ASCII one.
            if v == 0x2019 || v == 0x2018 || v == 0x02BC || v == 0x00B4 { continue }

            let props = sc.properties
            switch props.generalCategory {
            case .nonspacingMark, .enclosingMark, .format:
                continue   // combining accents, zero-width joiners: neither a unit nor a gap
            default:
                break
            }
            if props.isAlphabetic {
                let flag: UInt8 = props.isUppercase ? 1 : (props.isLowercase ? 2 : 0)
                let folded = String(sc).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                var emitted = false
                for f in folded.unicodeScalars where f.properties.isAlphabetic {
                    append(f, GlossaryUnits.isSpaceless(f.value) ? .cjk : .word, flag, &pendingGap, index)
                    emitted = true
                }
                if !emitted { pendingGap = true }
            } else if props.numericType != nil {
                append(sc, .digit, 0, &pendingGap, index)
            } else {
                pendingGap = true
            }
        }
    }

    private mutating func append(_ sc: Unicode.Scalar, _ script: GlossaryScript, _ flag: UInt8,
                                 _ pendingGap: inout Bool, _ index: Int32) {
        scalars.append(sc)
        scripts.append(script)
        gapBefore.append(pendingGap)
        caseFlag.append(flag)
        rawIndex.append(index)
        pendingGap = false
    }

    private static func isPlainASCII(_ text: String) -> Bool {
        for byte in text.utf8 where byte >= 0x80 { return false }
        return true
    }

    /// Scripts written without spaces between words.
    static func isSpaceless(_ v: UInt32) -> Bool {
        (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF) || (v >= 0xF900 && v <= 0xFAFF)
            || (v >= 0x3040 && v <= 0x30FF) || (v >= 0x31F0 && v <= 0x31FF) || (v >= 0xFF66 && v <= 0xFF9F)
            || (v >= 0x0E00 && v <= 0x0E7F) || (v >= 0x20000 && v <= 0x2FA1F)
    }

    /// A position where a space-separated word starts or ends. Letter↔digit and script changes
    /// count too, so "2dps", "55레벨" and "收个DM" expose their inner words.
    func isBoundary(_ i: Int) -> Bool {
        if i <= 0 || i >= scalars.count { return true }
        return gapBefore[i] || scripts[i - 1] != scripts[i]
    }

    /// A real separator (or text edge) at `i`, not merely a script change.
    func isHardBoundary(_ i: Int) -> Bool {
        if i <= 0 || i >= scalars.count { return true }
        return gapBefore[i]
    }

    func key(_ range: Range<Int>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[range])
        return String(view)
    }

    /// The whole text as one key.
    var fullKey: String { key(0..<scalars.count) }

    /// Bit i set when unit i of the range was written upper-case (first 64 units).
    func caseSignature(_ range: Range<Int>) -> UInt64 {
        var sig: UInt64 = 0
        var bit: UInt64 = 1
        for i in range.prefix(64) {
            if caseFlag[i] == 1 { sig |= bit }
            bit <<= 1
        }
        return sig
    }

    func hasLowercase(_ range: Range<Int>) -> Bool {
        for i in range where caseFlag[i] == 2 { return true }
        return false
    }

    func hasUppercase(_ range: Range<Int>) -> Bool {
        for i in range where caseFlag[i] == 1 { return true }
        return false
    }

    /// Number of space/script separated tokens.
    var tokenCount: Int {
        var n = 0
        for i in 0..<scalars.count where isBoundary(i) { n += 1 }
        return n
    }

    /// Keys of the individual tokens.
    var tokens: [String] {
        var out: [String] = []
        guard !scalars.isEmpty else { return out }
        var start = 0
        for i in 1...scalars.count where isBoundary(i) {
            out.append(key(start..<i))
            start = i
        }
        return out
    }
}
