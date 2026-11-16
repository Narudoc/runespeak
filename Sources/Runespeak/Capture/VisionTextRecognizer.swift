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
///  * koKR client: one Korean pass over the frame. A message it read as Korean is final: no
///    other model reads Hangul, and each answers with confident nonsense (digits, bars,
///    Cyrillic) for a script it does not know. Rows it is not sure about, or in which a
///    bracket or a letter looks misread, are shown to the Latin/Cyrillic model and, if that
///    does not explain them, to the Chinese/Japanese model. Which model is believed for which
///    part of a row is decided in `ScriptChoice` (RunespeakCore), word by word; letters of a
///    script that cannot stand in a row never leave the recogniser.
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
        /// Cut words in another colour off the end of a chat row (text of the game world that
        /// overlaps the chat window) and read a row damaged by them again without them.
        var trimForeignTail = true

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

    /// Debugging aid for `--replay-image --trace`: receives one line per recognition pass and
    /// per decision about a row. Nil in the app.
    nonisolated(unsafe) static var trace: ((String) -> Void)?
    /// With `trace`: also where each model placed every glyph of a row it was asked twice about.
    nonisolated(unsafe) static var traceGlyphs = false
    /// Recognition passes that threw since the process started. A second-model pass that fails
    /// is skipped silently in the app; the command-line tools report the count, so that a
    /// skipped pass is not mistaken for a clean result.
    nonisolated(unsafe) private(set) static var failedPasses = 0
    private static let failedPassLock = NSLock()
    fileprivate static func noteFailedPass(_ error: Error, languages: [String]) {
        failedPassLock.lock(); failedPasses += 1; failedPassLock.unlock()
        trace?("PASS FAILED languages=\(languages): \(error)")
    }

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
            case .koKR: rescueKoreanClient(&lines, detected: rows, pass: pass, locale: clientLocale)
            case .enUS: rescueEnglishClient(&lines, detected: rows, pass: pass)
            }
        }

        // Which rows stand on plain black: asked once per row, used twice below.
        let onBlack = lines.map { pixels.isOpaqueBlack(in: $0.box.insetBy(dx: -$0.box.height, dy: -0.15 * $0.box.height)) }
        if options.trimForeignTail {
            let all = lines
            var rereads = 0
            lines = lines.enumerated().map { n, line in
                // A chat window with an opaque background shows nothing of the world: every
                // word on the row is the row's own, whatever its colour.
                if onBlack[n] { return line }
                // A link that wraps ("[Blade of Eternal" / "Darkness] ...") ends this row in the
                // link's colour: that is chat, not text of the world.
                if Self.endsInsideLink(line, among: all) || Self.tailContinuesBelow(line, among: all, pixels: pixels) { return line }
                var line = line
                if rereads < Self.maxWorldTextRereads {
                    line = withoutWorldTextInside(line, pixels: pixels, clientLocale: clientLocale) { foreign, kept in
                        rereads += 1
                        return self.reread(line, without: foreign, keeping: kept, pixels: pixels, preprocess: preprocess,
                                           upscale: upscale, languages: languages, autodetect: autodetect)
                    }
                }
                return trimForeignTail(line, pixels: pixels, clientLocale: clientLocale) { foreign, kept in
                    self.reread(line, without: foreign, keeping: kept, pixels: pixels, preprocess: preprocess,
                                upscale: upscale, languages: languages, autodetect: autodetect)
                }
            }
        }

        let result = lines
            .sorted { $0.box.minY < $1.box.minY }
            .compactMap { reading -> OCRLine? in
                var line = reading
                // Scripts that cannot stand in the row never leave the recogniser: the Latin
                // model writes Cyrillic for whatever it cannot read.
                switch clientLocale {
                case .koKR: if !line.cyrillic { line.glyphs = ScriptChoice.withoutStrayScripts(line.glyphs) }
                case .enUS: line.glyphs = ScriptChoice.foldLookAlikes(line.glyphs)
                }
                line.glyphs = Self.tidy(line.glyphs)
                let text = line.text
                guard !text.isEmpty else { return nil }
                let color = line.ownColour ?? pixels.glyphColor(in: line.messageColourRects()) ?? pixels.glyphColor(in: [line.box]) ?? .white
                return OCRLine(text: text, box: line.box, color: color, confidence: line.confidence)
            }
        // Most rows on plain black: the window has an opaque background. (Not all of them:
        // what the game draws over the chat, a menu, has a panel of its own.)
        let black = onBlack.filter { $0 }.count
        return OCRFrame(lines: result, imageSize: size, opaqueBackground: black >= 1 && black * 2 >= onBlack.count)
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
    typealias Glyph = OCRGlyph

    /// One visual text line as read by one model (or spliced from several).
    struct Reading {
        var glyphs: [Glyph]
        var box: CGRect
        var confidence: Double
        /// Stands far to the right of other text on its row: not the start of a chat line.
        var detached = false
        /// Colour of the row's own text when it had to be told from something drawn over it.
        var ownColour: RGBColor?
        /// Accepted as Cyrillic text (see `ScriptChoice`): the only rows that may carry it.
        var cyrillic = false

        var text: String { ScriptChoice.text(glyphs) }

        /// Pixel rects of the text outside [brackets]. Channel tags, player names and item links
        /// are bracketed and may carry class/quality colours; what is left is the message itself,
        /// which is always drawn in the channel colour.
        func bodyRects() -> [CGRect] {
            var rects: [CGRect] = []
            // A row that closes a bracket it never opened starts inside a link that wrapped
            // ("Vow][Bring Back a Ring]"): what stands in front of that bracket is link text.
            var depth = glyphs.first(where: { $0.character == "[" || $0.character == "]" })?.character == "]" ? 1 : 0
            // Right end of the last bracketed word. Where a model reports word boxes only, the
            // ":" of "[Name]:" has the extent of the whole word and must not start a run.
            var bracketedUntil = -CGFloat.greatestFiniteMagnitude
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
                    bracketedUntil = max(bracketedUntil, g.maxX)
                } else if g.character == "]" {
                    depth = max(0, depth - 1)
                    bracketedUntil = max(bracketedUntil, g.maxX)
                } else if depth > 0 {
                    bracketedUntil = max(bracketedUntil, g.maxX)
                } else if g.minX >= bracketedUntil - 1 {
                    let counts = g.character.isLetter || g.character.isNumber ? 1 : 0
                    if let r = run {
                        run = (min(r.minX, g.minX), max(r.maxX, g.maxX), r.letters + counts)
                    } else if counts > 0 {
                        run = (g.minX, g.maxX, counts)
                    }
                }
            }
            close()
            return rects
        }

        /// Where the colour of the message can be read off the row: the text outside brackets,
        /// or, on a header row with next to nothing behind the colon ("[Guild] [Some Name]: ?"),
        /// the channel tag, which is drawn in the colour of the message. Never the name, which
        /// may have the colour of the speaker's class.
        func messageColourRects() -> [CGRect] {
            let body = bodyRects()
            guard body.isEmpty, glyphs.count >= 6, glyphs[0].character == "[",
                  let close = glyphs.firstIndex(where: { $0.character == "]" }), close >= 2, close <= 28,
                  close + 1 < glyphs.count, glyphs[close + 1].character == "[" else { return body }
            let minX = glyphs[0].minX, maxX = glyphs[close].maxX
            return maxX - minX >= 3 ? [CGRect(x: minX, y: box.minY, width: maxX - minX, height: box.height)] : body
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
            do {
                try handler.perform([request])
            } catch {
                VisionTextRecognizer.noteFailedPass(error, languages: languages)
                throw error
            }

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
            if let trace = VisionTextRecognizer.trace {
                trace("PASS languages=\(languages.joined(separator: ",")) region=\(region.map { "y\(Int($0.minY))..\(Int($0.maxY))" } ?? "all"): \(out.count) fragments")
                for r in out.sorted(by: { $0.box.minY != $1.box.minY ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }) {
                    trace(String(format: "  x=%.0f..%.0f y=%.0f..%.0f conf=%.2f |%@|", r.box.minX, r.box.maxX, r.box.minY, r.box.maxY,
                                 r.confidence, r.text))
                }
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
        // Nobody types a bullet: it is a full stop the model saw a little above the baseline.
        case "\u{2022}", "\u{2219}": return ["."]
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

    typealias Script = ScriptChoice.Script

    static func script(_ c: Character) -> Script { ScriptChoice.script(c) }

    private static func count(_ glyphs: [Glyph], _ scripts: Script...) -> Int {
        glyphs.reduce(0) { $0 + (scripts.contains(script($1.character)) ? 1 : 0) }
    }

    private static func bracketsBalanced(_ glyphs: [Glyph]) -> Bool { ScriptChoice.bracketsBalanced(glyphs) }

    // MARK: - Line assembly

    /// Vision splits a visual line where it sees a wide gap (between a channel tag and the name,
    /// around an item link, at a script change). Joins fragments sharing a baseline, left to right.
    /// Gap, in line heights, beyond which two fragments on one baseline are not one line.
    static let wideGap: CGFloat = 2

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

        // Fragments of one chat line sit about a space apart. Across a wide gap they are different
        // things: chat on the left and, say, the name over a character behind the chat window.
        var groups: [[Reading]] = []
        for row in rows {
            var group: [Reading] = []
            var right: CGFloat = 0, height: CGFloat = 0
            for p in row.sorted(by: { $0.box.minX < $1.box.minX }) {
                if !group.isEmpty, p.box.minX - right > wideGap * max(height, p.box.height) {
                    groups.append(group)
                    group = []
                    var first = p
                    first.detached = true
                    group.append(first)
                    right = p.box.maxX; height = p.box.height
                    continue
                }
                group.append(p)
                right = max(right, p.box.maxX); height = max(height, p.box.height)
            }
            groups.append(group)
        }

        return groups.map { row -> Reading in
            guard row.count > 1 else { return row[0] }
            let parts = row
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
        var bestShared: CGFloat = 0
        for c in candidates {
            let overlap = min(c.box.maxY, line.box.maxY) - max(c.box.minY, line.box.minY)
            guard overlap > min(c.box.height, line.box.height) * 0.5 else { continue }
            // A baseline can hold two readings (see `mergeIntoLines`): the one covering the same
            // stretch of it is the counterpart.
            let shared = max(0, min(c.box.maxX, line.box.maxX) - max(c.box.minX, line.box.minX))
            if best == nil || shared > bestShared || (shared == bestShared && overlap > bestOverlap) {
                bestOverlap = overlap; bestShared = shared; best = c
            }
        }
        return best
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

    /// Which model is believed for which part of a row is decided in `ScriptChoice`; this runs
    /// the passes it asks for.
    private func rescueKoreanClient(_ lines: inout [Reading], detected: [CGRect], pass: Pass, locale: ClientLocale) {
        appendMissedRows(to: &lines, detected: detected)
        defer { lines.removeAll { $0.glyphs.isEmpty } }

        // The bracket in front of the speaker colon is read as a thin letter on every other
        // row. Whatever the passes below make of the row, that is mended in the end; the other
        // model is asked first, because it tells a bracket read as "l" from a name that ends
        // in "l" in front of a bracket that was not read.
        defer {
            for i in lines.indices where !lines[i].glyphs.isEmpty && !lines[i].cyrillic {
                lines[i].glyphs = ScriptChoice.mendSpeakerBracket(lines[i].glyphs)
            }
        }

        // The Korean model answers 1.0 for text it can read (Hangul, Latin) and 0.3–0.5 for
        // Cyrillic, Han and kana — and for small or noisy Korean. A message it read as Korean
        // and is sure of is final: no other model reads Hangul. (Such a row is still shown to
        // the Latin model when its name bracket is in doubt, for that bracket alone.)
        var suspects = lines.indices.filter { i in
            let l = lines[i]
            if l.detached { return false }
            if l.glyphs.isEmpty { return true }
            let balanced = Self.bracketsBalanced(l.glyphs)
            if ScriptChoice.isSettledKorean(l.glyphs, confidence: l.confidence) {
                return !balanced && ScriptChoice.mendSpeakerBracket(l.glyphs) != l.glyphs
            }
            if l.confidence < ScriptChoice.sure || !balanced { return true }
            // Sure of the row, but a link bracket or a letter in it reads like a misread.
            if ScriptChoice.hasLinkLookAlike(l.glyphs) || ScriptChoice.hasDigitLookAlike(l.glyphs) { return true }
            // The row above ends inside a link and this one closes none: the Korean model
            // skips a closing bracket where the colour changes behind it.
            if !l.glyphs.contains(where: { $0.character == "[" || $0.character == "]" }),
               let above = Self.rowAbove(l, among: lines),
               above.glyphs.last(where: { $0.character == "[" || $0.character == "]" })?.character == "[" {
                return true
            }
            return false
        }
        guard !suspects.isEmpty else { return }
        Self.trace?("suspects: " + suspects.map { "y=\(Int(lines[$0].box.minY))" }.joined(separator: " "))

        // Latin/Cyrillic first: it is three times cheaper than the Chinese model.
        var latinFallback: [Int: Reading] = [:]
        let region = unionRegion(suspects.map { lines[$0] }, imageSize: pass.imageSize)
        if let found = try? pass.run(languages: Self.latinCyrillicModel, autodetect: false, region: region) {
            let latin = Self.mergeIntoLines(found)
            suspects.removeAll { i in
                // The other model's reading of this row, and of no other: a speck beside the
                // window that it joined to the row next to it ("D [1. General] [Some Name]:
                // text") is the reading of that row, which has one of its own.
                guard let alt = Self.counterpart(of: lines[i], in: latin),
                      Self.counterpart(of: alt, in: lines)?.box == lines[i].box else { return false }
                let original = lines[i]
                let height = original.glyphs.isEmpty ? alt.box.height : original.box.height
                let choice = ScriptChoice.chooseLatin(korean: original.glyphs, koreanConfidence: original.confidence,
                                                      latin: alt.glyphs, latinConfidence: alt.confidence, height: height)
                if Self.trace != nil, Self.traceGlyphs {
                    Self.trace?("  K: " + original.glyphs.map { "\($0.character)\(Int($0.minX))-\(Int($0.maxX))" }.joined(separator: " "))
                    Self.trace?("  L: " + alt.glyphs.map { "\($0.spaceBefore ? "_" : "")\($0.character)\(Int($0.minX))-\(Int($0.maxX))" }.joined(separator: " "))
                }
                switch choice {
                case .korean(let glyphs):
                    Self.trace?("y=\(Int(original.box.minY)) korean stands: |\(ScriptChoice.text(glyphs))|")
                    lines[i].glyphs = glyphs
                    // Read the same way by both models: no guess, whatever the first one said.
                    if alt.confidence > original.confidence, ScriptChoice.agree(korean: glyphs, latin: alt.glyphs, height: height) {
                        lines[i].confidence = alt.confidence
                        return true
                    }
                    // A guess at Han or kana comes back at 0.3: the Chinese model gets a look.
                    return original.confidence >= 0.45
                case .cyrillic(let glyphs, let confidence):
                    Self.trace?("y=\(Int(original.box.minY)) cyrillic: |\(ScriptChoice.text(glyphs))|")
                    lines[i] = Self.replaced(original, by: alt, glyphs: glyphs, confidence: confidence)
                    lines[i].cyrillic = true
                    return true
                case .latinFallback(let glyphs, let confidence):
                    Self.trace?("y=\(Int(original.box.minY)) latin fallback: |\(ScriptChoice.text(glyphs))|")
                    latinFallback[i] = Self.replaced(original, by: alt, glyphs: glyphs, confidence: confidence)
                    return false
                case .unreadable:
                    return false
                }
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
                    guard cjkSuspects.contains(i), let alt = Self.counterpart(of: lines[i], in: cjk),
                          Self.counterpart(of: alt, in: lines)?.box == lines[i].box else { return false }
                    let original = lines[i]
                    let glyphs = original.glyphs.isEmpty
                        ? alt.glyphs : ScriptChoice.splice(korean: original.glyphs, other: alt.glyphs, height: original.box.height)
                    let foreign = ScriptChoice.foreignPart(of: glyphs, korean: original.glyphs)
                    guard ScriptChoice.isChineseOrJapanese(korean: original.glyphs, foreign: foreign) else { return false }
                    lines[i] = Self.replaced(original, by: alt, glyphs: glyphs, confidence: alt.confidence)
                    return true
                }
            }
        }
        // Neither Cyrillic nor CJK: a Latin line the Korean model could not read.
        for i in suspects { if let latin = latinFallback[i] { lines[i] = latin } }
    }

    /// `korean` with its message taken from `other`: the confidence is that of the reading the
    /// message came from, never the larger of the two (which made a guess look like a clean
    /// read).
    private static func replaced(_ korean: Reading, by other: Reading, glyphs: [Glyph], confidence: Double) -> Reading {
        var result = other
        result.glyphs = glyphs
        result.box = korean.glyphs.isEmpty ? other.box : korean.box.union(other.box)
        result.confidence = confidence
        result.detached = korean.detached
        return result
    }

    static func looksKorean(_ glyphs: [Glyph]) -> Bool { ScriptChoice.looksKorean(glyphs) }

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

    // MARK: - Text of the world over a chat row

    /// Glyph index ranges of the space-separated words of a reading.
    private static func words(_ glyphs: [Glyph]) -> [Range<Int>] { ScriptChoice.words(glyphs) }

    private static func rect(of range: Range<Int>, in line: Reading) -> CGRect {
        let minX = line.glyphs[range].map(\.minX).min() ?? line.box.minX
        let maxX = line.glyphs[range].map(\.maxX).max() ?? line.box.maxX
        return CGRect(x: minX, y: line.box.minY, width: maxX - minX, height: line.box.height)
    }

    /// True when the row right below `line` closes a bracket it never opened: `line` ends
    /// inside a link that wraps, even if its own opening bracket was misread.
    static func endsInsideLink(_ line: Reading, among lines: [Reading]) -> Bool {
        guard let next = rowBelow(line, among: lines),
              let first = next.glyphs.first(where: { $0.character == "[" || $0.character == "]" }) else { return false }
        return first.character == "]"
    }

    /// The row right above `line`, if any.
    private static func rowAbove(_ line: Reading, among lines: [Reading]) -> Reading? {
        let h = line.box.height
        guard h > 0 else { return nil }
        return lines.filter {
            !$0.detached && !$0.glyphs.isEmpty && $0.box.midY < line.box.midY - 0.5 * h && $0.box.midY > line.box.midY - 1.8 * h
                && abs($0.box.minX - line.box.minX) < 2.5 * h
        }.max { $0.box.midY < $1.box.midY }
    }

    /// The row right below `line` on the column of wrapped rows, if any.
    private static func rowBelow(_ line: Reading, among lines: [Reading]) -> Reading? {
        let h = line.box.height
        guard h > 0 else { return nil }
        return lines.filter {
            !$0.detached && $0.box.midY > line.box.midY + 0.5 * h && $0.box.midY < line.box.midY + 1.8 * h
                && abs($0.box.minX - line.box.minX) < 2.5 * h
        }.min { $0.box.midY < $1.box.midY }
    }

    /// True when the last word of `line` and the first word of the row below it are drawn in
    /// one colour that is not the colour of the row: a link of any link colour (item quality,
    /// quest, spell, achievement) that wraps. Its brackets need not have been read.
    static func tailContinuesBelow(_ line: Reading, among lines: [Reading], pixels: PixelBuffer) -> Bool {
        guard let next = rowBelow(line, among: lines), next.box.minX > line.box.minX + 0.15 * line.box.height else { return false }
        let mine = words(line.glyphs), theirs = words(next.glyphs)
        guard mine.count >= 3, let last = mine.last, let first = theirs.first,
              let tail = pixels.glyphColor(in: [rect(of: last, in: line)]),
              let head = pixels.glyphColor(in: [rect(of: first, in: next)]),
              let own = pixels.glyphColor(in: [rect(of: mine[0], in: line)]) else { return false }
        return PixelBuffer.chromaDistance(tail, head) < 0.2 && PixelBuffer.chromaDistance(tail, own) > otherColourDistance
    }

    /// Names floating over characters and other text of the game world show through the chat
    /// window, and where they touch the end of a chat row OCR reads them as part of it. The text
    /// of a chat message has one colour (links and names, which may differ, are bracketed), so
    /// words at the end of a row in a clearly different colour are cut off.
    ///
    /// The overlap also damages the chat words under it. `reread` is asked for a second reading
    /// with that colour erased, which replaces the first unless it is the worse of the two.
    private func trimForeignTail(_ line: Reading, pixels: PixelBuffer, clientLocale: ClientLocale,
                                 reread: ((_ foreign: RGBColor, _ kept: RGBColor) -> Reading?)?) -> Reading {
        let words = Self.words(line.glyphs)
        guard words.count >= 2 else { return line }
        let parsed = ChatLineParser.parse(line.text, locale: clientLocale)

        // The colour the row's text ought to have, and the first word that may be cut.
        var reference: RGBColor?
        var firstCuttable = 1
        if parsed.hasPrefix {
            let bodyWords = parsed.body.split(separator: " ").count
            guard bodyWords >= 1, bodyWords < words.count, line.text.hasSuffix(parsed.body) else { return line }
            let firstBody = words.count - bodyWords
            // A channel tag is drawn in the colour of the message; a name may have its own.
            if parsed.channelLabel != nil, line.glyphs[0].character == "[",
               let close = line.glyphs.firstIndex(where: { $0.character == "]" }), close < words[firstBody].lowerBound {
                reference = pixels.glyphColor(in: [Self.rect(of: 0..<(close + 1), in: line)])
            }
            if reference == nil { reference = pixels.glyphColor(in: [Self.rect(of: words[firstBody], in: line)]) }
            firstCuttable = firstBody + 1
        } else {
            // A wrapped row of a chat message. System text is left alone: it mixes colours.
            guard words.count >= 3 else { return line }
            let head = words[0].lowerBound..<words[1].upperBound
            var sample = [Self.rect(of: head, in: line)]
            if line.glyphs[head].contains(where: { $0.character == "[" || $0.character == "]" }) {
                // The row begins with a link, which has a colour of its own: the colour of the
                // row is that of the text outside brackets. "[Some Item]을 만들었습니다." is a
                // notice of the game in the colour of its text, however white its link; a row
                // that is all link has nothing that could be cut.
                sample = line.bodyRects()
                guard !sample.isEmpty else { return line }
            }
            guard let colour = pixels.glyphColor(in: sample),
                  let channel = ChatColors.channel(for: colour), channel != .system, channel != .emote else { return line }
            reference = colour
            firstCuttable = 2
        }
        guard let kept = reference else { return line }
        // The message text ends inside a link ("... [Blade of Eternal"): its last words have
        // the link's colour and are chat.
        let message = line.glyphs[(parsed.hasPrefix ? words[firstCuttable - 1].lowerBound : 0)...]
        if message.last(where: { $0.character == "[" || $0.character == "]" })?.character == "[" { return line }

        // Words are cut from the end for as long as they are drawn in another colour and show
        // nothing of the row's own. A chat word half covered by world text still shows its
        // own colour and stays.
        //
        // One vivid other colour (the blue, green, red and yellow of names) is proof by
        // itself. Names are also drawn in white and grey (a name plate, a dead or tapped
        // unit) and, where the client colours them by class, in hues the chat channels use:
        // such a colour proves less, so the words must also be what a name over a character
        // is made of (a few words of letters, a "<Guild>" tag).
        var cut = words.count
        var foreign: RGBColor?
        var pale = false
        while cut > firstCuttable {
            let word = words[cut - 1]
            if line.glyphs[word].contains(where: { $0.character == "[" || $0.character == "]" }) { break }
            let rect = Self.rect(of: word, in: line)
            guard let colour = pixels.glyphColor(in: [rect]) else { break }
            let distance = PixelBuffer.chromaDistance(colour, kept)
            let vivid = max(colour.r, colour.g, colour.b) - min(colour.r, colour.g, colour.b) >= 0.35
            if !pale, vivid, distance > Self.foreignColourDistance {
                guard pixels.share(of: kept, in: rect) < 0.01, pixels.share(of: colour, in: rect) >= 0.03 else { break }
            } else if pale || cut == words.count, distance > Self.otherColourDistance {
                // (The box of a word reaches a pixel or two into the glyph before it: a trace
                // of the row's hue at its edge is not the word's.)
                let own = pixels.share(of: colour, in: rect)
                guard own >= 0.03, pixels.share(of: kept, in: rect) < max(0.005, 0.08 * own) else { break }
                pale = true
            } else {
                break
            }
            foreign = colour
            cut -= 1
        }
        if pale {
            var tail = line
            tail.glyphs = Array(line.glyphs[words[cut].lowerBound...])
            guard Self.isMadeOfNameWords(tail.text) else { return line }
            // The colour the row is held to must be the row's beyond doubt: a wrapped row that
            // begins with the end of a link ("Bandage] cheap, pst me") has the link's colour
            // on its first words, and so has a row with a name over its start. Most of what
            // is left, and three words of it at least, must be drawn in that colour.
            if !parsed.hasPrefix, line.glyphs.first(where: { $0.character == "[" || $0.character == "]" })?.character == "]" {
                return line
            }
            let own = words[..<cut].filter { pixels.share(of: kept, in: Self.rect(of: $0, in: line)) >= 0.03 }.count
            guard own >= 3, own * 2 > cut else { return line }
        }
        guard cut < words.count, let foreign else { return line }
        // Over a busy scene the colour sampled from a few glyphs can be the scene's. The
        // reference is believed only when the row as a whole says the same.
        guard let whole = pixels.glyphColor(in: [line.box]),
              PixelBuffer.chromaDistance(kept, whole) < (pale ? 0.15 : 0.3) else { return line }

        var trimmed = line
        trimmed.glyphs = Array(line.glyphs[..<words[cut].lowerBound])
        let right = trimmed.glyphs.map(\.maxX).max() ?? line.box.maxX
        trimmed.box = CGRect(x: line.box.minX, y: line.box.minY, width: max(2, right - line.box.minX), height: line.box.height)

        // Erasing a pale colour next to pale chat text takes the edges of the chat glyphs with
        // it: such a row is not read again.
        if let reread, !pale, line.confidence < 0.9 || !Self.bracketsBalanced(trimmed.glyphs),
           var again = reread(foreign, kept) {
            again = trimForeignTail(again, pixels: pixels, clientLocale: clientLocale, reread: nil)
            let second = ChatLineParser.parse(again.text, locale: clientLocale)
            let sound = Self.bracketsBalanced(again.glyphs)
            if second.hasPrefix == parsed.hasPrefix, again.glyphs.count * 10 >= trimmed.glyphs.count * 7,
               sound || !Self.bracketsBalanced(trimmed.glyphs),
               again.confidence >= line.confidence || (sound && again.confidence >= 0.45) {
                return again
            }
        }
        return trimmed
    }

    /// Up to four words of letters, with or without the angle brackets of a guild tag: "Some
    /// Name", "<Some Guild>", "some Nam" (OCR gets the case of a first letter wrong, and a
    /// name that runs out of the captured region is cut short). Numbers and punctuation, which
    /// chat is full of, are not in names.
    static func isMadeOfNameWords(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard (1...4).contains(words.count) else { return false }
        return words.allSatisfy { word in
            var w = Substring(word)
            if w.hasPrefix("<") { w = w.dropFirst() }
            if w.hasSuffix(">") { w = w.dropLast() }
            return w.filter(\.isLetter).count >= 2 && w.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
        }
    }

    /// No player channel is drawn in this colour: it is a colour of names over characters
    /// (blue, green, red, yellow — which system text shares) or of nothing known.
    private static func isWorldColour(_ colour: RGBColor) -> Bool {
        guard let channel = ChatColors.channel(for: colour) else { return true }
        return channel == .system || channel == .emote
    }

    /// Rows per frame that may be read a second time for text of the world drawn through them.
    static let maxWorldTextRereads = 4

    /// A name floating over a character that stands behind the chat window is drawn through
    /// the middle of a chat row as often as over its end, and OCR then reads both as one run of
    /// letters ("without quests" + "<Some Guild>" = "withSomeGutsts"). Chat text outside
    /// brackets has one colour, so a word there that is mostly drawn in a vivid colour no
    /// player channel uses (the blue, green, red and yellow of names) gives the overlap away.
    /// `reread` is asked for a second reading with that colour erased; it replaces the first
    /// when it is a sound chat row.
    private func withoutWorldTextInside(_ line: Reading, pixels: PixelBuffer, clientLocale: ClientLocale,
                                        reread: (_ foreign: RGBColor, _ kept: RGBColor) -> Reading?) -> Reading {
        let words = Self.words(line.glyphs)
        // The second reading uses the first pass's model only: a line another model had to
        // read (Cyrillic, Chinese, Japanese) would come back worse.
        guard words.count >= 2, !line.detached, Self.count(line.glyphs, .cyrillic, .han, .kana) == 0 else { return line }
        let parsed = ChatLineParser.parse(line.text, locale: clientLocale)
        let balanced = Self.bracketsBalanced(line.glyphs)
        var damaged = !balanced || parsed.isDamagedHeader
        var mustBecomeHeader = false

        // The colour the row's text ought to have, and the first word that may be covered.
        var reference: RGBColor?
        var first = 0
        // The colour was read off the channel tag: it is the row's for certain.
        var fromTag = false
        if line.glyphs[0].character == "[", ChatLineParser.opensLikeHeader(line.text) {
            fromTag = true
            // A channel tag is drawn in the colour of the message. When its closing bracket
            // is gone, its first word ("[1.", "[Guild") still is.
            if let close = line.glyphs.firstIndex(where: { $0.character == "]" }), close <= 28 {
                reference = pixels.glyphColor(in: [Self.rect(of: 0..<(close + 1), in: line)])
                first = words.firstIndex { $0.lowerBound > close } ?? words.count
            } else {
                reference = pixels.glyphColor(in: [Self.rect(of: words[0], in: line)])
                first = 1
            }
        } else if parsed.hasPrefix {
            let bodyWords = parsed.body.split(separator: " ").count
            guard bodyWords >= 2, bodyWords < words.count, line.text.hasSuffix(parsed.body) else { return line }
            let firstBody = words.count - bodyWords
            reference = pixels.glyphColor(in: [Self.rect(of: words[firstBody], in: line)])
            first = firstBody + 1
        } else {
            // A wrapped row: most of it is chat, whichever of its words are covered. When
            // most of it is NOT in a chat colour, it may be a header row with a name of the
            // world over its start, and the chat colour is the other one on the row.
            // "[Some Name]xxxx": a speech header ("[Name] yells:") that no longer reads as one.
            let opensWithName = line.glyphs[0].character == "[" && line.glyphs[1].character.isLetter
            guard words.count >= 3 || opensWithName else { return line }
            // "[Some Item]을 만들었습니다.": a notice of the game that begins with a link. Its
            // own text, outside the brackets, is in a system colour.
            if opensWithName, let own = pixels.glyphColor(in: line.bodyRects()), ChatColors.channel(for: own) == .system {
                return line
            }
            mustBecomeHeader = opensWithName
            reference = pixels.glyphColor(in: [line.box])
            if let dominant = reference, Self.isWorldColour(dominant),
               let other = pixels.glyphColor(in: [line.box], besides: dominant), !Self.isWorldColour(other),
               max(other.r, other.g, other.b) >= 0.6,
               PixelBuffer.chromaDistance(other, dominant) > Self.foreignColourDistance,
               pixels.share(of: other, in: line.box) >= max(0.02, 0.3 * pixels.share(of: dominant, in: line.box)) {
                reference = other
                mustBecomeHeader = true
            }
        }
        guard let kept = reference, first < words.count, !Self.isWorldColour(kept) else { return line }

        if mustBecomeHeader { damaged = true }
        // Names and links keep their own colours inside brackets; on a row whose brackets do
        // not pair up nothing can be told apart that way, and the row is damaged anyway.
        var depth = 0
        var bracketed = Set<Int>()
        for (n, word) in words.enumerated() {
            var inside = depth > 0
            for g in line.glyphs[word] {
                if g.character == "[" { depth += 1; inside = true }
                if g.character == "]" { depth = max(0, depth - 1); inside = true }
            }
            if inside { bracketed.insert(n) }
        }
        // Not the colour of the words: the colour of what else is drawn where they are, in
        // one pass over all of them.
        let rects = (first..<words.count).filter { damaged || !bracketed.contains($0) }.map { Self.rect(of: words[$0], in: line) }
        guard !rects.isEmpty, let foreign = pixels.glyphColor(in: rects, besides: kept),
              PixelBuffer.chromaDistance(foreign, kept) > Self.foreignColourDistance,
              max(foreign.r, foreign.g, foreign.b) - min(foreign.r, foreign.g, foreign.b) >= 0.35,
              rects.contains(where: { pixels.share(of: foreign, in: $0) >= 0.03 }) else { return line }
        // A colour no player channel uses, or the red of a yell behind a tag that tells the
        // row is no yell: a hostile name is drawn in that red, and no item link is. (The
        // orange of a legendary link is the colour of raid chat: other channel colours stay.)
        let named = ChatColors.channel(for: foreign)
        guard named == nil || named == .system
                || (fromTag && named == .yell && ChatColors.channel(for: kept) != .yell) else { return line }
        guard var again = reread(foreign, kept) else { return line }

        let second = ChatLineParser.parse(again.text, locale: clientLocale)
        guard !second.isDamagedHeader, again.confidence >= 0.45 else { return line }
        again.ownColour = kept
        if damaged {
            // Anything that reads as a header again is better than a row that does not.
            return second.hasPrefix ? again : line
        }
        guard Self.bracketsBalanced(again.glyphs), second.hasPrefix == parsed.hasPrefix, again.glyphs.count * 10 >= line.glyphs.count * 6 else { return line }
        if parsed.hasPrefix, second.sender != parsed.sender || second.channelLabel != parsed.channelLabel { return line }
        return again
    }

    /// Hue distance (brightness removed) beyond which a word is not in the colour of its row.
    /// Channel pink against the green of a friendly name is about 1.2.
    static let foreignColourDistance = 0.5
    /// The same for a colour that is not vivid: just beyond the distance within which
    /// `PixelBuffer.share` counts a pixel as drawn in a hue. Channel pink against white is 0.32.
    static let otherColourDistance = 0.25

    /// Reads the row of `line` again from a copy in which everything in the hue of `foreign` is
    /// blacked out.
    private func reread(_ line: Reading, without foreign: RGBColor, keeping kept: RGBColor, pixels: PixelBuffer,
                        preprocess: Options.Preprocess, upscale: CGFloat, languages: [String], autodetect: Bool) -> Reading? {
        reread(line, pixels: pixels, preprocess: preprocess, upscale: upscale, languages: languages, autodetect: autodetect) { strip in
            strip.erase(colour: foreign, keeping: kept, reach: max(2, Int(line.box.height / 12)))
        }
    }

    /// Reads the row of `line` again from a copy of its strip of the picture, changed by `edit`
    /// and drawn `upscale` times as large.
    private func reread(_ line: Reading, pixels: PixelBuffer, preprocess: Options.Preprocess, upscale: CGFloat,
                        languages: [String], autodetect: Bool, edit: (inout PixelBuffer) -> Void) -> Reading? {
        // The rows above and below come along whole: half a row of cut-off glyphs disturbs the reading.
        let pad = max(3, line.box.height)
        let top = max(0, Int((line.box.minY - pad).rounded(.down)))
        let bottom = min(pixels.height, Int((line.box.maxY + pad).rounded(.up)))
        guard bottom - top >= 8, var strip = pixels.strip(top..<bottom) else { return nil }
        edit(&strip)
        switch preprocess {
        case .none: break
        case .maxChannel: strip.flattenToMaxChannel(inverted: false)
        case .maxChannelInverted: strip.flattenToMaxChannel(inverted: true)
        }
        guard var image = strip.makeImage() else { return nil }
        if upscale != 1, let enlarged = PixelBuffer(image, scale: upscale)?.makeImage() { image = enlarged }
        let pass = Pass(handler: VNImageRequestHandler(cgImage: image, options: [:]),
                        imageSize: CGSize(width: strip.width, height: strip.height), options: options)
        guard let found = try? pass.run(languages: languages, autodetect: autodetect, region: nil) else { return nil }
        // The reading that starts where the row starts.
        let middle = line.box.midY - CGFloat(top)
        let candidates = Self.mergeIntoLines(found).filter { !$0.detached && $0.box.minY < middle && $0.box.maxY > middle }
        guard var best = candidates.min(by: { abs($0.box.minX - line.box.minX) < abs($1.box.minX - line.box.minX) }),
              abs(best.box.minX - line.box.minX) < line.box.height else { return nil }
        best.box = best.box.offsetBy(dx: 0, dy: CGFloat(top))
        // The same model's second reading has the same habit with the bracket of a name.
        best.glyphs = ScriptChoice.mendSpeakerBracket(best.glyphs)
        return best
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
