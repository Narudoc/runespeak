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
    /// The line is a header row that did not survive OCR in one piece: pieced together without
    /// its colon and a complete name group ("[1. General] some words", "[1. General] [Name some
    /// words", "[Some Name other words: text"), or not recognised as a header at all although
    /// it opens like one ("[1. Genxxxxx: text"; `hasPrefix` is false then). That is what a
    /// header row looks like while text of the game world covers part of it, so nothing behind
    /// its tag can be trusted to be what the player said. A wrapped row that starts with a
    /// link ("[Some Item] 5g") is marked too; where it stands tells the two apart.
    var headerBroken: Bool = false
    /// The damage is of the mildest kind: a name of several words behind "[" that no bracket
    /// closes, with the header colon (or speech particle) right behind it ("[1. General]
    /// [Some Name: text"). The speaker is a guess; what stands behind the colon was read as
    /// the body of a header row.
    var unclosedName: Bool = false
    /// The header is whole but for its speaker, which has a one-letter word in it ("[A Wexlay
    /// thoruwcods]"): what OCR makes of a name with another drawn over it - or, rarely,
    /// somebody's name.
    var oddName: Bool = false
    /// The header is whole but for the closing bracket of its numbered channel tag ("[1. General
    /// [Some Name]: text"). OCR loses that bracket once in a long while; far more often
    /// something is drawn over the tag (a menu of the game, whose label then reads as part of
    /// the channel's name), so the row is damaged until the tag is known from a sound row.
    var unclosedTag: Bool = false

    /// True for a header row that did not survive OCR in one piece (see `headerBroken`).
    public var isDamagedHeader: Bool { headerBroken }
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
        // "[1. 필터 설정습지] [Some Name]: text": a label of the game's chat menu where the name
        // of the channel is. The menu is open over the row, and what reads as its header is not.
        if result.hasPrefix, let label = result.channelLabel, ChatMenu.labelInside(label, locale: locale) != nil {
            result.headerBroken = true
        }
        if !result.hasPrefix, result.timestamp == nil {
            // "[Some Name]xxxx: text" in the colour of a player channel: a row that opens with
            // a bracketed word there is a header row or a wrapped link, never plain text.
            let byColour = color.flatMap(ChatColors.channel(for:))
            let chars = Array(text.drop(while: { $0 == " " }).prefix(2))
            let bracketedWord = chars.count == 2 && chars[0] == "[" && chars[1].isLetter
                && byColour != nil && byColour != .system && byColour != .emote
            if opensLikeHeader(text) || bracketedWord { result.headerBroken = true }
        }
        return result
    }

    /// "[1. ", "[Guild", "[길드": the line opens with a bracket and a numbered channel or a
    /// channel tag, whatever follows.
    public static func opensLikeHeader(_ text: String) -> Bool {
        let chars = Array(text.drop(while: { $0 == " " }))
        guard chars.count >= 6, let first = chars.first, Scanner.openers.contains(Scanner.normalize(first)) else { return false }
        if chars[1].isASCII, chars[1].isNumber {
            // "[1. General", "[12. world": never "[1/2]" or "[21:04]".
            var k = 2
            if chars[k].isASCII, chars[k].isNumber { k += 1 }
            return chars[k] == "." && k + 2 < chars.count && chars[k + 1] == " " && chars[k + 2].isLetter
        }
        let rest = String(chars[1...])
        return tags.contains { tag in
            guard rest.hasPrefix(tag.label) else { return false }
            let after = rest.dropFirst(tag.label.count).first
            return after == nil || after == "]" || after == " " || after == "["
        }
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

    /// "Thrall waves at you." → "Thrall";  "스랄님이 손을 흔듭니다." → "스랄";
    /// "First Last가 춤을 춥니다." → "First Last" (a name of several words is one name).
    private static func emoteSubject(_ body: String) -> String? {
        let words = body.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        var name = first
        for suffix in ["님이", "님은", "님의", "님을", "님께서"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name.removeLast(suffix.count)
            return name
        }
        // Capitalised Latin words up to the one a Korean particle is glued to ("Last가").
        func latinHead(_ word: String) -> (name: String, particle: Bool)? {
            let head = word.prefix { $0.isASCII && ($0.isLetter || $0 == "-" || $0 == "'") }
            guard head.count >= 2, head.first?.isUppercase == true else { return nil }
            let rest = word.dropFirst(head.count)
            if rest.isEmpty { return (String(head), false) }
            return rest.allSatisfy(Scanner.isHangul) ? (String(head), true) : nil
        }
        if words.count >= 2, let one = latinHead(words[0]), !one.particle {
            var parts = [one.name]
            for word in words.dropFirst().prefix(2) {
                guard let next = latinHead(word) else { break }
                parts.append(next.name)
                if next.particle { return parts.joined(separator: " ") }
            }
        }
        if let one = latinHead(first), one.particle { return stripRealm(one.name) }
        while let last = name.last, last.isPunctuation { name.removeLast() }
        guard let head = name.unicodeScalars.first, head.properties.isUppercase,
              name.count >= 2, name.count <= 24, name.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }) else { return nil }
        return stripRealm(name)
    }

    /// A player's name is a capital followed by small letters, word by word. OCR takes "l" and
    /// "I" (and the bar, the slash and the digit one) for each other: "TharI" and "Thar/" are
    /// "Tharl", "lronvale" is "Ironvale". The first letter of a name is a capital; of letters
    /// drawn alike small and large OCR tells the case by size alone and gets it wrong ("odo"
    /// for "Odo"). Names in other scripts and names with digits of their own are left alone.
    static func mendThinLetters(_ name: String) -> String {
        var out: [Character] = []
        var previous: Character?
        var atWordStart = true
        let chars = Array(name)
        for (n, c) in chars.enumerated() {
            var c = c
            let next = n + 1 < chars.count ? chars[n + 1] : nil
            if atWordStart {
                if c == "l" || c == "|" || c == "1", let next, next.isASCII, next.isLowercase { c = "I" }
                if n == 0, "cosuvwxz".contains(c), let next, next.isASCII, next.isLowercase { c = Character(c.uppercased()) }
            } else if let previous, previous.isASCII, previous.isLowercase, c == "I" || c == "|" || c == "1" || c == "/",
                      next == nil || next == " " || next?.isLowercase == true {
                c = "l"
            }
            out.append(c)
            atWordStart = c == " " || c == "-"
            previous = c
        }
        return String(out)
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
        Particle("의 귓속말", .whisperIn), Particle("님의 외침", .yell), Particle("의 외침", .yell),
        Particle("님에게", .whisperOut),
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
        /// See `ParsedChatLine.headerBroken`.
        var broken: Bool = false
        /// See `ParsedChatLine.unclosedName`.
        var unclosedName: Bool = false
        /// See `ParsedChatLine.oddName`.
        var oddName: Bool = false
        /// See `ParsedChatLine.unclosedTag`.
        var unclosedTag: Bool = false
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

        struct Name {
            var text: String; var leftEvidence: Int; var rightEvidence: Int
            /// A name of several words behind "[" that no bracket or bracket look-alike closes:
            /// where it ends is a guess.
            var unclosed = false
            /// Several words between two brackets that do not read like a name ("[A Wexlay
            /// thoruwcods]"): a name with something drawn over it.
            var odd = false
        }

        /// Reads `field` as a player name with possibly damaged brackets. Evidence: 2 = real bracket,
        /// 1 = a letter that brackets are commonly misread as, 0 = none.
        func cleanName(_ field: ArraySlice<Character>, allowSpaces: Bool = false, beforeColon: Bool = false) -> Name? {
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
            // "[Name Surnamel: text": with the header colon right behind it, a bracket read as a
            // thin letter is far more common than a bracket lost altogether.
            if right == 0, left == 2, beforeColon, chars.count >= 4, let l = chars.last, "lI1".contains(l),
               let before = chars.dropLast().last, before.isLowercase || Scanner.isHangul(before) {
                right = 1; chars.removeLast()
            }
            guard !chars.isEmpty, chars.count <= 40 else { return nil }
            var letters = 0, spaces = 0
            for (n, c) in chars.enumerated() {
                if c.isLetter { letters += 1 }
                else if c == " " { spaces += 1 }
                else if c.isNumber || c == "-" || c == "'" || c == "–" || c == "’" { continue }
                // "Some Nam/": the thin last letter of a name read as a stroke (mended in
                // `mendThinLetters`), between brackets.
                else if c == "/", n > 0, chars[n - 1].isASCII, chars[n - 1].isLowercase, n == chars.count - 1 || chars[n + 1] == " ",
                        left + right >= 2 { letters += 1 }
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

        /// "[Some Name other words" in front of a speech particle.
        static func isUnclosed(_ name: Name) -> Bool {
            name.leftEvidence == 2 && name.rightEvidence == 0 && name.text.contains(" ")
        }

        /// Several words where a name stands, one of them a single Latin letter ("A Wexlay
        /// thoruwcods"): no name has such a word, and OCR makes one of a name with another
        /// drawn over it. A lower-case first letter alone proves nothing: OCR takes "S", "W",
        /// "O" and their like for the small letter often enough.
        static func isOdd(_ name: Name) -> Bool {
            let words = name.text.split(separator: " ")
            return words.count > 1 && words.contains { $0.count == 1 && $0.first?.isASCII == true && $0.first?.isLetter == true }
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
            var opened = false
            if let f = chars.first, Scanner.openers.contains(f) || f == "|" { evidence += 2; realBrackets += 1; opened = true; chars.removeFirst() }
            if let l = chars.last, Scanner.closers.contains(l) || l == "|" { evidence += 2; realBrackets += 1; chars.removeLast() }
            guard !chars.isEmpty else { return nil }
            // "[1. General] [First": a bracket inside without its partner means the field spans
            // two groups. A balanced pair belongs to the label ("2. Trade (Services) - City").
            var depth = 0
            for c in chars {
                if Scanner.openers.contains(c) { depth += 1 }
                else if Scanner.closers.contains(c) {
                    depth -= 1
                    if depth < 0 { return nil }
                }
            }
            guard depth == 0 else { return nil }
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
                // (A tag whose opening bracket is gone may have lost it to the edge of the
                // captured region; one that opens and never closes has something over it.)
                return (Header(channel: .publicChannel, label: content, name: nil, tagForKey: content, tagKnown: true,
                               unclosedTag: opened), evidence)
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
                guard let name = cleanName(rest, beforeColon: true)
                        ?? bracketedSpacedName(rest, tagEvidence: tag.evidence, tagKnown: tag.header.tagKnown) else { continue }
                let total = tag.evidence + name.leftEvidence + name.rightEvidence
                let real = (tag.evidence >= 2 ? 1 : 0) + (name.leftEvidence == 2 ? 1 : 0) + (name.rightEvidence == 2 ? 1 : 0)
                let nameEvidence = name.leftEvidence + name.rightEvidence
                // An unreadable tag is believable only inside an otherwise convincing header.
                if !tag.header.tagKnown {
                    // "[First Last]" is one group, not a damaged tag plus a damaged name.
                    if let whole = scanGroup(lo), whole.end == hi { continue }
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
                h.broken = name.unclosed || name.odd || h.unclosedTag
                h.unclosedName = name.unclosed
                h.oddName = name.odd && !name.unclosed
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
            if let name = cleanName(head) ?? bracketedSpacedName(head, tagEvidence: 4), name.leftEvidence + name.rightEvidence >= 3,
               ChatLineParser.tagsBySkeleton[TextFold.skeleton(name.text)] == nil {
                return Header(channel: .say, label: nil, name: name.text, tagForKey: "", tagKnown: false, bareName: true,
                              broken: Scanner.isOdd(name), oddName: Scanner.isOdd(name))
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

        /// "[First Last]" after a tag: a name with spaces is only believable inside its own
        /// opening bracket, and with the closing one lost only when every word is capitalised.
        /// After a recognised tag that kept just one of its brackets, the name must show both of
        /// its own (the closing one possibly read as a thin letter). After a recognised tag in
        /// intact brackets, "First Lastj" with both name brackets gone is accepted too: nothing
        /// but the name stands between the tag and the header colon.
        func bracketedSpacedName(_ field: ArraySlice<Character>, tagEvidence: Int, tagKnown: Bool = false) -> Name? {
            guard tagEvidence == 4 || (tagKnown && tagEvidence >= 2),
                  var n = cleanName(field, allowSpaces: true, beforeColon: true),
                  n.text.contains(" "), n.text.split(separator: " ").count <= 3 else { return nil }
            if n.leftEvidence == 2 {
                if n.rightEvidence == 2 {
                    n.odd = Scanner.isOdd(n)
                    return n
                }
                if tagEvidence < 4 && n.rightEvidence == 0 { return nil }
                n.unclosed = n.rightEvidence == 0
                return Scanner.looksLikeName(n.text) ? n : nil
            }
            // Both brackets read as thin letters ("ISome NameI"), or both lost with the closing
            // one's look-alike still glued to the name ("Some Namej").
            guard tagKnown, tagEvidence == 4, n.leftEvidence == 0 || (n.leftEvidence == 1 && n.rightEvidence == 1) else { return nil }
            var chars = Array(n.text)
            if n.rightEvidence == 0 {
                guard chars.count >= 5, let l = chars.last, "jlI1J!".contains(l),
                      let before = chars.dropLast().last, before.isLowercase || Scanner.isHangul(before) else { return nil }
                chars.removeLast()
                n = Name(text: String(chars), leftEvidence: 0, rightEvidence: 1)
            }
            // Every word a capitalised name: "WTS Linen Cloth" has no lower-case tail to its first word.
            let words = n.text.split(separator: " ")
            guard words.count >= 2, words.allSatisfy({ w in
                guard let f = w.first, w.count >= 2 else { return false }
                if !f.isASCII { return w.allSatisfy { $0.isLetter } }
                return f.isUppercase && w.dropFirst().allSatisfy { $0.isLowercase || $0 == "'" || $0 == "-" }
            }) else { return nil }
            return n
        }

        /// "Some Name|H9|" in front of a speech particle: the closing bracket of the name (or
        /// the bar it was read as) with a few glyphs behind it that are no part of the row.
        /// OCR produces them at the seam between the Latin name and the Korean particle,
        /// also when the opening bracket lies outside the captured region.
        func nameBeforeCaughtGlyphs(_ field: ArraySlice<Character>) -> Name? {
            let from = field.startIndex + 2
            guard from < field.endIndex,
                  let close = field[from...].firstIndex(where: { Scanner.closers.contains($0) || $0 == "|" }) else { return nil }
            let caught = field[(close + 1)...]
            guard (1...4).contains(caught.count), caught.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "|" }),
                  let name = cleanName(field[...close], allowSpaces: true), name.rightEvidence == 2 else { return nil }
            return name
        }

        /// A creature's name with a quoted nickname in it (koKR: "별명" 이름 성, enUS: "Slim"
        /// Some Name), in front of a speech particle. The quotes are no part of a name as
        /// `cleanName` knows it; without them what is left must be one. OCR writes straight
        /// quotes and now and then a space inside them. An apostrophe inside a word ("O'Neil")
        /// is no quote.
        func quotedName(_ field: ArraySlice<Character>) -> Name? {
            let double: Set<Character> = ["\"", "“", "”", "„", "「", "」", "«", "»"]
            let single: Set<Character> = ["'", "‘", "’", "`"]
            let chars = Array(field)
            var plain: [Character] = []
            var marks: [Int] = []          // offsets into `plain` where a quote stood
            for (n, c) in chars.enumerated() {
                let atEdge = n == 0 || n == chars.count - 1 || chars[n - 1] == " " || chars[n + 1] == " "
                if double.contains(c) || (single.contains(c) && atEdge) {
                    marks.append(plain.count)
                } else {
                    plain.append(c)
                }
            }
            guard marks.count == 2, marks[0] < marks[1], let bare = cleanName(plain[...], allowSpaces: true),
                  bare.leftEvidence == 0, bare.rightEvidence == 0 else { return nil }
            func words(_ part: ArraySlice<Character>) -> String {
                String(part).split(separator: " ").joined(separator: " ")
            }
            let before = words(plain[..<marks[0]]), nick = words(plain[marks[0]..<marks[1]]), after = words(plain[marks[1]...])
            guard !nick.isEmpty else { return nil }
            let text = [before, "\"" + nick + "\"", after].filter { !$0.isEmpty }.joined(separator: " ")
            return Name(text: text, leftEvidence: 0, rightEvidence: 0)
        }

        func parseSpeech(_ head: ArraySlice<Character>) -> Header? {
            let lo = head.startIndex, hi = head.endIndex
            // English: last word is the verb.
            if let space = head.lastIndex(of: " "), space > lo {
                let verb = TextFold.skeleton(String(head[(space + 1)..<hi]))
                for v in ChatLineParser.englishVerbs where v.skeleton == verb {
                    if let name = cleanName(head[lo..<space], allowSpaces: true) ?? quotedName(head[lo..<space]) {
                        let evidence = name.leftEvidence + name.rightEvidence
                        if evidence == 0 && !Scanner.looksLikeName(name.text.filter { $0 != "\"" }) { continue }
                        return Header(channel: speech(v.kind), label: nil, name: name.text, tagForKey: v.text,
                                      tagKnown: true, weak: evidence == 0,
                                      broken: Scanner.isUnclosed(name) || (evidence > 0 && Scanner.isOdd(name)),
                                      unclosedName: Scanner.isUnclosed(name),
                                      oddName: !Scanner.isUnclosed(name) && evidence > 0 && Scanner.isOdd(name))
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
                guard var name = cleanName(head[lo..<k], allowSpaces: true) ?? nameBeforeCaughtGlyphs(head[lo..<k])
                        ?? quotedName(head[lo..<k]) else { continue }
                // A misread particle is only believable right after a bracketed name.
                if fuzzy && name.rightEvidence < 2 { continue }
                // "ISome NameIHg의 외침": both brackets read as letters, and a glyph or two of
                // something else caught between the closing one and the particle.
                if name.leftEvidence == 1, name.rightEvidence == 0 {
                    let chars = Array(name.text)
                    if let cut = chars.indices.last(where: { "Il1|!".contains(chars[$0]) }), cut >= 3,
                       (1...3).contains(chars.count - cut - 1), chars[cut - 1].isLowercase || Scanner.isHangul(chars[cut - 1]) {
                        name = Name(text: String(chars[..<cut]), leftEvidence: 1, rightEvidence: 1)
                    }
                }
                let label: String? = p.kind == .whisperOut ? outgoingLabel : nil
                return Header(channel: speech(p.kind), label: label, name: name.text, tagForKey: p.text,
                              tagKnown: true, weak: name.leftEvidence + name.rightEvidence == 0,
                              broken: Scanner.isUnclosed(name) || (name.leftEvidence + name.rightEvidence > 0 && Scanner.isOdd(name)),
                              unclosedName: Scanner.isUnclosed(name),
                              oddName: !Scanner.isUnclosed(name) && name.leftEvidence + name.rightEvidence > 0 && Scanner.isOdd(name))
            }
            return nil
        }

        // MARK: run

        mutating func run() -> ParsedChatLine {
            var start = skipSpaces(0)
            // A stray mark in front of the first bracket is OCR picking up the window edge.
            // (A mark with nothing but blanks behind it has no bracket to stand in front of.)
            if start + 2 < count, !norm[start].isLetter, !norm[start].isNumber,
               !Scanner.openers.contains(norm[start]), !Scanner.closers.contains(norm[start]) {
                let next = skipSpaces(start + 1)
                if next < count, Scanner.openers.contains(norm[next]) { start = next }
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
            } else if Scanner.openers.contains(norm[i]), i + 2 < count,
                      // (A row that is nothing but an opening bracket has no place for a second one.)
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
                if let g2 = scanGroup(j), let name = cleanName(norm[j..<g2.end], allowSpaces: true) {
                    h.name = name.text
                    h.oddName = Scanner.isOdd(name)
                    h.broken = h.oddName || h.unclosedTag
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
                    // "[Name some words": the name group never closes, so where the name ends
                    // and what follows it is a guess.
                    h.broken = name.rightEvidence == 0 || h.unclosedTag
                    return finish(h, timestamp: timestamp, bodyStart: k)
                }
                // Short addon tags are too ambiguous without a name ("[R] anyone?").
                if h.short { return nil }
                h.broken = true
                return finish(h, timestamp: timestamp, bodyStart: j)
            }
            return nil
        }

        mutating func finish(_ h: Header, timestamp: String?, bodyStart: Int) -> ParsedChatLine {
            tagKnown = h.tagKnown
            bareName = h.bareName
            weak = h.weak
            var p = ParsedChatLine(timestamp: timestamp, channel: h.channel, channelLabel: h.label,
                                   sender: h.name.map(ChatLineParser.stripRealm).map(ChatLineParser.mendThinLetters),
                                   body: body(from: bodyStart),
                                   hasPrefix: true)
            p.headerTag = h.tagForKey
            p.headerName = h.name ?? ""
            p.headerBroken = h.broken
            p.unclosedName = h.broken && h.unclosedName
            p.oddName = h.broken && h.oddName
            p.unclosedTag = h.broken && h.unclosedTag && !h.unclosedName && !h.oddName
            return p
        }
    }
}
