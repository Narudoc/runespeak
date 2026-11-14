import Foundation

/// Result of splitting one chat line (or one whole message) into its parts.
public struct ParsedChatLine: Equatable, Sendable {
    /// Leading timestamp as shown ("21:04"), if the client prints one.
    public var timestamp: String?
    public var channel: ChatChannel
    /// Channel tag without brackets ("Guild", "2. 거래 - 도시"); nil when the game shows none.
    public var channelLabel: String?
    /// Speaker without brackets and realm; nil when the line has none.
    public var sender: String?
    public var body: String
    /// True when a "[Channel] [Name]:" / "[Name] says:" style header was recognised, i.e. the
    /// line is the first screen line of a message rather than a wrapped continuation.
    public var hasPrefix: Bool

    // Header pieces as read, kept for line comparison (the name here still has its realm).
    var headerTag: String = ""
    var headerName: String = ""
}

/// Default WoW chat colours, used only when the text itself does not say which channel a line is.
public enum ChatColors {
    private struct Ref { let r: Double, g: Double, b: Double; let channel: ChatChannel }

    // ChatTypeInfo defaults (approximate). Loot/XP/skill/honour colours all mean "system".
    private static let refs: [Ref] = [
        Ref(r: 1, g: 1, b: 1, channel: .say),
        Ref(r: 1, g: 1, b: 0.62, channel: .say),            // creature say
        Ref(r: 1, g: 0.25, b: 0.25, channel: .yell),
        Ref(r: 0.67, g: 0.67, b: 1, channel: .party),
        Ref(r: 0.46, g: 0.78, b: 1, channel: .party),       // party leader
        Ref(r: 1, g: 0.5, b: 0, channel: .raid),
        Ref(r: 1, g: 0.28, b: 0.04, channel: .raidWarning),
        Ref(r: 0.25, g: 1, b: 0.25, channel: .guild),
        Ref(r: 1, g: 0.5, b: 1, channel: .whisper),
        Ref(r: 0, g: 1, b: 0.96, channel: .whisper),        // Battle.net whisper
        Ref(r: 1, g: 0.75, b: 0.75, channel: .publicChannel),
        Ref(r: 1, g: 1, b: 0, channel: .system),
        Ref(r: 0, g: 0.67, b: 0, channel: .system),         // loot
        Ref(r: 0.44, g: 0.44, b: 1, channel: .system),      // experience
        Ref(r: 0.33, g: 0.33, b: 1, channel: .system),      // skill
        Ref(r: 0.88, g: 0.79, b: 0.04, channel: .system),   // honour
        Ref(r: 1, g: 0.5, b: 0.25, channel: .emote),
    ]

    /// Channel whose default colour is nearest to `color`, nil when nothing is close.
    /// Guild and officer green differ only in brightness, as do raid and instance (identical),
    /// so the answer for those pairs is a best guess.
    public static func channel(for color: RGBColor) -> ChatChannel? {
        let peak = max(color.r, max(color.g, color.b))
        guard peak > 0.2 else { return nil }
        // Glyph colours sampled from a screenshot are darkened by anti-aliasing against the
        // background; hue survives, brightness does not, so compare at full brightness.
        let r = color.r / peak, g = color.g / peak, b = color.b / peak
        var best: ChatChannel?
        var bestDistance = Double.infinity
        for ref in refs {
            let rp = max(ref.r, max(ref.g, ref.b))
            let dr = r - ref.r / rp, dg = g - ref.g / rp, db = b - ref.b / rp
            let d = (dr * dr + dg * dg + db * db).squareRoot()
            if d < bestDistance { bestDistance = d; best = ref.channel }
        }
        guard bestDistance <= 0.24, let found = best else { return nil }
        if found == .guild && peak < 0.86 && peak > 0.6 { return .officer }
        return found
    }

