import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `--make-icon <png>`: draws the 1024 px app icon (used by scripts/build-app.sh).
enum IconMaker {
    static func run() -> Int32 {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--make-icon"), i + 1 < args.count else { return 2 }
        let url = URL(fileURLWithPath: args[i + 1])
        let size = 1024
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        let s = CGFloat(size)

        // Rounded dark tile with the usual macOS icon inset.
        let tile = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil))
        ctx.clip()
        let colors = [CGColor(srgbRed: 0.10, green: 0.16, blue: 0.32, alpha: 1),
                      CGColor(srgbRed: 0.04, green: 0.06, blue: 0.14, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
        }

        // Two chat lines: the foreign one in guild green, the Korean one in whisper pink.
        func draw(_ text: String, fontSize: CGFloat, color: CGColor, y: CGFloat) {
            let font = CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString, fontSize, nil)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(x: (s - width) / 2, y: y)
            CTLineDraw(line, ctx)
        }
        draw("LFG", fontSize: s * 0.21, color: CGColor(srgbRed: 0.25, green: 1, blue: 0.25, alpha: 1), y: s * 0.56)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
        ctx.setLineWidth(s * 0.012)
        ctx.move(to: CGPoint(x: s * 0.27, y: s * 0.5))
        ctx.addLine(to: CGPoint(x: s * 0.73, y: s * 0.5))
        ctx.strokePath()
        draw("번역", fontSize: s * 0.23, color: CGColor(srgbRed: 1, green: 0.5, blue: 1, alpha: 1), y: s * 0.24)

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return 1 }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? 0 : 1
    }
}
