import Foundation

/// The places of every zone (zone_places.<flavor>.tsv) and the two things asked of them: which
/// zone a channel label names, and which places of that zone a chat line may be speaking of.
/// Built once per load; immutable and safe to use from any thread.
///
/// A place is only ever offered for a line said in its zone's own channel, and only as weak
/// evidence: its name shares a word with the line ("IB site" and Ironbeak Excavation Site),
/// which is how players shorten a place nobody outside the zone would recognise. It comes
/// with the words it was found by, so that whoever reads the hint knows what in the line
/// the place would stand for.
final class GlossaryPlaceIndex: Sendable {

    /// Places offered for one line. Also how many places of a zone may share a word before the
    /// word stops saying which of them is meant ("camp" in a zone with five camps).
    static let placesPerLine = 3
    /// Shortest word, of a name and of a line, that is looked at ("Dun", "Bay", "Inn" are not).
    static let minimumWordLength = 4
    /// Shortest piece taken for a longer word cut short ("excav" for Excavation). On real chat
    /// a piece of four letters found nothing that one of five did not, and of the English
    /// words that begin a word of some place more than twice as many have four letters as have
    /// five (salt, silk, bomb, lame against plate, split), so the bar is five.
    static let minimumPrefixLength = 5
    /// Shortest zone name, in compared units, in which one misread unit is forgiven.
    static let minimumForgivingLength = 6
    /// A word that ends the names of places in this many zones is a word for a kind of place
    /// ("site", "harbor", "tavern", "lodge"), not a name: chat says it all day about anything
    /// ("which site has the guide", "dont harbor a grudge"), so by itself it finds no place.
    static let kindZoneCount = 4
    /// Letters of a code written in front of a word of a name to shorten the rest ("IB site").
    static let codeLength = 2...4
    /// Points of the compass, which chat writes in capitals in front of a kind of place just
    /// like a code ("horde at the SE tower"): never a code.
    private static let compass: Set<String> = ["ne", "nw", "se", "sw", "nne", "ene", "ese", "sse", "ssw", "wsw", "wnw", "nnw"]

    /// A place found for a line, and the words of the line it was found by.
    struct Found: Sendable, Hashable {
        var pair: GlossaryPair
        /// As the line wrote them: "lost rigger", "thand span", "IB site".
        var written: String
    }

    private struct Place: Sendable {
        var pair: GlossaryPair
        /// How many words of the name can stand for the place.
        var wordCount: Int
        /// Those words are the whole name but for "the" and "of": a line that has them all
        /// names the place outright ("northshire"), however many other places share the word.
        var nameable: Bool
        /// Every word of the name in every spelling: a word of the line next to a found one
        /// that is among these belongs to the name too ("lost" in front of "rigger").
        var spellings: Set<String>
        /// The words of the name in order, without the little ones: what a code can shorten.
        var sequence: [[Unicode.Scalar]]
    }

    /// Word number `word` of place `place` (of one zone).
    private struct WordRef: Sendable, Hashable {
        var place: Int32
        var word: UInt8
    }

    private struct Zone: Sendable {
        var pair: GlossaryPair
        var places: [Place] = []
        /// Spelling of a word → the places of the zone whose name has it.
        var byWord: [String: [WordRef]] = [:]
        /// The spellings in order, for finding those that begin with a piece.
        var spellings: [String] = []
        /// A word for a kind of place → the places of the zone whose name ends in it, also
        /// where the word is too ordinary to be in `byWord` ("mine", "keep", "tower").
        var byKind: [String: [Int32]] = [:]
    }

    private struct Name: Sendable {
        var units: [Unicode.Scalar]
        /// Index into `zones`; -1 for a name that gives no zone.
        var zone: Int32
    }

    private let zones: [Zone]
    /// Folded zone name, either language → zone. -1: the name of a zone without known places,
    /// or of two zones at once.
    private let zoneByName: [String: Int32]
    /// The same names by length, for telling a misread name from another zone's name.
    private let namesByLength: [Int: [Name]]
    /// Every word of every place and zone name: a piece of a line that is one of these is a
    /// word of its own, not another word cut short.
    private let vocabulary: Set<String>
    /// The words for a kind of place (see `kindZoneCount`).
    private let kindWords: Set<String>

    var zoneCount: Int { zones.count }
    var placeCount: Int { zones.reduce(0) { $0 + $1.places.count } }

    // MARK: Building