    static func distance(_ a: RGBColor, _ b: RGBColor) -> Double {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

/// Splits chat lines of koKR and enUS clients into channel / sender / body, tolerating the usual
/// OCR damage to brackets and colons.
public enum ChatLineParser {

    /// `color` is a secondary signal: it decides the channel only when the text has no readable tag.
    public static func parse(_ text: String, locale: ClientLocale, color: RGBColor? = nil) -> ParsedChatLine {
        var scanner = Scanner(text: text, locale: locale)
        var result = scanner.run()
        // A bracket-less "Name says:" in a colour that is not say/yell/whisper is a wrapped
        // sentence that happens to read like a header.
        if scanner.weak, let c = color.flatMap(ChatColors.channel(for:)), c != result.channel {
            result = ParsedChatLine(timestamp: nil, channel: .unknown, channelLabel: nil, sender: nil,
                                    body: text.trimmingCharacters(in: .whitespaces), hasPrefix: false)
            scanner.tagKnown = false
            scanner.bareName = false
        }
        resolveChannelByColour(&result, color: color, tagKnown: scanner.tagKnown, bareName: scanner.bareName)
        return result
    }

    private static func resolveChannelByColour(_ p: inout ParsedChatLine, color: RGBColor?, tagKnown: Bool, bareName: Bool) {
        let byColour = color.flatMap(ChatColors.channel(for:))
        if !p.hasPrefix {
            switch byColour {
            case .system?: p.channel = .system
            case .emote?:
                p.channel = .emote
                p.sender = emoteSubject(p.body)
            default: p.channel = .unknown
            }
            return
        }
        if tagKnown { return }
        if bareName {
            // "[Name]: text" is /say on some client versions, but it is also what is left of any
            // channel line whose tag fell outside the captured region.
            if let c = byColour, c != .system, c != .emote { p.channel = c } else { p.channel = .say }
            return
        }
        // "[???] [Name]: text" with an unreadable tag.
        if let c = byColour, c != .system, c != .emote, c != .say { p.channel = c }
    }

    /// "Thrall waves at you." → "Thrall";  "스랄님이 손을 흔듭니다." → "스랄".
    private static func emoteSubject(_ body: String) -> String? {
        guard let first = body.split(separator: " ").first.map(String.init) else { return nil }
        var name = first
        for suffix in ["님이", "님은", "님의", "님을", "님께서"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name.removeLast(suffix.count)
            return name
        }
        while let last = name.last, last.isPunctuation { name.removeLast() }
        guard let head = name.unicodeScalars.first, head.properties.isUppercase,
              name.count >= 2, name.count <= 24, name.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }) else { return nil }
        return stripRealm(name)
    }

    static func stripRealm(_ name: String) -> String {
        guard let dash = name.firstIndex(where: { $0 == "-" || $0 == "–" || $0 == "—" }) else { return name }
        let left = name[..<dash]
        return left.count >= 2 ? String(left) : name
    }

    // MARK: - Tag tables

    struct Tag {
        let label: String
        let channel: ChatChannel
        let skeleton: [UInt32]
        init(_ label: String, _ channel: ChatChannel) {
            self.label = label; self.channel = channel; self.skeleton = TextFold.skeleton(label)
        }
    }

    static let tags: [Tag] = [
        Tag("Guild", .guild), Tag("Officer", .officer),
        Tag("Party", .party), Tag("Party Leader", .party), Tag("Dungeon Guide", .party),
        Tag("Raid", .raid), Tag("Raid Leader", .raid), Tag("Raid Warning", .raidWarning),
        Tag("Instance", .instance), Tag("Instance Leader", .instance),
        Tag("Battleground", .instance), Tag("Battleground Leader", .instance),
        Tag("길드", .guild), Tag("길드관리자", .officer), Tag("길드 관리자", .officer), Tag("관리자", .officer),
        Tag("파티", .party), Tag("파티장", .party), Tag("던전 길잡이", .party),
        Tag("공격대", .raid), Tag("공격대장", .raid), Tag("공격대 경보", .raidWarning),
        Tag("인스턴스", .instance), Tag("인스턴스 파티장", .instance), Tag("인스턴스 지휘관", .instance),
        Tag("전장", .instance), Tag("전장 지휘관", .instance),
    ]
    static let tagsBySkeleton: [[UInt32]: Tag] = Dictionary(tags.map { ($0.skeleton, $0) }, uniquingKeysWith: { a, _ in a })

    // One-/two-letter tags that chat addons substitute; trusted only inside clean brackets.
    static let shortTags: [String: (String, ChatChannel)] = [
        "G": ("Guild", .guild), "O": ("Officer", .officer), "P": ("Party", .party), "PL": ("Party Leader", .party),
        "R": ("Raid", .raid), "RL": ("Raid Leader", .raid), "RW": ("Raid Warning", .raidWarning),
        "I": ("Instance", .instance), "IL": ("Instance Leader", .instance), "BG": ("Battleground", .instance),
    ]

    enum SpeechKind { case say, yell, whisperIn, whisperOut }

