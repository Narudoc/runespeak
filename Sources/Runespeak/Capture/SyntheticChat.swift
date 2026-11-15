import CoreGraphics
import CoreText
import Foundation
import RunespeakCore

/// Renders WoW-like chat screenshots with CoreText so the OCR pipeline can be measured without
/// the game (used by `--ocr-selftest`). Nothing here touches the screen.
enum SyntheticChat {

    // Default WoW chat colours (ChatTypeInfo defaults).
    enum Palette {
        static let say = RGBColor(r: 1, g: 1, b: 1)
        static let yell = RGBColor(r: 1, g: 0.25, b: 0.25)
        static let guild = RGBColor(r: 0.25, g: 1, b: 0.25)
        static let party = RGBColor(r: 0.67, g: 0.67, b: 1)
        static let raid = RGBColor(r: 1, g: 0.5, b: 0)
        static let whisper = RGBColor(r: 1, g: 0.5, b: 1)
        static let channel = RGBColor(r: 1, g: 0.75, b: 0.75)
        static let system = RGBColor(r: 1, g: 1, b: 0)
        // Item-link quality colours and a class colour, which must NOT win over the channel colour.
        static let legendary = RGBColor(r: 1, g: 0.5, b: 0)
        static let epic = RGBColor(r: 0.64, g: 0.21, b: 0.93)
        static let mageName = RGBColor(r: 0.25, g: 0.78, b: 0.92)
    }

    struct Segment {
        var text: String
        var color: RGBColor
    }

    struct Line {
        /// Language bucket for the report: "en", "ko", "es", "pt", "ru", "zh", "ja".
        var language: String
        /// Name of the chat colour this line must be classified as ("guild", "party", ...).
        var channel: String
        var channelColor: RGBColor
        var segments: [Segment]
        /// A wrapped row of the message above: drawn a little to the right, as the game does.
        var wrapped = false
        var text: String { segments.map(\.text).joined() }

        init(_ language: String, _ channel: String, _ color: RGBColor, _ text: String) {
            self.language = language; self.channel = channel; self.channelColor = color
            self.segments = [Segment(text: text, color: color)]
        }
        init(_ language: String, _ channel: String, _ color: RGBColor, segments: [Segment]) {
            self.language = language; self.channel = channel; self.channelColor = color
            self.segments = segments
        }
    }

    enum Background: String, CaseIterable {
        /// Chat frame hovered: world dimmed by a dark panel.
        case darkPanel
        /// Chat frame faded out: text straight over a mid-tone, busy world.
        case busy
        /// Worst case: text over a bright scene (snow, sky), only the shadow separates it.
        case bright
    }

    enum Edge: String, CaseIterable {
        case shadow    // WoW default: 1 px drop shadow
        case outline   // chat setting "outline"
    }

    struct Style {
        var fontName: String
        var pointSize: CGFloat
        var scale: CGFloat
        var background: Background
        var edge: Edge
        var label: String { "\(fontName) \(Int(pointSize))pt @\(Int(scale))x \(background.rawValue)/\(edge.rawValue)" }
    }

    /// Text of the game world showing through the chat window: the name floating over a
    /// character that stands behind it. Drawn under the chat, larger and outlined.
    struct WorldText {
        var text: String
        var color: RGBColor
        /// Chat row it shares a baseline with, and where it starts, in points from the right end
        /// of that row's text (negative: the two overlap).
        var row: Int
        var gap: CGFloat
        var sizeFactor: CGFloat = 1.25
    }

    struct Rendered {
        var image: CGImage
        var lines: [Line]
        /// Pixel boxes of the rendered lines, top-left origin, same order as `lines`.
        var boxes: [CGRect]
        var style: Style
    }

