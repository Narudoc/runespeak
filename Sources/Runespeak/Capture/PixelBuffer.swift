import CoreGraphics
import Foundation
import RunespeakCore

/// RGBA8 sRGB copy of an image, row 0 at the TOP (same orientation as OCRLine.box).
struct PixelBuffer {
    let width: Int
    let height: Int
    private(set) var data: [UInt8]

    init?(_ image: CGImage, scale: CGFloat = 1, interpolation: CGInterpolationQuality = .high) {
        let w = Int((CGFloat(image.width) * scale).rounded())
        let h = Int((CGFloat(image.height) * scale).rounded())
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = interpolation
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w; height = h; data = bytes
    }

    private init(width: Int, height: Int, data: [UInt8]) {
        self.width = width; self.height = height; self.data = data
    }

    @inline(__always) func offset(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }

    /// Full-width copy of the pixel rows `rows`.
    func strip(_ rows: Range<Int>) -> PixelBuffer? {
        let lo = max(0, rows.lowerBound), hi = min(height, rows.upperBound)
        guard hi > lo else { return nil }
        return PixelBuffer(width: width, height: hi - lo, data: Array(data[(lo * width * 4)..<(hi * width * 4)]))
    }

    /// Hue of a colour with its brightness taken out, for comparing glyph colours that
    /// anti-aliasing has darkened by different amounts.
    static func chroma(_ c: RGBColor) -> (r: Double, g: Double, b: Double) {
        let peak = max(c.r, max(c.g, c.b))
        return peak > 0 ? (c.r / peak, c.g / peak, c.b / peak) : (0, 0, 0)
    }