    struct Particle {
        let text: String
        let kind: SpeechKind
        let skeleton: [UInt32]
        init(_ text: String, _ kind: SpeechKind) { self.text = text; self.kind = kind; self.skeleton = TextFold.skeleton(text) }
    }
    static let englishVerbs: [Particle] = [
        Particle("says", .say), Particle("yells", .yell), Particle("whispers", .whisperIn),
    ]
    // Longest first: "의 귓속말" must win over "의 말".
    static let koreanParticles: [Particle] = [
        Particle("님에게 귓속말", .whisperOut), Particle("에게 귓속말", .whisperOut), Particle("님의 귓속말", .whisperIn),
        Particle("의 귓속말", .whisperIn), Particle("의 외침", .yell), Particle("님에게", .whisperOut),
        Particle("님의 말", .say), Particle("의 말", .say),
    ]

    /// `wellFormed`: the tag sits in intact brackets, which makes a short near-miss believable.
    static func matchTag(_ content: String, wellFormed: Bool = false) -> Tag? {
        let sk = TextFold.skeleton(content)
        if sk.isEmpty { return nil }
        if let exact = tagsBySkeleton[sk] { return exact }
        var best: Tag?
        var bestDistance = Int.max
        for tag in tags where tag.skeleton.count >= (wellFormed ? 4 : 5) {
            let limit = tag.skeleton.count >= 10 ? 2 : 1
            if let d = TextFold.distance(sk, tag.skeleton, limit: limit), d < bestDistance {
                bestDistance = d; best = tag
            }
        }
        return best
    }

    /// "1. General - Elwynn Forest", "2. 거래 - 도시", "4. LookingForGroup"; the digit may be read as I/l.
    static func isNumberedChannel(_ content: String) -> Bool {
        let chars = Array(content.trimmingCharacters(in: .whitespaces))
        var k = 0
        var real = 0
        while k < chars.count, k < 2, "0123456789IlO|".contains(chars[k]) {
            if chars[k].isASCII && chars[k].isNumber { real += 1 }
            k += 1
        }
        // "[. 일반]": the digit itself was lost.
        guard k >= 1 || chars.first == ".", k < chars.count else { return false }
        if k == 0 { real = 1 }
        var sawDot = false
        while k < chars.count, chars[k] == " " { k += 1 }
        if k < chars.count, ".,".contains(chars[k]) { sawDot = true; k += 1 }
        guard sawDot else { return false }
        let hadSpace = k < chars.count && chars[k] == " "
        while k < chars.count, chars[k] == " " { k += 1 }
        guard k < chars.count, chars[k].isLetter else { return false }
        // A digit read as a letter is only believable in the exact "l. Name" shape.
        return real >= 1 || hadSpace
    }

    // MARK: - Scanner

    private struct Header {
        var channel: ChatChannel
        var label: String?
        var name: String?
        var tagForKey: String
        var tagKnown: Bool
        var bareName: Bool = false
        /// Addon-style one-letter tag: believable only next to a fully bracketed name.
        var short: Bool = false
        /// Recognised without any bracket ("Hogger says: ..."): colour may veto it.
        var weak: Bool = false
    }

    private struct Scanner {
        let raw: [Character]
        let norm: [Character]
        let locale: ClientLocale
        var tagKnown = false
        var bareName = false
        var weak = false

        static let openers: Set<Character> = ["[", "(", "{"]
        static let closers: Set<Character> = ["]", ")", "}"]
        static let damagedOpeners: Set<Character> = ["|", "I", "l", "1", "!"]
        static let damagedClosers: Set<Character> = ["|", "J", "I", "l", "1", "!"]

        init(text: String, locale: ClientLocale) {
            let chars = Array(text)
            raw = chars
            norm = chars.map(Scanner.normalize)
            self.locale = locale
        }

        /// One-to-one character folding so indices into `norm` are indices into `raw`.
        static func normalize(_ c: Character) -> Character {
            guard c.unicodeScalars.count == 1, let u = c.unicodeScalars.first else { return c }
            switch u.value {
            case 0xFF01...0xFF5E: return Character(UnicodeScalar(u.value - 0xFEE0)!)
            case 0x3000, 0x00A0, 0x2009, 0x200A, 0x202F: return " "
            case 0x3010, 0x3014, 0x3016, 0x3018, 0x301A, 0x300C, 0x300E, 0xFF62: return "["
            case 0x3011, 0x3015, 0x3017, 0x3019, 0x301B, 0x300D, 0x300F, 0xFF63: return "]"
            case 0x2236, 0xFE30, 0xFE55, 0xA789, 0x02D0: return ":"
            case 0xFE54, 0x204F: return ";"
            default: return c
            }
        }

