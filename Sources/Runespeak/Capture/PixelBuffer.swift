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

    @inline(__always) func offset(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }

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
    func glyphColor(in rects: [CGRect]) -> RGBColor? {
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
