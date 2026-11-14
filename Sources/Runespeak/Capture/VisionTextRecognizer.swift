import CoreGraphics
import Foundation
import Vision
import RunespeakCore

/// Vision OCR tuned for the WoW chat window.
///
/// Vision does not mix scripts inside one request: the FIRST recognition language selects one of
/// three models (Korean+Latin, Latin+Cyrillic, Chinese/Japanese+Latin) and the others in the list
/// are ignored. A koKR chat line such as "[길드] [Иван]: привет" therefore needs two models. The
/// shipping strategy (measured with `--ocr-selftest --grid`):
///
///  * koKR client: one Korean pass over the frame. Lines it is not sure about (foreign script) or
///    whose brackets do not balance are read again with the Latin/Cyrillic model and, if that
///    does not explain them, the Chinese/Japanese model; the Korean channel tag is kept and the
///    rest of the line is spliced in by x position.
///  * enUS client: one pass with Vision's per-line language detection (every model reads the
///    Latin channel tags) on an inverted grey picture; only rows that pass skipped are re-read.
final class VisionTextRecognizer: TextRecognizing, @unchecked Sendable {

    struct Options {
        enum Preprocess: String, CaseIterable {
            case none
            /// Grey image of max(r,g,b): every chat colour becomes equally bright.
            case maxChannel
            /// Same, inverted to dark text on a light page.
            case maxChannelInverted
        }
        /// Vision language identifiers for the first pass; nil picks the set for the client locale.
        var languages: [String]? = nil
        /// nil = per-locale default (off for koKR, on for enUS).
        var automaticallyDetectsLanguage: Bool? = nil
        var accurate = true
        /// Off by default: the language model "corrects" player names and gaming abbreviations.
        var languageCorrection = false
        /// Resample factor applied before recognition (1 = none). nil = decide per frame: text
        /// shorter than `smallTextHeight` pixels (a 1x display) is doubled, which lifts accuracy
        /// there from 89 % to 97 %; Retina captures gain nothing and are left alone.
        var upscale: CGFloat? = nil
        /// nil = per-locale default.
        var preprocess: Preprocess? = nil
        var customWords: [String] = []
        /// Re-read unsure lines with the other script models and splice the results.
        var rescue = true
        /// enUS only: also re-read lines the detection pass was unsure of (slow, no measured gain).
        var secondOpinionForUnsureLines = false

        init() {}
    }

    enum RecognitionError: Error {
        case unreadableImage
    }

    let options: Options
    // Vision's perform() blocks; keep it off the cooperative thread pool and serialised so two
    // frames never compete for the same Neural Engine session.
    private let queue = DispatchQueue(label: "runespeak.ocr", qos: .userInitiated)

    init() { options = Options() }
    init(options: Options) { self.options = options }

    static let koreanModel = ["ko-KR", "en-US"]
    static let latinCyrillicModel = ["en-US", "ru-RU", "es-ES", "pt-BR", "fr-FR", "de-DE"]
    static let chineseJapaneseModel = ["zh-Hans", "zh-Hant", "ja-JP"]