        var count: Int { norm.count }

        func skipSpaces(_ i: Int) -> Int {
            var k = i
            while k < count, norm[k] == " " || norm[k] == "\t" { k += 1 }
            return k
        }

        func string(_ range: Range<Int>, raw useRaw: Bool = false) -> String {
            String((useRaw ? raw : norm)[range])
        }

        func body(from i: Int) -> String {
            guard i < count else { return "" }
            return String(raw[i...]).trimmingCharacters(in: .whitespaces)
        }

        // MARK: timestamp

        /// "[21:04]", "[21:04:33]", "21:04:33", "9:04 PM", "오후 9:04". Returns the text and the index after it.
        func scanTimestamp(_ start: Int) -> (text: String, end: Int, strong: Bool)? {
            var k = start
            var bracket = false
            if k < count, Scanner.openers.contains(norm[k]) { bracket = true; k += 1 }
            let textStart = k
            var real = 0
            func digits(_ k: inout Int, min: Int, max: Int) -> Bool {
                var n = 0
                while k < count, n < max, "0123456789OolI".contains(norm[k]) {
                    if norm[k].isNumber { real += 1 }
                    k += 1; n += 1
                }
                return n >= min
            }
            func meridiem(_ k: inout Int) {
                for word in ["오전", "오후", "AM", "PM", "am", "pm"] {
                    let w = Array(word)
                    if k + w.count <= count, Array(norm[k..<k + w.count]) == w { k += w.count; return }
                }
            }
            let beforeMeridiem = k
            meridiem(&k)
            if k != beforeMeridiem { k = skipSpaces(k) }
            guard digits(&k, min: 1, max: 2), k < count else { return nil }
            let sep = norm[k]
            guard sep == ":" || (bracket && sep == ".") else { return nil }
            k += 1
            guard digits(&k, min: 2, max: 2) else { return nil }
            var groups = 2
            if k + 2 < count, norm[k] == sep {
                var k2 = k + 1
                if digits(&k2, min: 2, max: 2) { k = k2; groups = 3 }
            }
            guard real >= 2 else { return nil }
            if k < count, "0123456789".contains(norm[k]) { return nil }
            let afterDigits = k
            let spaced = skipSpaces(k)
            var k3 = spaced
            meridiem(&k3)
            if k3 != spaced { k = k3 } else { k = afterDigits }
            let textEnd = k
            if bracket {
                guard k < count, Scanner.closers.contains(norm[k]) || Scanner.damagedClosers.contains(norm[k]) else { return nil }
                k += 1
            } else {
                guard k >= count || norm[k] == " " else { return nil }
            }
            return (string(textStart..<textEnd), k, bracket || groups == 3)
        }

        // MARK: groups and names

        /// A cleanly bracketed group starting at `i`: content range and the index after the closer.
        func scanGroup(_ i: Int) -> (content: Range<Int>, end: Int)? {
            guard i < count, Scanner.openers.contains(norm[i]) else { return nil }
            var k = i + 1
            while k < count, k - i <= 52 {
                let c = norm[k]
                if Scanner.closers.contains(c) {
                    return k > i + 1 ? (i + 1..<k, k + 1) : nil
                }
                if Scanner.openers.contains(c) || c == ":" { return nil }
                k += 1
            }
            return nil
        }

        struct Name { var text: String; var leftEvidence: Int; var rightEvidence: Int }