    /// Chat as a koKR client shows it (Korean channel tags, gothic font).
    static let koreanClientLines: [Line] = [
        Line("en", "guild", Palette.guild, "[길드] [Thrall]: need 1 more dps for mara"),
        Line("en", "channel", Palette.channel, segments: [
            Segment(text: "[2. 거래] [Jaina]: WTS ", color: Palette.channel),
            Segment(text: "[Thunderfury, Blessed Blade of the Windseeker]", color: Palette.legendary),
            Segment(text: " 500g", color: Palette.channel),
        ]),
        Line("en", "party", Palette.party, "[파티] [Anduin]: omw, 2 min. pull when rdy"),
        Line("en", "whisper", Palette.whisper, "[Varian]님의 귓속말: can u tank BRD? need 1 for arena/anger run"),
        Line("en", "raid", Palette.raid, "[공격대] [Sylvanas]: MT on skull, OT pick up adds @ 35%"),
        Line("en", "yell", Palette.yell, "[Garrosh]의 외침: LF2M UBRS need healer + dps, have key"),
        Line("ko", "guild", Palette.guild, "[길드] [달빛기사]: 오늘 저녁 9시에 화산심장부 가실 분 계신가요?"),
        Line("ko", "party", Palette.party, segments: [
            Segment(text: "[파티] [", color: Palette.party),
            Segment(text: "검은용", color: Palette.mageName),
            Segment(text: "]: 잠시만요 마나 좀 채우고 갈게요", color: Palette.party),
        ]),
        Line("ko", "system", Palette.system, "경험치 250을 획득했습니다. 전리품을 획득했습니다: 10골드"),
        Line("es", "guild", Palette.guild, "[길드] [Pedro]: ¿alguien para mazmorras? necesito más daño"),
        Line("pt", "channel", Palette.channel, "[1. 일반] [João]: alguém pode me ajudar com a missão? não consigo"),
        Line("ru", "guild", Palette.guild, "[길드] [Иван]: привет всем, кто идёт в рейд сегодня?"),
        Line("ru", "say", Palette.say, "[Наташа]: нужен танк и хил в подземелье"),
        Line("zh", "guild", Palette.guild, "[길드] [小明]: 有人一起打副本吗?我是治疗"),
        Line("zh", "whisper", Palette.whisper, "[阿強]님의 귓속말: 等我一下,馬上到"),
        Line("ja", "guild", Palette.guild, "[길드] [さくら]: こんにちは、ダンジョンに行きませんか?"),
        Line("ja", "party", Palette.party, "[파티] [タケシ]: よろしくお願いします"),
    ]

    /// Chat as an enUS client shows it (English channel tags, Arial Narrow).
    static let englishClientLines: [Line] = [
        Line("en", "guild", Palette.guild, "[Guild] [Thrall]: need 1 more dps for mara"),
        Line("en", "channel", Palette.channel, segments: [
            Segment(text: "[2. Trade] [Jaina]: WTS ", color: Palette.channel),
            Segment(text: "[Thunderfury, Blessed Blade of the Windseeker]", color: Palette.legendary),
            Segment(text: " 500g", color: Palette.channel),
        ]),
        Line("en", "party", Palette.party, "[Party] [Anduin]: omw, 2 min. pull when rdy"),
        Line("en", "whisper", Palette.whisper, "[Varian] whispers: can u tank BRD? need 1 for arena/anger run"),
        Line("en", "raid", Palette.raid, "[Raid] [Sylvanas]: MT on skull, OT pick up adds @ 35%"),
        Line("en", "yell", Palette.yell, "[Garrosh] yells: LF2M UBRS need healer + dps, have key"),
        Line("en", "system", Palette.system, "You receive loot: [Hearthstone]x2. Quest accepted: 15/20"),
        Line("ko", "guild", Palette.guild, "[Guild] [달빛기사]: 오늘 저녁 9시에 화산심장부 가실 분 계신가요?"),
        Line("ko", "party", Palette.party, segments: [
            Segment(text: "[Party] [", color: Palette.party),
            Segment(text: "검은용", color: Palette.mageName),
            Segment(text: "]: 잠시만요 마나 좀 채우고 갈게요", color: Palette.party),
        ]),
        Line("es", "guild", Palette.guild, "[Guild] [Pedro]: ¿alguien para mazmorras? necesito más daño"),
        Line("pt", "channel", Palette.channel, "[1. General] [João]: alguém pode me ajudar com a missão? não consigo"),
        Line("ru", "guild", Palette.guild, "[Guild] [Иван]: привет всем, кто идёт в рейд сегодня?"),
        Line("ru", "say", Palette.say, "[Наташа] says: нужен танк и хил в подземелье"),
        Line("zh", "guild", Palette.guild, "[Guild] [小明]: 有人一起打副本吗?我是治疗"),
        Line("zh", "whisper", Palette.whisper, "[阿強] whispers: 等我一下,馬上到"),
        Line("ja", "guild", Palette.guild, "[Guild] [さくら]: こんにちは、ダンジョンに行きませんか?"),
        Line("ja", "party", Palette.party, "[Party] [タケシ]: よろしくお願いします"),
    ]