    /// `otherZoneNames`: names of zones that may have no row here (the official zone and
    /// instance names). A label that reads as one of them names that zone, not a zone of this
    /// table that is spelled almost the same.
    init(rows: [GlossaryZonePlace], otherZoneNames: [String] = []) {
        var zones: [Zone] = []
        var zoneIndex: [String: Int] = [:]
        var named: [String: Int32] = [:]
        var vocabulary = Set<String>()
        var zoneWords: [Set<String>] = []
        // (place, word) → its spellings, per zone, in file order.
        var seenPlaces: [Set<String>] = []
        // Last word of a name → the zones that have such a place, and the places themselves.
        var endsIn: [String: Set<Int>] = [:]
        var byLastWord: [[String: [Int32]]] = []

        func register(_ name: String, zone: Int32) {
            let key = Self.key(Self.fold(name))
            guard !key.isEmpty else { return }
            if let known = named[key], known != zone { named[key] = -1 } else { named[key] = zone }
        }

        for row in rows {
            let id = row.zone.english.lowercased()
            let z: Int
            if let known = zoneIndex[id] {
                z = known
            } else {
                z = zones.count
                zoneIndex[id] = z
                zones.append(Zone(pair: row.zone))
                seenPlaces.append([])
                byLastWord.append([:])
                var own = Set<String>()
                for word in Self.words(of: row.zone.english) { own.formUnion(word) }
                zoneWords.append(own)
                vocabulary.formUnion(own)
                register(row.zone.english, zone: Int32(z))
            }
            register(row.zone.korean, zone: Int32(z))
            guard let place = row.place else { continue }
            // Rows that only give another Korean name of the zone come first in the file: the
            // name on the rows with places is the one to show.
            if zones[z].places.isEmpty { zones[z].pair = row.zone }
            guard seenPlaces[z].insert(place.english.lowercased()).inserted else { continue }

            var count = 0
            var nameable = true
            let number = Int32(zones[z].places.count)
            let words = Self.words(of: place.english)
            var every = Set<String>()
            var sequence: [[Unicode.Scalar]] = []
            for spellings in words {
                vocabulary.formUnion(spellings)
                every.formUnion(spellings)
                // The spelling without a possessive "s" is the one a code is read off.
                if !Self.littleWords.contains(spellings[0]) { sequence.append(Array(spellings[spellings.count - 1].unicodeScalars)) }
                let usable = spellings.filter {
                    $0.unicodeScalars.count >= Self.minimumWordLength && !GlossaryStopwords.isOrdinaryPlaceWord($0)
                        && !zoneWords[z].contains($0)
                }
                // A name of more words than this has no use for the rest.
                guard !usable.isEmpty, count < 64 else {
                    if !Self.littleWords.contains(spellings[0]) { nameable = false }
                    continue
                }
                let ref = WordRef(place: number, word: UInt8(count))
                for spelling in usable where !(zones[z].byWord[spelling]?.contains(ref) ?? false) {
                    zones[z].byWord[spelling, default: []].append(ref)
                }
                count += 1
            }
            // What kind of place it is: the last word ("Gullwing Wharf"), or the one in
            // front of "of" ("Ruins of Korvendal").
            var last = words.count - 1
            if let of = words.firstIndex(where: { $0[0] == "of" }), of > 0 { last = of - 1 }
            if last >= 0 {
                for spelling in words[last] where spelling.unicodeScalars.count >= Self.minimumWordLength {
                    endsIn[spelling, default: []].insert(z)
                    byLastWord[z][spelling, default: []].append(number)
                }
            }
            zones[z].places.append(Place(pair: place, wordCount: count, nameable: nameable, spellings: every, sequence: sequence))
        }
        var kindWords = Set<String>()
        for (word, where_) in endsIn where where_.count >= Self.kindZoneCount { kindWords.insert(word) }
        for z in zones.indices {
            zones[z].spellings = zones[z].byWord.keys.sorted()
            zones[z].byKind = byLastWord[z].filter { kindWords.contains($0.key) }
        }

        // A zone no place is known in gives nothing to offer.
        for (z, zone) in zones.enumerated() where zone.places.isEmpty {
            for (key, value) in named where value == Int32(z) { named[key] = -1 }
        }
        for name in otherZoneNames {
            let key = Self.key(Self.fold(name))
            if !key.isEmpty, named[key] == nil { named[key] = -1 }
        }
        var byLength: [Int: [Name]] = [:]
        for (key, zone) in named {
            let units = Array(key.unicodeScalars)
            byLength[units.count, default: []].append(Name(units: units, zone: zone))
        }

        self.zones = zones
        self.zoneByName = named
        self.namesByLength = byLength
        self.vocabulary = vocabulary
        self.kindWords = kindWords
    }