        /// Reads `field` as a player name with possibly damaged brackets. Evidence: 2 = real bracket,
        /// 1 = a letter that brackets are commonly misread as, 0 = none.
        func cleanName(_ field: ArraySlice<Character>, allowSpaces: Bool = false) -> Name? {
            var chars = Array(field)
            func trim() {
                while let f = chars.first, f == " " { chars.removeFirst() }
                while let l = chars.last, l == " " { chars.removeLast() }
            }
            trim()
            // Status flags: "<AFK>", "<DND>", "<자리 비움>".
            while chars.first == "<", let close = chars.firstIndex(of: ">"), close < 14 {
                chars.removeSubrange(0...close)
                trim()
            }
            var left = 0, right = 0
            if let f = chars.first, Scanner.openers.contains(f) || f == "|" {
                left = 2; chars.removeFirst()
            }
            if let l = chars.last, Scanner.closers.contains(l) || l == "|" {
                right = 2; chars.removeLast()
            }
            trim()
            // "[NameJ": a capital glued to the end of a name is a misread bracket.
            if right == 0, chars.count >= 3, let l = chars.last, "JI1!".contains(l),
               let before = chars.dropLast().last, before.isLowercase || Scanner.isHangul(before) {
                right = 1; chars.removeLast()
            }
            // "IName]", "CJaina]": likewise at the front, when the real name visibly starts after
            // it. Names have a single capital, so a second capital gives the first one away.
            if left == 0, chars.count >= 3, let f = chars.first {
                let next = chars[1]
                if "Il1!".contains(f), next.isUppercase || Scanner.isHangul(next) || Scanner.isCJK(next) {
                    left = 1; chars.removeFirst()
                } else if f.isASCII, f.isLetter || f.isNumber, next.isASCII, next.isUppercase, chars[2].isLowercase {
                    left = 1; chars.removeFirst()
                }
            }
            // "[Pedroj", "CJainal": the closing bracket read as a thin letter. After a real "["
            // only "j" is taken for one ("[Thrall" simply lost its bracket); when the opening
            // bracket was misread too, the whole name group is evidently in bad shape.
            if right == 0, left > 0, chars.count >= 3, let l = chars.last,
               "jJ!".contains(l) || (left == 1 && "lI1".contains(l)) {
                right = 1; chars.removeLast()
            }
            guard !chars.isEmpty, chars.count <= 40 else { return nil }
            var letters = 0, spaces = 0
            for c in chars {
                if c.isLetter { letters += 1 }
                else if c == " " { spaces += 1 }
                else if c.isNumber || c == "-" || c == "'" || c == "–" || c == "’" { continue }
                else { return nil }
            }
            guard letters >= 1 else { return nil }
            if spaces > 0 && !(allowSpaces && spaces <= 4) { return nil }
            return Name(text: String(chars), leftEvidence: left, rightEvidence: right)
        }

        /// Capitalised words (NPC and player names), or any non-Latin name.
        static func looksLikeName(_ text: String) -> Bool {
            let small: Set<Substring> = ["of", "the", "von", "de", "la", "el"]
            let words = text.split(separator: " ")
            guard !words.isEmpty else { return false }
            for (n, w) in words.enumerated() {
                guard let f = w.first else { return false }
                if f.isASCII {
                    if f.isUppercase { continue }
                    if n > 0 && small.contains(w) { continue }
                    return false
                }
            }
            return true
        }

        static func isHangul(_ c: Character) -> Bool {
            guard let v = c.unicodeScalars.first?.value else { return false }
            return (v >= 0xAC00 && v <= 0xD7A3) || (v >= 0x3131 && v <= 0x318E)
        }
        static func isCJK(_ c: Character) -> Bool {
            guard let v = c.unicodeScalars.first?.value else { return false }
            return (v >= 0x3040 && v <= 0x30FF) || (v >= 0x3400 && v <= 0x9FFF)
        }