    static func lines(for locale: ClientLocale) -> [Line] {
        locale == .koKR ? koreanClientLines : englishClientLines
    }

    /// Closest stand-ins for the game fonts that ship with macOS: the koKR client draws chat in a
    /// gothic face (2002.ttf), the enUS client in Arial Narrow.
    static func fontName(for locale: ClientLocale) -> String {
        locale == .koKR ? "AppleSDGothicNeo-Medium" : "ArialNarrow"
    }

    /// `canvasPoints` fixes the picture size (lines that do not fit are clipped, as in a real
    /// chat window); nil sizes the picture to the text.
    static func render(lines: [Line], style: Style, canvasPoints: CGSize? = nil, world: [WorldText] = []) -> Rendered? {
        let s = style.scale
        let font = CTFontCreateWithName(style.fontName as CFString, style.pointSize * s, nil)
        let lineHeight = ceil(style.pointSize * 1.3 * s)
        let margin = 6 * s
        let ctLines: [(fill: CTLine, dark: CTLine, stroke: CTLine)] = lines.map { line in
            (attributed(line, font: font, mode: .fill),
             attributed(line, font: font, mode: .dark),
             attributed(line, font: font, mode: .stroke(width: 2 * s)))
        }
        let maxWidth = ctLines.map { CTLineGetTypographicBounds($0.fill, nil, nil, nil) }.max() ?? 0
        let width = canvasPoints.map { Int($0.width * s) } ?? Int(ceil(maxWidth + margin * 2))
        let height = canvasPoints.map { Int($0.height * s) } ?? Int(lineHeight * CGFloat(lines.count) + margin * 2)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        drawBackground(ctx, width: width, height: height, kind: style.background)
        // The game renders greyscale-antialiased glyphs, never LCD subpixel text.
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldAntialias(true)

        // The game indents wrapped rows by a fixed step of about 0.4 line heights.
        let indent = (0.42 * lineHeight).rounded()
        func geometry(_ i: Int) -> (x: CGFloat, baselineY: CGFloat, width: CGFloat, ascent: CGFloat, descent: CGFloat) {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(ctLines[i].fill, &ascent, &descent, &leading))
            let top = margin + CGFloat(i) * lineHeight
            // CoreGraphics origin is bottom-left.
            let baselineY = CGFloat(height) - top - ascent - (lineHeight - ascent - descent) / 2
            return (margin + (lines[i].wrapped ? indent : 0), baselineY, w, ascent, descent)
        }

        for item in world where lines.indices.contains(item.row) {
            let g = geometry(item.row)
            let big = CTFontCreateWithName(style.fontName as CFString, style.pointSize * s * item.sizeFactor, nil)
            let label = Line("", "", item.color, item.text)
            ctx.setLineJoin(.round)
            ctx.textPosition = CGPoint(x: g.x + g.width + item.gap * s, y: g.baselineY)
            CTLineDraw(attributed(label, font: big, mode: .stroke(width: 2 * s)), ctx)
            ctx.textPosition = CGPoint(x: g.x + g.width + item.gap * s, y: g.baselineY)
            CTLineDraw(attributed(label, font: big, mode: .fill), ctx)
        }