    static func chromaDistance(_ a: RGBColor, _ b: RGBColor) -> Double {
        let x = chroma(a), y = chroma(b)
        let dr = x.r - y.r, dg = x.g - y.g, db = x.b - y.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// Share of the pixels of `rect` that are bright and drawn in the hue of `colour`.
    func share(of colour: RGBColor, in rect: CGRect) -> Double {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard r.width >= 1, r.height >= 1 else { return 0 }
        let c = PixelBuffer.chroma(colour)
        var hits = 0
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) {
                let o = offset(x, y)
                let v = Double(max(data[o], max(data[o + 1], data[o + 2])))
                guard v >= 90 else { continue }
                let dr = Double(data[o]) / v - c.r, dg = Double(data[o + 1]) / v - c.g, db = Double(data[o + 2]) / v - c.b
                if dr * dr + dg * dg + db * db < 0.06 { hits += 1 }
            }
        }
        return Double(hits) / Double(r.width * r.height)
    }

    /// Shares of the pixels of `rect` that are black, dim and bright (strongest channel up to
    /// 3, up to 70, above). Black means the black of an opaque panel, which is exact: a dark
    /// scene behind a translucent panel is dim, however dark.
    func darkness(in rect: CGRect) -> (black: Double, dim: Double, bright: Double) {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard r.width >= 1, r.height >= 1 else { return (0, 0, 0) }
        var black = 0, dim = 0, bright = 0
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) {
                let o = offset(x, y)
                let v = max(data[o], max(data[o + 1], data[o + 2]))
                if v <= 3 { black += 1 } else if v < 70 { dim += 1 } else { bright += 1 }
            }
        }
        let n = Double(r.width * r.height)
        return (Double(black) / n, Double(dim) / n, Double(bright) / n)
    }

    /// True when the text in `rect` stands on plain black: a chat window whose background is
    /// opaque. Nothing of the game world shows through such a window, so no word on it can be
    /// text of the world. Measured: rows on an opaque background are 73–87 % black with up to
    /// 11 % dim pixels (the soft edges of the glyphs); rows on the game's translucent
    /// background, however dark the scene behind, have next to no black pixel at all.
    func isOpaqueBlack(in rect: CGRect) -> Bool {
        let d = darkness(in: rect)
        return d.black >= 0.55 && d.dim <= 0.2
    }

    /// Paints over everything drawn in the hue of `colour`, sparing what is nearer to the hue of
    /// `keeping`: removes text of another colour that overlaps a chat row. The dark outline
    /// around the removed glyphs (within `reach` pixels of them) goes too, or its shapes would
    /// still read as letters. The paint is the average of the dark pixels left.
    mutating func erase(colour: RGBColor, keeping: RGBColor, reach: Int) {
        let f = PixelBuffer.chroma(colour), k = PixelBuffer.chroma(keeping)
        let w = width, h = height
        let dark: UInt8 = 90
        var mask = [Bool](repeating: false, count: w * h)
        var sum = (r: 0.0, g: 0.0, b: 0.0), n = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let o = offset(x, y)
                let peak = max(data[o], max(data[o + 1], data[o + 2]))
                let v = Double(peak)
                if v >= 40 {
                    let r = Double(data[o]) / v, g = Double(data[o + 1]) / v, b = Double(data[o + 2]) / v
                    let df = (r - f.r) * (r - f.r) + (g - f.g) * (g - f.g) + (b - f.b) * (b - f.b)
                    let dk = (r - k.r) * (r - k.r) + (g - k.g) * (g - k.g) + (b - k.b) * (b - k.b)
                    if df < 0.2, df < dk { mask[y * w + x] = true; continue }
                }
                if peak < dark {
                    sum.r += Double(data[o]); sum.g += Double(data[o + 1]); sum.b += Double(data[o + 2]); n += 1
                }
            }
        }
        guard mask.contains(true) else { return }
        // Grow the mask by `reach` in both directions, one axis at a time.
        var wide = mask
        for y in 0..<h {
            var last = -1 - reach
            for x in 0..<w where mask[y * w + x] {
                let hi = min(w - 1, x + reach)
                for t in max(0, last + 1, x - reach)..<(hi + 1) { wide[y * w + t] = true }
                last = hi
            }
        }
        var grown = wide
        for x in 0..<w {
            var last = -1 - reach
            for y in 0..<h where wide[y * w + x] {
                let hi = min(h - 1, y + reach)
                for t in max(0, last + 1, y - reach)..<(hi + 1) { grown[t * w + x] = true }
                last = hi
            }
        }
        let paint = n > 0 ? (UInt8(sum.r / n), UInt8(sum.g / n), UInt8(sum.b / n)) : (0, 0, 0)
        for i in 0..<(w * h) where grown[i] {
            let o = i * 4
            guard mask[i] || max(data[o], max(data[o + 1], data[o + 2])) < dark else { continue }
            data[o] = paint.0; data[o + 1] = paint.1; data[o + 2] = paint.2
        }
    }

    /// Replaces every pixel by a grey level derived from its strongest channel. Chat colours all
    /// have one channel near full intensity, so this makes dim-luminance colours (party blue,
    /// yell red) as bright as white text. `inverted` gives dark text on a light page.
    mutating func flattenToMaxChannel(inverted: Bool) {
        data.withUnsafeMutableBufferPointer { p in
            var i = 0
            let n = p.count
            while i < n {
                var v = max(p[i], max(p[i + 1], p[i + 2]))
                if inverted { v = 255 - v }
                p[i] = v; p[i + 1] = v; p[i + 2] = v
                i += 4
            }
        }
    }

    func makeImage() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Glyph colour

    /// Colour of the text drawn inside `rects` (pixel rects, top-left origin).
    ///
    /// Glyph pixels are told from the world behind them by two facts about WoW chat text: every
    /// glyph carries a dark drop shadow or outline on its lower-right side, and all glyph pixels of
    /// one chat line share one chromaticity while the background does not. Pixels with a much
    /// darker neighbour to the right/below vote into a chromaticity histogram; the brightest pixels
    /// of the winning bin (the stroke cores, least blended with the shadow) give the colour.
    ///
    /// With `besides`, pixels in the hue of that colour do not vote: the answer is the colour
    /// of whatever else is drawn there (text of the world through a chat word).
    func glyphColor(in rects: [CGRect], besides: RGBColor? = nil) -> RGBColor? {
        let skipping = besides != nil
        let skip = besides.map(PixelBuffer.chroma) ?? (r: 0, g: 0, b: 0)
        var votes = [Float](repeating: 0, count: 9 * 9 * 9)
        var samples: [(bin: Int, v: UInt8, off: Int)] = []
        samples.reserveCapacity(4096)

        for rect in rects {
            let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard r.width >= 2, r.height >= 2 else { continue }
            let x0 = Int(r.minX), x1 = Int(r.maxX), y0 = Int(r.minY), y1 = Int(r.maxY)
            // Shadow offset is 1 px in game units, i.e. up to ~2-3 device px on Retina; strokes are
            // about a tenth of the line height thick.
            let reach = max(2, min(5, (y1 - y0) / 7))
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let o = offset(x, y)
                    let pr = data[o], pg = data[o + 1], pb = data[o + 2]
                    let v = max(pr, max(pg, pb))
                    guard v >= 90 else { continue }
                    let darkLimit = Int(v) * 2 / 5
                    var hasShadow = false
                    var k = 1
                    while k <= reach && !hasShadow {
                        if x + k < width {
                            let n = offset(x + k, y)
                            if Int(max(data[n], max(data[n + 1], data[n + 2]))) < darkLimit { hasShadow = true }
                        }
                        if !hasShadow, y + k < height {
                            let n = offset(x, y + k)
                            if Int(max(data[n], max(data[n + 1], data[n + 2]))) < darkLimit { hasShadow = true }
                        }
                        k += 1
                    }
                    guard hasShadow else { continue }
                    if skipping {
                        let dv = Double(v)
                        let dr = Double(pr) / dv - skip.r, dg = Double(pg) / dv - skip.g, db = Double(pb) / dv - skip.b
                        if dr * dr + dg * dg + db * db < 0.12 { continue }
                    }
                    let fv = Float(v)
                    let bin = Int((Float(pr) / fv * 8).rounded()) * 81
                        + Int((Float(pg) / fv * 8).rounded()) * 9
                        + Int((Float(pb) / fv * 8).rounded())
                    // Brighter pixels are more likely stroke cores than antialiased fringe.
                    votes[bin] += fv
                    samples.append((bin, v, o))
                }
            }
        }
        guard samples.count >= 6, let best = votes.indices.max(by: { votes[$0] < votes[$1] }) else { return nil }

        var members = samples.filter { $0.bin == best }
        guard !members.isEmpty else { return nil }
        members.sort { $0.v > $1.v }
        let take = max(1, members.count / 4)
        var sr = 0.0, sg = 0.0, sb = 0.0
        for m in members.prefix(take) {
            sr += Double(data[m.off]); sg += Double(data[m.off + 1]); sb += Double(data[m.off + 2])
        }
        let n = Double(take) * 255
        return RGBColor(r: sr / n, g: sg / n, b: sb / n)
    }
}