        /// A channel tag with possibly damaged brackets.
        func cleanTag(_ field: ArraySlice<Character>) -> (header: Header, evidence: Int)? {
            var chars = Array(field)
            while let f = chars.first, f == " " { chars.removeFirst() }
            while let l = chars.last, l == " " { chars.removeLast() }
            while let l = chars.last, l == ":" || l == ";" || l == " " { chars.removeLast() }
            guard chars.count >= 2 else { return nil }
            var evidence = 0
            var realBrackets = 0
            if let f = chars.first, Scanner.openers.contains(f) || f == "|" { evidence += 2; realBrackets += 1; chars.removeFirst() }
            if let l = chars.last, Scanner.closers.contains(l) || l == "|" { evidence += 2; realBrackets += 1; chars.removeLast() }
            guard !chars.isEmpty else { return nil }
            let content = String(chars).trimmingCharacters(in: .whitespaces)
            if realBrackets == 2 {
                if ChatLineParser.isNumberedChannel(content) {
                    return (Header(channel: .publicChannel, label: content, name: nil, tagForKey: content, tagKnown: true), evidence)
                }
                if let short = ChatLineParser.shortTags[content.uppercased()] {
                    return (Header(channel: short.1, label: content, name: nil, tagForKey: short.0, tagKnown: true, short: true), evidence)
                }
                // "[Z. 거래]": the channel number read as a letter.
                let c = Array(content)
                if c.count >= 4, c[0].isLetter, c[0].isASCII, c[1] == ".", c[2] == " ", c[3].isLetter {
                    return (Header(channel: .publicChannel, label: content, name: nil, tagForKey: content, tagKnown: true, short: true), evidence)
                }
            } else if realBrackets == 1, ChatLineParser.isNumberedChannel(content),
                      content.first.map({ $0.isNumber }) == true {
                return (Header(channel: .publicChannel, label: content, name: nil, tagForKey: content, tagKnown: true), evidence)
            }
            // Try the content as is, then with misread bracket letters peeled off either end.
            var variants: [(String, Int)] = [(content, evidence)]
            if realBrackets < 2 {
                if let f = chars.first, Scanner.damagedOpeners.contains(f), chars.count > 2 {
                    variants.append((String(chars.dropFirst()), evidence + 1))
                    if let l = chars.last, Scanner.damagedClosers.contains(l), chars.count > 3 {
                        variants.append((String(chars.dropFirst().dropLast()), evidence + 2))
                    }
                }
                if let l = chars.last, Scanner.damagedClosers.contains(l), chars.count > 2 {
                    variants.append((String(chars.dropLast()), evidence + 1))
                }
            }
            for (candidate, ev) in variants {
                if let tag = ChatLineParser.matchTag(candidate, wellFormed: realBrackets == 2) {
                    return (Header(channel: tag.channel, label: tag.label, name: nil, tagForKey: tag.label, tagKnown: true), ev)
                }
            }
            if realBrackets >= 1, content.count <= 30 {
                // Unknown tag with at least one bracket left: keep it as the label, let colour pick
                // the channel. The caller decides whether the rest of the header makes it believable.
                return (Header(channel: .unknown, label: content, name: nil, tagForKey: content, tagKnown: false), evidence)
            }
            return nil
        }

        // MARK: header before the colon

        func speech(_ kind: SpeechKind) -> ChatChannel {
            switch kind {
            case .say: return .say
            case .yell: return .yell
            case .whisperIn, .whisperOut: return .whisper
            }
        }

        var outgoingLabel: String { locale == .koKR ? "귓속말 보냄" : "To" }