        var boxes: [CGRect] = []
        for (i, l) in ctLines.enumerated() {
            let g = geometry(i)
            switch style.edge {
            case .shadow:
                ctx.textPosition = CGPoint(x: g.x + s, y: g.baselineY - s)
                CTLineDraw(l.dark, ctx)
            case .outline:
                ctx.setLineJoin(.round)
                ctx.textPosition = CGPoint(x: g.x, y: g.baselineY)
                CTLineDraw(l.stroke, ctx)
            }
            ctx.textPosition = CGPoint(x: g.x, y: g.baselineY)
            CTLineDraw(l.fill, ctx)
            let boxTop = CGFloat(height) - (g.baselineY + g.ascent)
            boxes.append(CGRect(x: g.x, y: boxTop, width: g.width, height: g.ascent + g.descent))
        }
        guard let image = ctx.makeImage() else { return nil }
        return Rendered(image: image, lines: lines, boxes: boxes, style: style)
    }

    // MARK: - Private

    private enum Mode {
        case fill
        case dark
        case stroke(width: CGFloat)
    }

    private static func attributed(_ line: Line, font: CTFont, mode: Mode) -> CTLine {
        let result = NSMutableAttributedString()
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        for seg in line.segments {
            var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let fg = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
            switch mode {
            case .fill:
                attrs[fg] = CGColor(srgbRed: seg.color.r, green: seg.color.g, blue: seg.color.b, alpha: 1)
            case .dark:
                attrs[fg] = black
            case .stroke(let width):
                attrs[fg] = black
                attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = black
                // Positive percentage of the font size = stroke only.
                attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] =
                    Double(width / CTFontGetSize(font) * 100)
            }
            result.append(NSAttributedString(string: seg.text, attributes: attrs))
        }
        return CTLineCreateWithAttributedString(result)
    }

    private struct LCG {
        var state: UInt64
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }
    }

    /// A deterministic "game world": gradient plus blobs and hard-edged shapes, optionally dimmed.
    private static func drawBackground(_ ctx: CGContext, width: Int, height: Int, kind: Background) {
        let w = CGFloat(width), h = CGFloat(height)
        var rng = LCG(state: 0x5EED_CAFE)
        let base: (lo: CGFloat, hi: CGFloat)
        switch kind {
        case .darkPanel, .busy: base = (0.15, 0.75)
        case .bright: base = (0.72, 0.97)
        }
        func shade() -> CGColor {
            let v = base.lo + (base.hi - base.lo) * rng.next()
            return CGColor(srgbRed: min(1, v * (0.8 + 0.4 * rng.next())),
                           green: min(1, v * (0.8 + 0.4 * rng.next())),
                           blue: min(1, v * (0.8 + 0.4 * rng.next())), alpha: 1)
        }
        ctx.setFillColor(shade())
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for i in 0..<140 {
            ctx.setFillColor(shade())
            let bw = 20 + rng.next() * w * 0.25, bh = 8 + rng.next() * h * 0.3
            let r = CGRect(x: rng.next() * w - bw / 2, y: rng.next() * h - bh / 2, width: bw, height: bh)
            if i % 2 == 0 { ctx.fillEllipse(in: r) } else { ctx.fill(r) }
        }
        // Thin bright strokes: grass, branches, UI edges — the kind of clutter OCR mistakes for glyphs.
        for _ in 0..<60 {
            ctx.setStrokeColor(shade())
            ctx.setLineWidth(1 + rng.next() * 2)
            let p = CGPoint(x: rng.next() * w, y: rng.next() * h)
            ctx.move(to: p)
            ctx.addLine(to: CGPoint(x: p.x + (rng.next() - 0.5) * 80, y: p.y + (rng.next() - 0.5) * 30))
            ctx.strokePath()
        }
        switch kind {
        case .darkPanel:
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        case .busy:
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        case .bright:
            break
        }
    }
}