    private static let littleWords: Set<String> = ["the", "of", "and", "at", "in", "on", "to", "a"]

    /// The words of an English name, each with the spellings a line may use for it: the word
    /// itself and, for a possessive ("Ironbeak's"), the name without its "s".
    private static func words(of name: String) -> [[String]] {
        let units = GlossaryUnits(name)
        let n = units.count
        guard n > 0 else { return [] }
        var out: [[String]] = []
        var start = 0
        for end in 1...n where units.isBoundary(end) {
            defer { start = end }
            guard units.scripts[start] == .word else { continue }
            var spellings = [units.key(start..<end)]
            if end - start >= 2, units.scalars[end - 1] == "s" {
                let before = Int(units.rawIndex[end - 1]) - 1
                if before >= 0, before < units.raw.count, units.raw[before] == "'" || units.raw[before] == "\u{2019}" {
                    spellings.append(units.key(start..<(end - 1)))
                }
            }
            out.append(spellings)
        }
        return out
    }

    /// Whether the word names a kind of place rather than a place (see `kindZoneCount`).
    func isKindWord(_ word: String) -> Bool { kindWords.contains(word) }

    // MARK: Zone of a channel label

    /// The channels the game opens per zone, as the Korean and the English client name them:
    /// General and LocalDefense. Trade ("거래 - 도시") and the others name no zone.
    private static let zoneChannels: [[Unicode.Scalar]] = ["공개", "수비", "General", "LocalDefense"].map(fold)