        /// Parses everything between the timestamp and the header colon.
        func parseHead(_ head: ArraySlice<Character>) -> Header? {
            let lo = head.startIndex, hi = head.endIndex
            guard lo < hi else { return nil }

            // 1. "[Tag] [Name]" — try every plausible boundary between the two.
            var unknownTagged: Header?
            var cuts: [Int] = []
            for k in (lo + 1)..<hi {
                let c = norm[k], p = norm[k - 1]
                if c == " " || p == " " || Scanner.openers.contains(c) || Scanner.closers.contains(p) { cuts.append(k) }
            }
            for cut in cuts {
                guard let tag = cleanTag(head[lo..<cut]) else { continue }
                let rest = head[cut..<hi]
                if rest.allSatisfy({ $0 == " " }) { continue }
                guard let name = cleanName(rest) else { continue }
                let total = tag.evidence + name.leftEvidence + name.rightEvidence
                let real = (tag.evidence >= 2 ? 1 : 0) + (name.leftEvidence == 2 ? 1 : 0) + (name.rightEvidence == 2 ? 1 : 0)
                let nameEvidence = name.leftEvidence + name.rightEvidence
                // An unreadable tag is believable only inside an otherwise convincing header.
                if !tag.header.tagKnown {
                    let intact = tag.evidence == 4 && nameEvidence == 4
                    let damaged = tag.evidence >= 2 && (nameEvidence >= 2 || (nameEvidence >= 1 && total >= 4)
                        || (tag.evidence == 4 && Scanner.looksLikeName(name.text)))
                    if !(intact || damaged) { continue }
                    if name.text.contains(" ") { continue }
                }
                guard real >= 1 && total >= 3 else { continue }
                if tag.header.short && nameEvidence < 4 { continue }
                // "[Guild] Name" with both name brackets lost is accepted only for a name-like word.
                if nameEvidence == 0 && !(tag.evidence == 4 && Scanner.looksLikeName(name.text)) { continue }
                var h = tag.header
                h.name = name.text
                if h.tagKnown { return h }
                // An unreadable tag is a last resort: "[Name]님에게" must get the chance to be
                // read as a speech header first.
                if unknownTagged == nil { unknownTagged = h }
            }
            // A numbered channel or known tag alone before the colon: "[1. General]: ..." is not a
            // game format, so this is a tag whose name group was lost; leave it to the fallback.

            // 2. "[Name] says" / "[이름]의 말" / "이름님에게".
            if let h = parseSpeech(head) { return h }

            // 3. "To [Name]".
            let text = String(head)
            // A Battle.net friend's name has a space ("To [John Smith]"); that reading is only
            // trusted inside two real brackets.
            func spacedName() -> Name? {
                guard let n = cleanName(head[(lo + 3)..<hi], allowSpaces: true),
                      n.leftEvidence == 2, n.rightEvidence == 2 else { return nil }
                return n
            }
            if text.count > 3, text.lowercased().hasPrefix("to "),
               let name = cleanName(head[(lo + 3)..<hi]) ?? spacedName() {
                let evidence = name.leftEvidence + name.rightEvidence
                if evidence > 0 || Scanner.looksLikeName(name.text) {
                    return Header(channel: .whisper, label: outgoingLabel, name: name.text, tagForKey: "to",
                                  tagKnown: true, weak: evidence == 0)
                }
            }

            if let h = unknownTagged { return h }

            // 4. "[Name]" alone. A lone known tag is a header whose name group was lost, not a name.
            if let name = cleanName(head), name.leftEvidence + name.rightEvidence >= 3,
               ChatLineParser.tagsBySkeleton[TextFold.skeleton(name.text)] == nil {
                return Header(channel: .say, label: nil, name: name.text, tagForKey: "", tagKnown: false, bareName: true)
            }

            // 5. "[Name]<a few unreadable characters>": a speech header ("의 외침", "whispers") too
            // damaged to tell which; colour decides between say, yell and whisper.
            if let g = scanGroup(lo), g.end < hi, hi - g.end <= 10,
               let name = cleanName(head[lo..<g.end]),
               ChatLineParser.tagsBySkeleton[TextFold.skeleton(name.text)] == nil,
               !head[g.end..<hi].contains(where: { Scanner.openers.contains($0) || Scanner.closers.contains($0) }),
               head[g.end..<hi].contains(where: { $0.isLetter }) {
                return Header(channel: .say, label: nil, name: name.text, tagForKey: "", tagKnown: false, bareName: true)
            }
            return nil
        }

        func parseSpeech(_ head: ArraySlice<Character>) -> Header? {
            let lo = head.startIndex, hi = head.endIndex
            // English: last word is the verb.
            if let space = head.lastIndex(of: " "), space > lo {
                let verb = TextFold.skeleton(String(head[(space + 1)..<hi]))
                for v in ChatLineParser.englishVerbs where v.skeleton == verb {
                    if let name = cleanName(head[lo..<space], allowSpaces: true) {
                        let evidence = name.leftEvidence + name.rightEvidence
                        if evidence == 0 && !Scanner.looksLikeName(name.text) { continue }
                        return Header(channel: speech(v.kind), label: nil, name: name.text, tagForKey: v.text,
                                      tagKnown: true, weak: evidence == 0)
                    }
                }
            }
            // Korean: the particle follows the name directly ("[이름]의 말", "이름님에게").
            let compact = head.filter { $0 != " " }
            for p in ChatLineParser.koreanParticles {
                let particle = Array(p.text.filter { $0 != " " })
                guard compact.count > particle.count else { continue }
                let tail = Array(compact.suffix(particle.count))
                let exact = tail == particle
                let fuzzy = !exact && p.skeleton.count >= 5
                    && TextFold.distance(TextFold.skeleton(String(tail)), p.skeleton,
                                         limit: p.skeleton.count >= 10 ? 3 : 1) != nil
                guard exact || fuzzy else { continue }
                // Walk back over the particle in the spaced original.
                var k = hi, remaining = particle.count
                while remaining > 0, k > lo {
                    k -= 1
                    if norm[k] != " " { remaining -= 1 }
                }
                guard let name = cleanName(head[lo..<k], allowSpaces: true) else { continue }
                // A misread particle is only believable right after a bracketed name.
                if fuzzy && name.rightEvidence < 2 { continue }
                let label: String? = p.kind == .whisperOut ? outgoingLabel : nil
                return Header(channel: speech(p.kind), label: label, name: name.text, tagForKey: p.text,
                              tagKnown: true, weak: name.leftEvidence + name.rightEvidence == 0)
            }
            return nil
        }