    func recognize(_ image: CGImage, clientLocale: ClientLocale) async throws -> OCRFrame {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.recognizeSync(image, clientLocale: clientLocale) })
            }
        }
    }

    /// Blocking variant (self-test, command-line tools).
    func recognizeSync(_ image: CGImage, clientLocale: ClientLocale) throws -> OCRFrame {
        let size = CGSize(width: image.width, height: image.height)
        guard image.width >= 8, image.height >= 8, let pixels = PixelBuffer(image) else {
            throw RecognitionError.unreadableImage
        }

        // Script-agnostic and a few milliseconds: tells how tall the text is and, later, which
        // rows the recogniser skipped.
        let detected = Self.detectTextBoxes(image)
        var upscale = options.upscale ?? 1
        if options.upscale == nil, !detected.isEmpty {
            let heights = detected.map(\.height).sorted()
            if heights[heights.count / 2] < Self.smallTextHeight { upscale = 2 }
        }
        let preprocess = options.preprocess ?? Self.defaultPreprocess(for: clientLocale)

        var input = image
        if upscale != 1 || preprocess != .none {
            guard var work = PixelBuffer(image, scale: upscale) else { throw RecognitionError.unreadableImage }
            switch preprocess {
            case .none: break
            case .maxChannel: work.flattenToMaxChannel(inverted: false)
            case .maxChannelInverted: work.flattenToMaxChannel(inverted: true)
            }
            guard let made = work.makeImage() else { throw RecognitionError.unreadableImage }
            input = made
        }

        // The detector separates small rows much better on the enlarged picture.
        let rows = upscale != 1 ? Self.detectTextBoxes(input).map {
            $0.applying(CGAffineTransform(scaleX: 1 / upscale, y: 1 / upscale))
        } : detected

        let handler = VNImageRequestHandler(cgImage: input, options: [:])
        let pass = Pass(handler: handler, imageSize: size, options: options)

        let languages: [String]
        let autodetect: Bool
        switch clientLocale {
        case .koKR:
            languages = options.languages ?? Self.koreanModel
            autodetect = options.automaticallyDetectsLanguage ?? false
        case .enUS:
            languages = options.languages ?? ["en-US", "ko-KR", "zh-Hans", "ja-JP", "ru-RU"]
            autodetect = options.automaticallyDetectsLanguage ?? true
        }

        var lines = Self.mergeIntoLines(try pass.run(languages: languages, autodetect: autodetect, region: nil))
        if options.rescue {
            switch clientLocale {
            case .koKR: rescueKoreanClient(&lines, detected: rows, pass: pass)
            case .enUS: rescueEnglishClient(&lines, detected: rows, pass: pass)
            }
        }

        let result = lines
            .sorted { $0.box.minY < $1.box.minY }
            .compactMap { reading -> OCRLine? in
                var line = reading
                line.glyphs = Self.tidy(line.glyphs)
                let text = line.text
                guard !text.isEmpty else { return nil }
                let color = pixels.glyphColor(in: line.bodyRects()) ?? pixels.glyphColor(in: [line.box]) ?? .white
                return OCRLine(text: text, box: line.box, color: color, confidence: line.confidence)
            }
        return OCRFrame(lines: result, imageSize: size)
    }

    // MARK: - Fingerprint

    /// Cheap hash of a heavily downsampled, coarsely quantised copy of the image. Equal fingerprints
    /// mean "nothing a reader would notice changed", so the frame can skip OCR. A new chat line
    /// scrolls every other line and always changes it.
    static func fingerprint(_ image: CGImage) -> UInt64 {
        let w = 96, h = 48
        var bytes = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: image.width)) { $0.forEach(mix) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: image.height)) { $0.forEach(mix) }
        guard drawn else { return hash }
        for b in bytes { mix(b >> 3) }
        return hash
    }

    // MARK: - Readings

    /// One glyph of a reading with its horizontal extent in image pixels. The Latin model only
    /// reports word boxes, so all glyphs of a word share one extent there.
    struct Glyph {
        var character: Character
        var minX: CGFloat
        var maxX: CGFloat
        var spaceBefore: Bool
        /// Where the glyph "starts" for deciding which side of a seam it is on. Not the centre:
        /// the Chinese model stretches a bracket's box over the space that follows it.
        var anchorX: CGFloat { minX + (maxX - minX) * 0.25 }
    }

    /// One visual text line as read by one model (or spliced from several).
    struct Reading {
        var glyphs: [Glyph]
        var box: CGRect
        var confidence: Double

        var text: String {
            var s = ""
            for (i, g) in glyphs.enumerated() {
                if g.spaceBefore, i > 0 { s.append(" ") }
                s.append(g.character)
            }
            return s
        }

        /// Pixel rects of the text outside [brackets]. Channel tags, player names and item links
        /// are bracketed and may carry class/quality colours; what is left is the message itself,
        /// which is always drawn in the channel colour.
        func bodyRects() -> [CGRect] {
            var rects: [CGRect] = []
            var depth = 0
            var run: (minX: CGFloat, maxX: CGFloat, letters: Int)? = nil
            func close() {
                if let r = run, r.letters >= 2, r.maxX - r.minX >= 3 {
                    rects.append(CGRect(x: r.minX, y: box.minY, width: r.maxX - r.minX, height: box.height))
                }
                run = nil
            }
            for g in glyphs {
                if g.character == "[" {
                    if depth == 0 { close() }
                    depth += 1
                } else if g.character == "]" {
                    depth = max(0, depth - 1)
                } else if depth == 0 {
                    let counts = g.character.isLetter || g.character.isNumber ? 1 : 0
                    if let r = run {
                        run = (min(r.minX, g.minX), max(r.maxX, g.maxX), r.letters + counts)
                    } else {
                        run = (g.minX, g.maxX, counts)
                    }
                }
            }
            close()
            return rects
        }
    }

    private struct Pass {
        let handler: VNImageRequestHandler
        let imageSize: CGSize
        let options: Options

        /// `region` is in image pixels, top-left origin.
        func run(languages: [String], autodetect: Bool, region: CGRect?) throws -> [Reading] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = options.accurate ? .accurate : .fast
            request.usesLanguageCorrection = options.languageCorrection
            request.automaticallyDetectsLanguage = autodetect
            request.recognitionLanguages = languages
            if !options.customWords.isEmpty { request.customWords = options.customWords }
            var roi = CGRect(x: 0, y: 0, width: 1, height: 1)
            if let region {
                // Vision regions are normalised with a bottom-left origin.
                roi = CGRect(x: region.minX / imageSize.width, y: 1 - region.maxY / imageSize.height,
                             width: region.width / imageSize.width, height: region.height / imageSize.height)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard !roi.isNull, roi.width > 0, roi.height > 0 else { return [] }
                request.regionOfInterest = roi
            }
            try handler.perform([request])

            // Observation boxes are normalised to the region of interest, bottom-left origin.
            func toPixels(_ n: CGRect) -> CGRect {
                let x = (roi.minX + n.minX * roi.width) * imageSize.width
                let w = n.width * roi.width * imageSize.width
                let yBottom = roi.minY + n.minY * roi.height
                let hN = n.height * roi.height
                return CGRect(x: x, y: (1 - yBottom - hN) * imageSize.height, width: w, height: hN * imageSize.height)
            }

            var out: [Reading] = []
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let box = toPixels(observation.boundingBox)
                guard box.width >= 2, box.height >= 2 else { continue }

                let string = candidate.string
                var glyphs: [Glyph] = []
                var pendingSpace = false
                var i = string.startIndex
                while i < string.endIndex {
                    let next = string.index(after: i)
                    let c = string[i]
                    if c.isWhitespace {
                        pendingSpace = true
                    } else {
                        var extent = (box.minX, box.maxX)
                        if let quad = try? candidate.boundingBox(for: i..<next) {
                            let r = toPixels(quad.boundingBox)
                            if r.width > 0 { extent = (r.minX, r.maxX) }
                        }
                        for n in VisionTextRecognizer.normalize(c) {
                            glyphs.append(Glyph(character: n, minX: extent.0, maxX: extent.1, spaceBefore: pendingSpace))
                            pendingSpace = false
                        }
                    }
                    i = next
                }
                guard !glyphs.isEmpty else { continue }
                glyphs[0].spaceBefore = false
                out.append(Reading(glyphs: glyphs, box: box, confidence: Double(candidate.confidence)))
            }
            return out
        }
    }

    // MARK: - Text helpers

    /// Vision emits full-width punctuation on lines it reads with the Chinese model; chat
    /// structure (brackets, colon) is ASCII in every client.
    static func normalize(_ c: Character) -> [Character] {
        switch c {
        case "\u{FF3B}", "\u{3010}", "\u{3014}": return ["["]
        case "\u{FF3D}", "\u{3011}", "\u{3015}": return ["]"]
        case "\u{FF1A}": return [":"]
        case "\u{FF1B}": return [";"]
        case "\u{3000}", "\u{00A0}": return []
        default:
            let composed = String(c).precomposedStringWithCanonicalMapping
            return Array(composed)
        }
    }

    /// The Chinese model sometimes reads one bracket of a pair as a CJK quote or brace. Only an
    /// unbalanced line is touched, so genuine 「quotes」 in Japanese chat survive.
    static func repairBrackets(_ glyphs: [Glyph]) -> [Glyph] {
        var out = glyphs
        var open = out.filter { $0.character == "[" }.count
        var close = out.filter { $0.character == "]" }.count
        guard open != close else { return out }
        let openLike: Set<Character> = ["\u{300C}", "\u{300E}", "\u{FF5B}", "{", "\u{3008}", "\u{300A}"]
        let closeLike: Set<Character> = ["\u{300D}", "\u{300F}", "\u{FF5D}", "}", "\u{3009}", "\u{300B}"]
        for i in out.indices {
            if open < close, openLike.contains(out[i].character) {
                out[i].character = "["; open += 1
            } else if close < open, closeLike.contains(out[i].character) {
                out[i].character = "]"; close += 1
            }
        }
        return out
    }

    /// Canonical chat punctuation, whatever model (or seam between two models) produced the
    /// line: "[tag] [name]: text".
    static func tidy(_ glyphs: [Glyph]) -> [Glyph] {
        var g = repairBrackets(glyphs)
        if g.contains(where: { let s = script($0.character); return s == .han || s == .kana }) {
            g = restoreColon(g)
        }
        guard !g.isEmpty else { return g }

        // The speaker colon: the first colon of the line unless it sits inside a clock time.
        var colon: Int? = nil
        for (i, glyph) in g.enumerated() where glyph.character == ":" {
            let digitBefore = i > 0 && g[i - 1].character.isNumber
            let digitAfter = i + 1 < g.count && g[i + 1].character.isNumber && !g[i + 1].spaceBefore
            if digitBefore && digitAfter { continue }
            colon = i
            break
        }
        if let c = colon, c > 0 {
            // Two models both reported the colon at a seam.
            while c + 1 < g.count, g[c + 1].character == ":" { g.remove(at: c + 1) }
            if g[c - 1].character == "]" { g[c].spaceBefore = false }
            if c + 1 < g.count { g[c + 1].spaceBefore = true }
        }
        // "[tag][name]" → "[tag] [name]" ahead of the message.
        let limit = colon ?? 0
        var i = 1
        while i < limit {
            if g[i].character == "[", g[i - 1].character == "]" { g[i].spaceBefore = true }
            i += 1
        }
        g[0].spaceBefore = false
        return g
    }

    enum Script { case hangul, han, kana, cyrillic, latin, other }

    static func script(_ c: Character) -> Script {
        guard let u = c.unicodeScalars.first?.value else { return .other }
        switch u {
        case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: return .hangul
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: return .han
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .kana
        case 0x0400...0x052F: return .cyrillic
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: return .latin
        default: return .other
        }
    }

    private static func count(_ glyphs: [Glyph], _ scripts: Script...) -> Int {
        glyphs.reduce(0) { $0 + (scripts.contains(script($1.character)) ? 1 : 0) }
    }

    private static func bracketsBalanced(_ glyphs: [Glyph]) -> Bool {
        var depth = 0
        for g in glyphs {
            if g.character == "[" { depth += 1 }
            if g.character == "]" { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0
    }

    // MARK: - Line assembly

    /// Vision splits a visual line where it sees a wide gap (between a channel tag and the name,
    /// around an item link, at a script change). Joins fragments sharing a baseline, left to right.
    private static func mergeIntoLines(_ fragments: [Reading]) -> [Reading] {
        let sorted = fragments.sorted { $0.box.midY < $1.box.midY }
        var rows: [[Reading]] = []
        for f in sorted {
            if let last = rows.indices.last {
                // Compare against the union of the row so a short fragment ("gg") still matches.
                let top = rows[last].map(\.box.minY).min() ?? f.box.minY
                let bottom = rows[last].map(\.box.maxY).max() ?? f.box.maxY
                let overlap = min(bottom, f.box.maxY) - max(top, f.box.minY)
                let smaller = min(bottom - top, f.box.height)
                let clashes = rows[last].contains { other in
                    let common = min(other.box.maxX, f.box.maxX) - max(other.box.minX, f.box.minX)
                    return common > min(other.box.width, f.box.width) * 0.3
                }
                if smaller > 0, overlap / smaller > 0.55, !clashes {
                    rows[last].append(f)
                    continue
                }
            }
            rows.append([f])
        }

        return rows.map { row -> Reading in
            guard row.count > 1 else { return row[0] }
            let parts = row.sorted { $0.box.minX < $1.box.minX }
            var merged = parts[0]
            var weighted = 0.0, weight = 0.0
            for (i, p) in parts.enumerated() {
                let w = Double(max(1, p.glyphs.count))
                weighted += p.confidence * w; weight += w
                guard i > 0 else { continue }
                var glyphs = p.glyphs
                glyphs[0].spaceBefore = true
                merged.glyphs += glyphs
                merged.box = merged.box.union(p.box)
            }
            merged.confidence = weighted / weight
            return merged
        }
        .sorted { $0.box.minY < $1.box.minY }
    }

    /// The reading in `candidates` that lies on the same visual line as `line`.
    private static func counterpart(of line: Reading, in candidates: [Reading]) -> Reading? {
        var best: Reading? = nil
        var bestOverlap: CGFloat = 0
        for c in candidates {
            let overlap = min(c.box.maxY, line.box.maxY) - max(c.box.minY, line.box.minY)
            if overlap > bestOverlap { bestOverlap = overlap; best = c }
        }
        guard let found = best, bestOverlap > min(found.box.height, line.box.height) * 0.5 else { return nil }
        return found
    }

    /// Smallest region covering `lines`, padded so glyph edges are not cut.
    private func unionRegion(_ lines: [Reading], imageSize: CGSize) -> CGRect {
        var u = CGRect.null
        for l in lines { u = u.union(l.box) }
        let pad = max(3, (lines.first?.box.height ?? 12) * 0.25)
        // Full width: the first pass may have missed the start or the end of a foreign-script line.
        return CGRect(x: 0, y: u.minY - pad, width: imageSize.width, height: u.height + pad * 2)
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    // MARK: - Rows the first pass missed

    /// Median detector box height (pixels) under which the frame is doubled before recognition.
    static let smallTextHeight: CGFloat = 17

    /// Measured on the synthetic set (overall character accuracy):
    ///   koKR pipeline — none 97.7 %, max-channel grey 98.8 %, inverted 96.7 % (Cyrillic suffers)
    ///   enUS pipeline — none 97.2 %, max-channel grey 98.5 %, inverted 99.1 %
    static func defaultPreprocess(for locale: ClientLocale) -> Options.Preprocess {
        locale == .enUS ? .maxChannelInverted : .maxChannel
    }

    /// Word-ish boxes from Vision's text detector, image pixels, top-left origin, top to bottom.
    private static func detectTextBoxes(_ image: CGImage) -> [CGRect] {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let found = request.results else { return [] }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return found.map { o -> CGRect in
            let n = o.boundingBox
            return CGRect(x: n.minX * w, y: (1 - n.maxY) * h, width: n.width * w, height: n.height * h)
        }.sorted { $0.midY < $1.midY }
    }

    /// Vision's text detector is script-agnostic and takes a few milliseconds; the recognisers
    /// silently drop whole lines in a script they do not know (the Korean model skips pure
    /// Cyrillic lines). Rows the detector saw but the first pass did not are added as empty
    /// readings so the rescue passes look at them.
    private func appendMissedRows(to lines: inout [Reading], detected boxes: [CGRect]) {
        var rows: [CGRect] = []
        for b in boxes {
            if let last = rows.last, min(last.maxY, b.maxY) - max(last.minY, b.minY) > min(last.height, b.height) * 0.5 {
                rows[rows.count - 1] = last.union(b)
            } else {
                rows.append(b)
            }
        }
        let typical = lines.map(\.box.height).sorted()
        let lineHeight = typical.isEmpty ? 0 : typical[typical.count / 2]
        for row in rows {
            // A chat line is much wider than tall; specks of scenery are not.
            guard row.width >= row.height * 3, row.height >= 6 else { continue }
            if lineHeight > 0, row.height > lineHeight * 1.8 || row.height < lineHeight * 0.5 { continue }
            let covered = lines.contains { l in
                min(l.box.maxY, row.maxY) - max(l.box.minY, row.minY) > min(l.box.height, row.height) * 0.4
            }
            if !covered { lines.append(Reading(glyphs: [], box: row, confidence: 0)) }
        }
    }

    // MARK: - Rescue, koKR client

    private func rescueKoreanClient(_ lines: inout [Reading], detected: [CGRect], pass: Pass) {
        appendMissedRows(to: &lines, detected: detected)
        defer { lines.removeAll { $0.glyphs.isEmpty } }

        // The Korean model answers 1.0 for text it can read (Hangul, Latin) and 0.3–0.5 for
        // Cyrillic, Han and kana — and for small or noisy Korean, which must be left alone.
        // It also drops accents, which now and then eats a bracket.
        var suspects = lines.indices.filter { i in
            let l = lines[i]
            if l.glyphs.isEmpty || !Self.bracketsBalanced(l.glyphs) { return true }
            return l.confidence < 0.9 && !Self.looksKorean(Self.untrustedPart(of: l))
        }
        guard !suspects.isEmpty else { return }

        // Latin/Cyrillic first: it is three times cheaper than the Chinese model.
        var latinFallback: [Int: Reading] = [:]
        let region = unionRegion(suspects.map { lines[$0] }, imageSize: pass.imageSize)
        if let found = try? pass.run(languages: Self.latinCyrillicModel, autodetect: false, region: region) {
            let latin = Self.mergeIntoLines(found)
            suspects.removeAll { i in
                guard let alt = Self.counterpart(of: lines[i], in: latin) else { return false }
                let original = lines[i]
                let spliced = original.glyphs.isEmpty ? alt : Self.splice(korean: original, other: alt)
                let foreign = Self.foreignPart(of: spliced, korean: original)
                let cyrillic = Self.count(foreign, .cyrillic)
                // A few Cyrillic look-alikes turn up in misread Latin; Russian fills the line.
                if cyrillic >= 2, cyrillic * 4 >= Self.count(foreign, .latin) {
                    lines[i] = spliced
                    return true
                }
                // A Latin reading may only replace the Korean one if it mends the brackets
                // without dropping part of the line.
                let complete = spliced.glyphs.count * 10 >= original.glyphs.count * 9
                if original.confidence >= 0.9 {
                    // Sent here for its brackets only.
                    if complete, Self.bracketsBalanced(spliced.glyphs) { lines[i] = spliced }
                    return true
                }
                // Hangul outside the trusted parts is something the Latin model cannot have read.
                if alt.confidence >= 0.9, Self.count(foreign, .latin) >= 3,
                   Self.count(Self.untrustedPart(of: original), .hangul) == 0,
                   complete, Self.bracketsBalanced(spliced.glyphs) {
                    latinFallback[i] = spliced
                }
                return false
            }
        }

        // The Korean model's guesses at Han and kana come back at 0.3; a noisy Latin or Korean
        // line stays at 0.5 and is not worth the slow Chinese model.
        let cjkSuspects = suspects.filter { lines[$0].glyphs.isEmpty || lines[$0].confidence < 0.45 }
        if !cjkSuspects.isEmpty {
            let rest = unionRegion(cjkSuspects.map { lines[$0] }, imageSize: pass.imageSize)
            if let found = try? pass.run(languages: Self.chineseJapaneseModel, autodetect: false, region: rest) {
                let cjk = Self.mergeIntoLines(found)
                suspects.removeAll { i in
                    guard cjkSuspects.contains(i), let alt = Self.counterpart(of: lines[i], in: cjk) else { return false }
                    let original = lines[i]
                    let spliced = original.glyphs.isEmpty ? alt : Self.splice(korean: original, other: alt)
                    let foreign = Self.foreignPart(of: spliced, korean: original)
                    let cjkCount = Self.count(foreign, .han, .kana)
                    // Han guesses for Latin text come out as a letter here and there; real
                    // Chinese or Japanese fills the line.
                    guard cjkCount >= 1, cjkCount * 3 >= Self.count(foreign, .latin) else { return false }
                    lines[i] = spliced
                    return true
                }
            }
        }
        // Neither Cyrillic nor CJK: a Latin line the Korean model was unsure of.
        for i in suspects { if let latin = latinFallback[i] { lines[i] = latin } }
    }

    /// Glyphs of a Korean reading outside its trusted ranges.
    private static func untrustedPart(of korean: Reading) -> [Glyph] {
        let kept = trustedKoreanRanges(korean.glyphs)
        return korean.glyphs.indices.filter { i in !kept.contains { $0.contains(i) } }.map { korean.glyphs[$0] }
    }

    /// True when the text is Korean rather than the Korean model's guess at another script:
    /// guesses are a soup of symbols, digits and the odd syllable.
    static func looksKorean(_ glyphs: [Glyph]) -> Bool {
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

    /// The Chinese model tends to swallow the ": " between "[name]" and the message.
    static func restoreColon(_ glyphs: [Glyph]) -> [Glyph] {
        var closings = 0
        for (i, g) in glyphs.enumerated() {
            if g.character == ":" { return glyphs }
            guard g.character == "]" else { continue }
            closings += 1
            guard closings <= 2, i + 1 < glyphs.count else { return glyphs }
            let next = script(glyphs[i + 1].character)
            if next == .han || next == .kana {
                var out = glyphs
                out[i + 1].spaceBefore = true
                out.insert(Glyph(character: ":", minX: g.maxX, maxX: g.maxX, spaceBefore: false), at: i + 1)
                return out
            }
        }
        return glyphs
    }

    /// Glyphs of a spliced line that did not come from the Korean reading.
    private static func foreignPart(of spliced: Reading, korean: Reading) -> [Glyph] {
        let kept = trustedKoreanRanges(korean.glyphs)
        guard !kept.isEmpty else { return spliced.glyphs }
        var own: [Glyph] = []
        for r in kept { own += korean.glyphs[r] }
        // Kept glyphs are copied verbatim, so position and character identify them.
        return spliced.glyphs.filter { g in
            !own.contains { $0.character == g.character && $0.minX == g.minX && $0.maxX == g.maxX }
        }
    }

    /// Index ranges of a low-confidence Korean reading that are still trustworthy: the parts of a
    /// koKR chat line that are Korean whatever the speaker's language — the channel tag
    /// ("[길드]", "[2. 거래]"), a Korean speaker name, and the verb phrase before the colon
    /// ("님의 귓속말:", "의 외침:", "의 말:").
    static func trustedKoreanRanges(_ g: [Glyph]) -> [Range<Int>] {
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
    private static func isChannelTag(_ inner: [Glyph]) -> Bool {
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
    private static func isKoreanName(_ inner: [Glyph]) -> Bool {
        guard inner.count >= 2, inner.count <= 20 else { return false }
        return inner.allSatisfy { script($0.character) == .hangul || $0.character == "-" }
            && count(inner, .hangul) >= 2
    }

    /// Keeps the trusted Korean parts of `korean` and takes everything else from `other`.
    ///
    /// The two readings are aligned on the bracket or colon that ends a trusted part when both
    /// models saw it (their boxes for the same glyph overlap), and by x position otherwise.
    static func splice(korean: Reading, other: Reading) -> Reading {
        let kept = trustedKoreanRanges(korean.glyphs)
        var result = other
        result.box = korean.box.union(other.box)
        result.confidence = max(korean.confidence, other.confidence)
        guard !kept.isEmpty, !other.glyphs.isEmpty else { return result }

        let k = korean.glyphs, o = other.glyphs
        // Kept small: glyph boxes are often those of the whole word, so the bracket that closes
        // the NEXT word ("[길드] [Иван]") starts only a space away from the mark looked for, and
        // taking it for the twin drops the speaker's name.
        let tolerance = korean.box.height * 0.15

        /// Index in `o` (at or after `from`) of the glyph that is the same mark as `mark`.
        func twin(of mark: Glyph, from: Int) -> Int? {
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

        var out: [Glyph] = []
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
                    edge = min(edge, last.minX + korean.box.height * 0.35)
                }
                end = o[start...].firstIndex { $0.anchorX >= edge - 1 } ?? o.count
            }
            out += o[cursor..<start]
            out += k[range]
            cursor = max(end, start)
        }
        out += o[cursor...]
        result.glyphs = out
        return result
    }

    // MARK: - Rescue, enUS client

    private func rescueEnglishClient(_ lines: inout [Reading], detected: [CGRect], pass: Pass) {
        appendMissedRows(to: &lines, detected: detected)
        defer { lines.removeAll { $0.glyphs.isEmpty } }

        // Language detection is per line and sure of itself on Latin/Cyrillic lines. Lines it
        // routed to the Korean or Chinese model come back below 1.0, and small Hangul or kana
        // next to Latin tags can be routed to the wrong one; both models can re-read those lines.
        //
        // Measured, though, on the inverted-grey picture this pipeline uses, detection alone
        // already reaches 99.1 % and the second opinions change nothing while tripling the frame
        // time — so by default only rows the first pass skipped altogether are read again.
        let suspects = lines.indices.filter {
            lines[$0].glyphs.isEmpty || (options.secondOpinionForUnsureLines && lines[$0].confidence < 0.9)
        }
        guard !suspects.isEmpty else { return }
        let region = unionRegion(suspects.map { lines[$0] }, imageSize: pass.imageSize)

        var korean: [Reading] = []
        var cjk: [Reading] = []
        if let found = try? pass.run(languages: Self.koreanModel, autodetect: false, region: region) {
            korean = Self.mergeIntoLines(found)
        }
        // Lines the Korean model reads as Korean need no second opinion.
        let undecided = suspects.filter { i in
            guard let k = Self.counterpart(of: lines[i], in: korean) else { return true }
            return !Self.looksKorean(k.glyphs)
        }
        if !undecided.isEmpty {
            let rest = unionRegion(undecided.map { lines[$0] }, imageSize: pass.imageSize)
            if let found = try? pass.run(languages: Self.chineseJapaneseModel, autodetect: false, region: rest) {
                cjk = Self.mergeIntoLines(found)
            }
        }

        for i in suspects {
            if let k = Self.counterpart(of: lines[i], in: korean), Self.looksKorean(k.glyphs) {
                lines[i] = k
            } else if let c = Self.counterpart(of: lines[i], in: cjk), Self.count(c.glyphs, .han, .kana) >= 1,
                      Self.count(c.glyphs, .han, .kana) * 3 >= Self.count(c.glyphs, .latin) || lines[i].glyphs.isEmpty {
                lines[i] = c
            }
        }
    }
}