    private static let dashes: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}", "\u{FF0D}"]

    /// The zone (an index for `zone(_:)` and `places(inZone:...)`) that a channel label names:
    /// "1. 공개 - 타나리스", "3. LocalDefense - Tanaris", "공개 - 타나리스". nil for a channel that
    /// is not a zone's own, for a zone without known places, and whenever the name is not read
    /// clearly enough to be sure: one misread letter is forgiven only where exactly one known
    /// zone is that close ("스톰원드" for 스톰윈드).
    func zone(forChannelLabel label: String) -> Int? {
        guard !zones.isEmpty, let dash = label.firstIndex(where: { Self.dashes.contains($0) }) else { return nil }
        var channel = label[..<dash]
        // "1. 공개": the number, however it was read, ends at the dot.
        if let dot = channel.lastIndex(of: ".") { channel = channel[channel.index(after: dot)...] }
        var word = Self.fold(String(channel))
        while let first = word.first, first.properties.numericType != nil { word.removeFirst() }
        guard Self.zoneChannels.contains(where: { $0 == word || Self.oneEditApart($0, word) }) else { return nil }

        let name = Self.fold(String(label[label.index(after: dash)...]))
        if let exact = zoneByName[Self.key(name)] { return exact >= 0 ? Int(exact) : nil }
        guard name.count >= Self.minimumForgivingLength else { return nil }
        var found: Int32?
        for length in (name.count - 1)...(name.count + 1) {
            for candidate in namesByLength[length] ?? [] where Self.oneEditApart(candidate.units, name) {
                // As close to a zone that gives nothing, or to a second zone: not sure enough.
                if candidate.zone < 0 { return nil }
                if let found, found != candidate.zone { return nil }
                found = candidate.zone
            }
        }
        return found.map { Int($0) }
    }

    func zone(_ index: Int) -> GlossaryPair { zones[index].pair }

    /// A name reduced to what is compared: letters lower-cased, Hangul syllables taken apart
    /// into their jamo (a misread syllable differs in one of them: 윈 / 원), digits. Spacing
    /// and punctuation are dropped.
    static func fold(_ name: String) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        for scalar in name.precomposedStringWithCanonicalMapping.unicodeScalars {
            let v = scalar.value
            if v >= 0xAC00 && v <= 0xD7A3 {
                let s = v - 0xAC00
                out.append(Unicode.Scalar(0x1100 + s / 588)!)
                out.append(Unicode.Scalar(0x1161 + (s % 588) / 28)!)
                if s % 28 != 0 { out.append(Unicode.Scalar(0x11A7 + s % 28)!) }
            } else if v < 0x80 {
                if (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) {
                    out.append(scalar)
                } else if v >= 0x41 && v <= 0x5A {
                    out.append(Unicode.Scalar(UInt8(v | 0x20)))
                }
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                out.append(contentsOf: String(scalar).lowercased().unicodeScalars)
            }
        }
        return out
    }

    private static func key(_ units: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: units)
        return String(view)
    }

    /// True when one unit changed, missing or added turns `a` into `b` (never for equal names).
    static func oneEditApart(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard long.count - short.count <= 1 else { return false }
        var i = 0
        while i < short.count, short[i] == long[i] { i += 1 }
        if i == long.count { return false }
        if short.count == long.count {
            return short[(i + 1)...].elementsEqual(long[(i + 1)...])
        }
        return short[i...].elementsEqual(long[(i + 1)...])
    }

    // MARK: Places a line may be speaking of

    /// The places of zone `index` that the text may be speaking of, best first, at most
    /// `limit`, each with the words it was found by.
    ///
    /// A word of the text finds a place when it is a word of the name, or a piece of at least
    /// five letters that begins one and is no word itself ("excav"); never when it is an
    /// ordinary word, when it stands inside a [link], or when a name or an abbreviation of
    /// the dictionary already explains it (`explained`, per unit, from `GlossaryIndex.match`):
    /// "cath" behind "SM" is the Scarlet Monastery wing, whatever square the city has.
    ///
    /// A word that more than `placesPerLine` places of the zone share points at none of them,
    /// so such a place is offered only when the text has every word of its name. A word for a
    /// kind of place ("site") needs company: a word of the name that is the place's own
    /// ("excav site"), or a code in front of it that the rest of the name can be read from
    /// ("IB site" for Ironbeak Excavation Site). With such a code even a kind word too
    /// ordinary to be looked at alone will do ("CV mine"). Such a code is written in capitals
    /// in a line that is not all capitals, and is no point of the compass: any short word
    /// can be read off some name ("one sec keep going", "meh mine is better", "SE tower").
    /// In small letters only the first four letters of a word of the name are one ("iron site").
    ///
    /// Places found by a word no other place of the zone has come before those found by a
    /// word several share, so that the bound keeps the ones the line names.
    func places(inZone index: Int, units: GlossaryUnits, explained: [Bool] = [], limit: Int = placesPerLine) -> [Found] {
        let zone = zones[index]
        let n = units.count
        guard n > 0, limit > 0, !zone.places.isEmpty else { return [] }
        let linked = Self.linkedUnits(units)

        // The words of the text, in order.
        var tokens: [Range<Int>] = []
        var start = 0
        for end in 1...n where units.isBoundary(end) {
            defer { start = end }
            if units.scripts[start] == .word { tokens.append(start..<end) }
        }
        func taken(_ token: Range<Int>) -> Bool {
            (!linked.isEmpty && linked[token.lowerBound]) || (!explained.isEmpty && explained[token].contains(true))
        }

        struct Hit {
            var words: UInt64 = 0
            var telling = false
            /// The first word found that is in the name of no other place of the zone.
            var alone: Int?
            var exact = false
            /// The first word found that is a name's own, not a word for a kind of place.
            var named: Int?
            /// Numbers of the tokens found, in order.
            var tokens: [Int] = []
            /// Where the place is spoken of: at the word that is its alone if one was found
            /// ("bluegill", not the "marsh" three places share), else at its own word.
            var first: Int { alone ?? named ?? tokens.first ?? Int.max }
        }
        var hits: [Int32: Hit] = [:]
        for (number, token) in tokens.enumerated() {
            guard token.count >= Self.minimumWordLength, !taken(token) else { continue }
            let key = units.key(token)
            for place in zone.byKind[key] ?? [] {
                hits[place, default: Hit()].tokens.append(number)
            }
            if GlossaryStopwords.isOrdinaryPlaceWord(key) { continue }

            var exact = true
            var refs: [(ref: WordRef, kind: Bool)] = (zone.byWord[key] ?? []).map { ($0, kindWords.contains(key)) }
            if refs.isEmpty, token.count >= Self.minimumPrefixLength, !vocabulary.contains(key), !GlossaryStopwords.isOrdinaryPiece(key) {
                exact = false
                refs = begunBy(key, in: zone)
            }
            if refs.isEmpty { continue }
            var reached = Set<Int32>()
            for found in refs { reached.insert(found.ref.place) }
            let telling = reached.count <= Self.placesPerLine
            for found in refs {
                var hit = hits[found.ref.place] ?? Hit()
                hit.words |= 1 << UInt64(found.ref.word)
                if telling { hit.telling = true }
                if reached.count == 1, hit.alone == nil { hit.alone = number }
                if exact { hit.exact = true }
                if !found.kind, hit.named == nil { hit.named = number }
                if hit.tokens.last != number { hit.tokens.append(number) }
                hits[found.ref.place] = hit
            }
        }
        if hits.isEmpty { return [] }

        /// Two words of the text with nothing but spacing between them.
        func adjacent(_ a: Int, _ b: Int) -> Bool {
            guard a >= 0, b < tokens.count, tokens[a].upperBound == tokens[b].lowerBound else { return false }
            let from = Int(units.rawIndex[tokens[a].upperBound - 1]) + 1, to = Int(units.rawIndex[tokens[b].lowerBound])
            guard from <= to, to <= units.raw.count else { return false }
            return !units.raw[from..<to].contains { !$0.properties.isWhitespace }
        }

        // A code is told from a short word by its capitals, which say nothing in a line
        // that is all capitals.
        let mixedCase = units.hasLowercase(0..<n)

        var ranked: [(place: Int32, coded: Bool, whole: Bool, count: Int, hit: Hit, written: String)] = []
        for (number, hit) in hits {
            let place = zone.places[Int(number)]
            let count = hit.words.nonzeroBitCount
            let whole = count > 0 && place.nameable && count >= place.wordCount

            /// The stretch of the text that stands for the place around word `anchor`: the
            /// found word and what stands right next to it of the same name ("lost" in front
            /// of "rigger"), and whether a code stands in front of it.
            func stretch(at anchor: Int) -> (low: Int, high: Int, coded: Bool) {
                var low = anchor, high = anchor
                func belongs(_ token: Int) -> Bool {
                    hit.tokens.contains(token) || (place.spellings.contains(units.key(tokens[token])) && !taken(tokens[token]))
                }
                while low > 0, adjacent(low - 1, low), belongs(low - 1) { low -= 1 }
                while high + 1 < tokens.count, adjacent(high, high + 1), belongs(high + 1) { high += 1 }
                while low < high, !hit.tokens.contains(low), Self.littleWords.contains(units.key(tokens[low])) { low += 1 }
                while high > low, !hit.tokens.contains(high), Self.littleWords.contains(units.key(tokens[high])) { high -= 1 }

                // A code in front of it that the rest of the name can be read from.
                guard low > 0, adjacent(low - 1, low), Self.codeLength.contains(tokens[low - 1].count),
                      !taken(tokens[low - 1]) else { return (low, high, false) }
                let code = units.key(tokens[low - 1])
                guard !GlossaryStopwords.contains(code), !vocabulary.contains(code), !Self.compass.contains(code) else { return (low, high, false) }
                var said = Set<String>()
                for token in low...high { said.insert(units.key(tokens[token])) }
                let rest = place.sequence.filter { word in
                    let name = Self.key(word)
                    return !said.contains { name.hasPrefix($0) || $0.hasPrefix(name) }
                }
                // Written in capitals where capitals mean something, any letters of the rest
                // in their order will do ("IB"); in small letters only the beginning of one
                // of its words, four letters of it ("iron site").
                let letters = Array(code.unicodeScalars)
                let capitals = mixedCase && !units.hasLowercase(tokens[low - 1])
                let coded = capitals ? Self.shortens(letters, rest)
                    : letters.count >= Self.minimumWordLength && rest.contains { $0.count > letters.count && $0.starts(with: letters) }
                return (low, high, coded)
            }
            // A place known only by its kind word may be spoken of at any of the places
            // the word stands ("which site? the IB site"): the one with a code in front.
            var found = stretch(at: hit.first)
            if !found.coded, hit.named == nil {
                for anchor in hit.tokens.dropFirst() {
                    let other = stretch(at: anchor)
                    if other.coded { found = other; break }
                }
            }
            let (low, high, coded) = found
            guard coded || ((hit.telling || whole) && hit.named != nil) else { continue }
            let from = coded ? tokens[low - 1].lowerBound : tokens[low].lowerBound
            ranked.append((number, coded, whole, count, hit, Self.written(units, from..<tokens[high].upperBound)))
        }
        ranked.sort { a, b in
            if a.coded != b.coded { return a.coded }
            if a.whole != b.whole { return a.whole }
            if a.count != b.count { return a.count > b.count }
            if (a.hit.alone != nil) != (b.hit.alone != nil) { return a.hit.alone != nil }
            if a.hit.exact != b.hit.exact { return a.hit.exact }
            if a.hit.first != b.hit.first { return a.hit.first < b.hit.first }
            return a.place < b.place
        }
        return ranked.prefix(limit).map { Found(pair: zone.places[Int($0.place)].pair, written: $0.written) }
    }

    /// English endings. A word of the line that lacks only one of these is the stem of the
    /// name's word ("craft" and Crafter's, "twist" and Twisting): a word of its own, not a
    /// name cut short.
    private static let endings: Set<String> = [
        "ed", "ded", "er", "ers", "rs", "or", "ors", "ing", "ings", "ling", "ion", "ions", "ment", "ance", "ness",
        "ery", "ory", "ant", "ous", "ess", "ite",
    ]

    /// The words of the zone's places that `piece` is the beginning of, where what the piece
    /// leaves off is at least two letters, no word either ("crush" is not Crushridge cut
    /// short, it stops where the name's second word begins) and no mere ending.
    private func begunBy(_ piece: String, in zone: Zone) -> [(ref: WordRef, kind: Bool)] {
        let spellings = zone.spellings
        var low = 0, high = spellings.count
        while low < high {
            let mid = (low + high) / 2
            if spellings[mid] < piece { low = mid + 1 } else { high = mid }
        }
        var refs: [(ref: WordRef, kind: Bool)] = []
        let pieceLength = piece.unicodeScalars.count
        while low < spellings.count, spellings[low].hasPrefix(piece) {
            let spelling = spellings[low]
            low += 1
            guard spelling.unicodeScalars.count >= pieceLength + 2 else { continue }
            var rest = String.UnicodeScalarView()
            rest.append(contentsOf: spelling.unicodeScalars.dropFirst(pieceLength))
            let left = String(rest)
            if vocabulary.contains(left) || GlossaryStopwords.isOrdinaryPlaceWord(left) || Self.endings.contains(left) { continue }
            let kind = kindWords.contains(spelling)
            for ref in zone.byWord[spelling] ?? [] where !refs.contains(where: { $0.ref == ref }) { refs.append((ref, kind)) }
        }
        return refs
    }

    /// True when `code` can be read off `words` from left to right: its first letter begins
    /// one of them, and each letter after it stands later in the same word or begins a later
    /// one ("ib" off ironbeak excavation, "ev" off excavation).
    static func shortens(_ code: [Unicode.Scalar], _ words: [[Unicode.Scalar]]) -> Bool {
        func read(_ letter: Int, _ word: Int, _ from: Int) -> Bool {
            if letter == code.count { return true }
            if word >= 0 {
                var at = from
                while at < words[word].count {
                    if words[word][at] == code[letter], read(letter + 1, word, at + 1) { return true }
                    at += 1
                }
            }
            var next = word + 1
            while next < words.count {
                if words[next].first == code[letter], read(letter + 1, next, 1) { return true }
                next += 1
            }
            return false
        }
        return code.count >= 2 && read(0, -1, 0)
    }

    /// The text of the units as it was written, capitals included (`raw` keeps them lowered).
    private static func written(_ units: GlossaryUnits, _ range: Range<Int>) -> String {
        guard !range.isEmpty else { return "" }
        let first = Int(units.rawIndex[range.lowerBound]), last = Int(units.rawIndex[range.upperBound - 1])
        guard first <= last, last < units.raw.count else { return units.key(range) }
        var view = String.UnicodeScalarView()
        var unit = range.lowerBound
        for index in first...last {
            var scalar = units.raw[index]
            while unit < range.upperBound, Int(units.rawIndex[unit]) < index { unit += 1 }
            if unit < range.upperBound, Int(units.rawIndex[unit]) == index, units.caseFlag[unit] == 1,
               scalar.value >= 0x61, scalar.value <= 0x7A {
                scalar = Unicode.Scalar(UInt8(scalar.value - 0x20))
            }
            view.append(scalar)
        }
        return String(view)
    }

    /// Per unit: it stands inside square brackets (an item or quest link, which is copied, not
    /// translated). A bracket that is never closed runs to the end of the text: a link cut off
    /// by the edge of the chat window. Empty when the text has no bracket.
    private static func linkedUnits(_ units: GlossaryUnits) -> [Bool] {
        guard units.raw.contains("[") else { return [] }
        var inside = [Bool](repeating: false, count: units.raw.count)
        var depth = 0
        for (i, scalar) in units.raw.enumerated() {
            if scalar == "[" { depth += 1 } else if scalar == "]" { depth = max(0, depth - 1) }
            inside[i] = depth > 0
        }
        return units.rawIndex.map { Int($0) < inside.count && inside[Int($0)] }
    }
}