        // MARK: run

        mutating func run() -> ParsedChatLine {
            var start = skipSpaces(0)
            // A stray mark in front of the first bracket is OCR picking up the window edge.
            if start + 2 < count, !norm[start].isLetter, !norm[start].isNumber,
               !Scanner.openers.contains(norm[start]), !Scanner.closers.contains(norm[start]),
               Scanner.openers.contains(norm[skipSpaces(start + 1)]) {
                start = skipSpaces(start + 1)
            }
            var timestamp: String?
            var i = start
            var weakTimestamp = false
            if let ts = scanTimestamp(start) {
                timestamp = ts.text
                i = skipSpaces(ts.end)
                weakTimestamp = !ts.strong
            }
            if let parsed = parseHeader(from: i, timestamp: timestamp) { return parsed }
            // "21:04 ..." with nothing chat-like after it is more likely a time inside a wrapped sentence.
            if weakTimestamp { timestamp = nil; i = start }
            return ParsedChatLine(timestamp: timestamp, channel: .unknown, channelLabel: nil, sender: nil,
                                  body: body(from: i), hasPrefix: false)
        }

        mutating func parseHeader(from i: Int, timestamp: String?) -> ParsedChatLine? {
            guard i < count else { return nil }
            // Header colon: the first ":" (or a ";" right after a bracket) near the start.
            var colons: [Int] = []
            var k = i
            while k < count, k - i <= 72, colons.count < 2 {
                let c = norm[k]
                if c == ":" { colons.append(k) }
                else if c == ";", k > i, Scanner.closers.contains(norm[k - 1]) { colons.append(k) }
                k += 1
            }
            for colon in colons {
                if let h = parseHead(norm[i..<colon]) {
                    return finish(h, timestamp: timestamp, bodyStart: colon + 1)
                }
            }
            // No usable colon: accept "[Tag] [Name] text" / "[Tag] text" when the tag is known.
            var tagEnd: Int?
            if let g1 = scanGroup(i) {
                tagEnd = g1.end
            } else if Scanner.openers.contains(norm[i]),
                      let open = (i + 2..<min(count, i + 22)).first(where: { Scanner.openers.contains(norm[$0]) }),
                      !norm[i..<open].contains(where: { Scanner.closers.contains($0) }) {
                tagEnd = open           // closing bracket lost: "[Guild [Name] ..."
            } else if let close = (i..<min(count, i + 26)).first(where: { Scanner.closers.contains(norm[$0]) }) {
                tagEnd = close + 1      // opening bracket misread: "PParty][Name] ..."
            }
            if let end = tagEnd, let tag = cleanTag(norm[i..<end]), tag.header.tagKnown, tag.evidence >= 2 {
                var h = tag.header
                var j = skipSpaces(end)
                while j < count, Scanner.closers.contains(norm[j]) { j = skipSpaces(j + 1) }
                if let g2 = scanGroup(j), let name = cleanName(norm[j..<g2.end]) {
                    h.name = name.text
                    var b = skipSpaces(g2.end)
                    if b < count, norm[b] == ":" || norm[b] == ";" || norm[b] == "." { b += 1 }
                    return finish(h, timestamp: timestamp, bodyStart: b)
                }
                // "[Guild] Name] text": one bracket of the name survived.
                var k = j
                while k < count, norm[k] != " ", k - j <= 30 { k += 1 }
                if k > j, k < count, let name = cleanName(norm[j..<k]),
                   name.leftEvidence == 2 || name.rightEvidence == 2 {
                    h.name = name.text
                    return finish(h, timestamp: timestamp, bodyStart: k)
                }
                // Short addon tags are too ambiguous without a name ("[R] anyone?").
                if h.short { return nil }
                return finish(h, timestamp: timestamp, bodyStart: j)
            }
            return nil
        }

        mutating func finish(_ h: Header, timestamp: String?, bodyStart: Int) -> ParsedChatLine {
            tagKnown = h.tagKnown
            bareName = h.bareName
            weak = h.weak
            var p = ParsedChatLine(timestamp: timestamp, channel: h.channel, channelLabel: h.label,
                                   sender: h.name.map(ChatLineParser.stripRealm), body: body(from: bodyStart),
                                   hasPrefix: true)
            p.headerTag = h.tagForKey
            p.headerName = h.name ?? ""
            return p
        }
    }
}
