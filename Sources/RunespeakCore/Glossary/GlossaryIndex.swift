import Foundation

/// Where a name line came from; lower wins when the same name is in several files.
enum GlossarySource: UInt8, Sendable {
    case mine = 0       // my_terms.tsv
    case nickname = 1   // nicknames.tsv
    case official = 2   // official_names.<flavor>.tsv
}

struct GlossaryNameEntry: Sendable {
    var line: GlossaryNameLine
    var source: GlossarySource
    /// A one-word English name of a minor kind (item, mount, currency, subzone: "Honey", "Tiger",
    /// "Tower") is found only where the chat writes it as a name: capitalised or as a [link].
    var properOnly = false
    /// Official names only: rank of the kind (0 = zone, instance, class ...). Where several
    /// official names share a spelling, only those of the best kind present are kept.
    var priority: UInt8 = 0
    /// Official names only: a Korean name written as one word is offered as a loose name
    /// (context decides) when it has at least this many syllables, and not at all below that.
    /// 0 = it is a binding name like any other (places, bosses, classes).
    var looseKoreanFrom: UInt8 = 0
}

/// Immutable lookup structure over every dictionary file. Built once per load; `match` is
/// lock-free and safe to call from any thread.
final class GlossaryIndex: Sendable {

    // What a key points at.
    private struct Ref: Sendable {
        enum Kind: UInt8, Sendable { case name, abbreviation, skill, looseName }
        var kind: Kind
        var rank: UInt8 = 0          // names: GlossarySource in the high four bits, kind priority below
        var side: UInt8 = 0          // 0 = Korean side matched, 1 = English side
        var alias: Int16 = 0
        var entry: Int32
        var flags: UInt16 = 0
        var literal: Int32 = -1      // index into `literals`
        var signature: UInt64 = 0    // which key units were written upper-case

        static let capsOnly: UInt16 = 1      // matches only an upper-case occurrence
        static let variant: UInt16 = 2       // other spelling from the "also" column
        static let standalone: UInt16 = 4    // one-letter abbreviation: exact case, spaces around
        static let shortTextOnly: UInt16 = 8 // "1": only when it is (nearly) the whole message
        static let linkOnly: UInt16 = 16     // "[Explorer]": only when the chat shows it as a [link]
        static let properOnly: UInt16 = 32   // "Honey": only capitalised or as a [link]
        static let mixedCase: UInt16 = 64    // abbreviation written like "BrM", "HoT"
        static let needsCapital: UInt16 = 128 // "HoT": the lower-case word is everyday English
        static let oneWord: UInt16 = 256      // the dictionary writes it as a single Latin word
        static let apostrophe: UInt16 = 512   // the dictionary spelling itself has an apostrophe
    }

    private let map: [String: [Ref]]
    /// First two scalars of a key → bit set of key lengths (bit L-2; bit 63 = 65 or longer).
    private let prefixes: [UInt64: UInt64]
    private let singles: Set<UInt32>
    private let maxKeyLength: Int
    private let literals: [[Unicode.Scalar]]

    let names: [GlossaryNameEntry]
    let abbreviations: [GlossaryAbbreviationLine]
    let skills: [GlossaryNameLine]
    /// Name pairs for the status line: official names (skills included) and the user's own
    /// lines. Nickname rows only add spellings to names that are already counted.
    let nameCount: Int

    struct Limits: Sendable {
        var names = 12
        var abbreviations = 10
        var skills = 6
    }

    struct Result: Sendable {
        var names: [GlossaryPair] = []
        var abbreviations: [GlossaryAbbreviation] = []
        var skills: [GlossaryPair] = []
        /// Per unit of the text (`GlossaryUnits`): a name or an abbreviation found here takes
        /// this unit as part of it. A loose name does not count: "ruins" read as several of the
        /// spell Ruin says nothing about what the word is. Empty when nothing was found.
        var explained: [Bool] = []
    }

    // MARK: Building

    init(names: [GlossaryNameEntry], abbreviations: [GlossaryAbbreviationLine], skills: [GlossaryNameLine]) {
        var builder = Builder()
        for line in abbreviations {
            let units = GlossaryUnits(line.abbreviation, keepRaw: false)
            if units.count > 0, !units.hasUppercase(0..<units.count) { builder.lowerCaseAbbreviations.insert(units.fullKey) }
        }
        builder.map.reserveCapacity(names.count * 2 + abbreviations.count * 2 + skills.count * 2)

        for (i, entry) in names.enumerated() {
            for (side, aliases) in [entry.line.korean, entry.line.english].enumerated() {
                for (a, alias) in aliases.enumerated() where a <= Int(Int16.max) {
                    builder.addName(alias, entry: i, side: side, aliasIndex: a, source: entry.source,
                                    priority: entry.priority, properOnly: entry.properOnly && side == 1,
                                    looseKoreanFrom: side == 0 ? Int(entry.looseKoreanFrom) : 0)
                }
            }
        }
        for (i, line) in abbreviations.enumerated() {
            builder.addAbbreviation(line, entry: i)
        }
        for (i, line) in skills.enumerated() {
            for (side, aliases) in [line.korean, line.english].enumerated() {
                for (a, alias) in aliases.enumerated() where a <= Int(Int16.max) {
                    builder.addSkill(alias, entry: i, side: side, aliasIndex: a)
                }
            }
        }

        self.map = builder.map
        self.prefixes = builder.prefixes
        self.singles = builder.singles
        self.maxKeyLength = builder.maxKeyLength
        self.literals = builder.literals
        self.names = names
        self.abbreviations = abbreviations
        self.skills = skills
        self.nameCount = names.lazy.filter { $0.source != .nickname }.count + skills.count
    }

    private struct Builder {
        var map: [String: [Ref]] = [:]
        var prefixes: [UInt64: UInt64] = [:]
        var singles: Set<UInt32> = []
        var maxKeyLength = 0
        var literals: [[Unicode.Scalar]] = []
        /// Keys of the abbreviations the file writes in lower case ("np").
        var lowerCaseAbbreviations: Set<String> = []

        /// Official names may share a key (two items with one name); beyond this many the extra
        /// senses are noise.
        static let maxOfficialSensesPerKey = 3

        mutating func insert(_ key: String, units: GlossaryUnits, _ ref: Ref) {
            let n = units.count
            guard n > 0 else { return }
            var ref = ref
            if n >= 2, units.tokenCount == 1, units.scripts[0] == .word { ref.flags |= Ref.oneWord }
            if units.raw.contains(where: { $0 == "'" || $0 == "\u{2019}" }) { ref.flags |= Ref.apostrophe }
            if var list = map.removeValue(forKey: key) {
                if ref.kind == .name, let existing = list.first(where: { $0.kind == .name }) {
                    if existing.rank < ref.rank { map[key] = list; return }
                    if existing.rank > ref.rank { list.removeAll { $0.kind == .name } }
                    else if list.contains(where: { $0.kind == .name && $0.entry == ref.entry && $0.side == ref.side }) {
                        map[key] = list; return
                    } else if ref.rank >> 4 == GlossarySource.official.rawValue,
                              list.lazy.filter({ $0.kind == .name }).count >= Builder.maxOfficialSensesPerKey {
                        map[key] = list; return
                    }
                } else if ref.kind != .name,
                          list.contains(where: { $0.kind == ref.kind && $0.entry == ref.entry }) {
                    map[key] = list; return
                } else if ref.kind == .looseName,
                          list.lazy.filter({ $0.kind == .looseName }).count >= Builder.maxOfficialSensesPerKey {
                    map[key] = list; return
                }
                list.append(ref)
                map[key] = list
                return
            }
            map[key] = [ref]
            if n == 1 {
                singles.insert(units.scalars[0].value)
            } else {
                let p = (UInt64(units.scalars[0].value) << 32) | UInt64(units.scalars[1].value)
                prefixes[p, default: 0] |= GlossaryIndex.lengthBit(n)
            }
            if n > maxKeyLength { maxKeyLength = n }
        }

        /// "8/8", "+10", "M+", "R&D": the letters alone ("88", "10", "m") would match far too
        /// much, so the occurrence must also contain the alias literally.
        mutating func literalIndex(for text: String, units: GlossaryUnits) -> Int32 {
            var raw = units.raw
            while let f = raw.first, f.properties.isWhitespace { raw.removeFirst() }
            while let l = raw.last, l.properties.isWhitespace { raw.removeLast() }
            // A trailing plus is the whole point of "mythic+" however long the word before it.
            if units.count > 3 {
                guard raw.last == "+" else { return -1 }
            } else {
                let symbols: Set<Unicode.Scalar> = ["+", "/", "&"]
                guard raw.contains(where: { symbols.contains($0) }) else { return -1 }
            }
            literals.append(raw)
            return Int32(literals.count - 1)
        }

        mutating func addName(_ alias: GlossaryAlias, entry: Int, side: Int, aliasIndex: Int, source: GlossarySource,
                              priority: UInt8, properOnly: Bool, looseKoreanFrom: Int) {
            let units = GlossaryUnits(alias.text)
            guard units.count > 0 else { return }
            // A nickname that is an ordinary word ("Strangle", "Gadget") would bind the city's name
            // to every such word in chat. Capital-only nicknames are dealt with below.
            if source == .nickname, aliasIndex > 0, units.tokenCount == 1, units.hasLowercase(0..<units.count),
               GlossaryStopwords.isEverydayWord(units.fullKey) { return }
            let rank = source.rawValue << 4 | (source == .official ? min(priority, 15) : 0)
            var ref = Ref(kind: .name, rank: rank, side: UInt8(side), alias: Int16(aliasIndex), entry: Int32(entry))
            if properOnly && units.tokenCount == 1 { ref.flags |= Ref.properOnly }
            if units.hasUppercase(0..<units.count) && !units.hasLowercase(0..<units.count) {
                // "IF", "SW", "TB" are found only in capitals. A longer all-capitals nickname that
                // is no word ("STV", "UBRS") is typed in lower case just as often.
                if source == .official || units.count <= 2 || GlossaryStopwords.isEverydayWord(units.fullKey) {
                    ref.flags |= Ref.capsOnly
                }
            }
            ref.literal = literalIndex(for: alias.text, units: units)
            // Achievements reach chat as links. A short one ("[Explorer]", "[Angler]") is an everyday
            // word unless the chat really shows the link.
            if alias.bracketed && (units.tokenCount == 1 || units.count < 8) {
                ref.flags |= Ref.linkOnly
                insert(units.fullKey, units: units, ref)
                return
            }

            if source == .official, units.tokenCount == 1, units.scripts[0] == .hangul {
                // One Korean word: 대해, 도시, 임시 are names of something in the game data and
                // words of every other sentence.
                if looseKoreanFrom == 0 {
                    if GlossaryStopwords.isEverydayKorean(units.fullKey) { return }
                } else {
                    if units.count < looseKoreanFrom || GlossaryStopwords.isEverydayKorean(units.fullKey) { return }
                    insert(units.fullKey, units: units, Ref(kind: .looseName, side: UInt8(side), entry: Int32(entry)))
                    return
                }
            }

            if source == .official {
                if GlossaryIndex.isSpecificEnough(units, minimumWordLength: 4) {
                    insert(units.fullKey, units: units, ref)
                }
                // "The Deadmines" is usually typed without the article.
                if units.count > 3, units.isBoundary(3), units.key(0..<3) == "the" {
                    let rest = GlossaryUnits(String(alias.text.drop(while: { $0 == " " }).dropFirst(3)))
                    if rest.count + 3 == units.count,
                       GlossaryIndex.isSpecificEnough(rest, minimumWordLength: 6) {
                        insert(rest.fullKey, units: rest, ref)
                    }
                }
            } else {
                insert(units.fullKey, units: units, ref)
            }
        }

        mutating func addSkill(_ alias: GlossaryAlias, entry: Int, side: Int, aliasIndex: Int) {
            let units = GlossaryUnits(alias.text)
            let minimum = units.scripts.first == .word ? 3 : 2
            guard units.count >= minimum else { return }
            // Every one-word spell of the game is a candidate; the ones that are plain English
            // ("Shoot", "Rest") would be offered on every other line.
            if side == 1 && GlossaryStopwords.contains(units.fullKey) { return }
            let ref = Ref(kind: .skill, side: UInt8(side), alias: Int16(aliasIndex), entry: Int32(entry))
            insert(units.fullKey, units: units, ref)
        }

        mutating func addAbbreviation(_ line: GlossaryAbbreviationLine, entry: Int) {
            let units = GlossaryUnits(line.abbreviation)
            guard units.count > 0 else { return }
            let all = 0..<units.count
            let key = units.fullKey
            var ref = Ref(kind: .abbreviation, entry: Int32(entry))
            ref.signature = units.caseSignature(all)
            ref.literal = literalIndex(for: line.abbreviation, units: units)
            let allCaps = units.hasUppercase(all) && !units.hasLowercase(all)
            // "IF", "NO", "UP": written in capitals precisely because the lower-case word is everyday English.
            // The same holds when the file lists the lower-case spelling as a word of its own:
            // "np" is "no problem", only "NP" the raid.
            if allCaps && (GlossaryStopwords.isEverydayWord(key) || lowerCaseAbbreviations.contains(key)) {
                ref.flags |= Ref.capsOnly
            }
            if !allCaps && units.hasUppercase(all) {
                ref.flags |= Ref.mixedCase
                if GlossaryStopwords.isEverydayWord(key) { ref.flags |= Ref.needsCapital }
            }
            if units.count == 1 && ref.literal < 0 && units.scripts[0] != .cjk {
                ref.flags |= Ref.standalone
                if units.scripts[0] == .digit { ref.flags |= Ref.shortTextOnly }
            }
            insert(key, units: units, ref)

            for variant in line.variants {
                let v = GlossaryUnits(variant)
                let vKey = v.fullKey
                let span = 0..<v.count
                guard v.count > 0, vKey != key else { continue }
                var vRef = Ref(kind: .abbreviation, entry: Int32(entry), flags: Ref.variant)
                vRef.signature = v.caseSignature(span)
                vRef.literal = literalIndex(for: variant, units: v)
                // A second spelling that is an everyday word ("live", "need") is taken only in
                // capitals, like the abbreviation itself would be.
                if v.tokenCount == 1 && GlossaryStopwords.isEverydayWord(vKey) {
                    guard v.hasUppercase(span) && !v.hasLowercase(span) else { continue }
                    vRef.flags |= Ref.capsOnly
                }
                if v.count == 1 && vRef.literal < 0 && v.scripts[0] != .cjk {
                    vRef.flags |= Ref.standalone
                    if v.scripts[0] == .digit { vRef.flags |= Ref.shortTextOnly }
                }
                insert(vKey, units: v, vRef)
            }
        }
    }

    private static func lengthBit(_ n: Int) -> UInt64 {
        1 << UInt64(min(n, 65) - 2)
    }

    /// Guard for official names, which are taken from game data wholesale: drops one-syllable Korean names, very short
    /// words, bare numbers and names made only of everyday English words.
    private static func isSpecificEnough(_ units: GlossaryUnits, minimumWordLength: Int) -> Bool {
        let n = units.count
        if n < 2 { return false }
        if units.scripts.contains(where: { $0 == .hangul || $0 == .cjk }) { return true }
        if !units.scripts.contains(.word) { return false }
        let tokens = units.tokens
        if tokens.count == 1 {
            return n >= minimumWordLength && !GlossaryStopwords.contains(tokens[0])
        }
        return n >= 4 && !tokens.allSatisfy { GlossaryStopwords.contains($0) || $0.count < 2 || Int($0) != nil }
    }

    // MARK: Matching

    private struct Candidate {
        var start: Int
        var end: Int
        var refs: [Ref]
        var exactCase: [Bool]
    }

    func match(_ text: String, limits: Limits = Limits()) -> Result {
        if map.isEmpty { return Result() }
        return match(GlossaryUnits(text), limits: limits)
    }

    func match(_ units: GlossaryUnits, limits: Limits = Limits()) -> Result {
        if map.isEmpty { return Result() }
        let n = units.count
        if n == 0 { return Result() }
        let shouted = !units.hasLowercase(0..<n)

        var candidates: [Candidate] = []
        for i in 0..<n {
            let script = units.scripts[i]
            let atBoundary = units.isBoundary(i)
            // Mid-word starts exist only where the script glues words together.
            if !atBoundary && (script == .word || script == .digit) { continue }

            if singles.contains(units.scalars[i].value), atBoundary || script == .cjk {
                consider(start: i, length: 1, units: units, shouted: shouted, into: &candidates)
            }
            guard i + 1 < n else { continue }
            let p = (UInt64(units.scalars[i].value) << 32) | UInt64(units.scalars[i + 1].value)
            guard var mask = prefixes[p] else { continue }
            let room = n - i
            while mask != 0 {
                let bit = mask.trailingZeroBitCount
                mask &= mask - 1
                if bit < 63 {
                    let length = bit + 2
                    if length > room { break }
                    if !atBoundary && script == .hangul && length < 3 { continue }
                    consider(start: i, length: length, units: units, shouted: shouted, into: &candidates)
                } else {
                    var length = 65
                    while length <= min(room, maxKeyLength) {
                        consider(start: i, length: length, units: units, shouted: shouted, into: &candidates)
                        length += 1
                    }
                }
            }
        }
        if candidates.isEmpty { return Result() }

        // Longest match wins; anything overlapping an accepted span is dropped.
        candidates.sort { a, b in
            let la = a.end - a.start, lb = b.end - b.start
            return la != lb ? la > lb : a.start < b.start
        }
        // One exception: an official name inside a longer abbreviation phrase is kept ("strat" in
        // "strat live"), because the abbreviation line alone does not give the official Korean name.
        var covered = [Bool](repeating: false, count: n)
        var coveredByName = [Bool](repeating: false, count: n)
        var explained = [Bool](repeating: false, count: n)
        var accepted: [Candidate] = []
        for var c in candidates {
            let hasName = c.refs.contains { $0.kind == .name }
            var free = true
            for i in c.start..<c.end where covered[i] { free = false; break }
            if !free {
                guard hasName else { continue }
                var nameFree = true
                for i in c.start..<c.end where coveredByName[i] { nameFree = false; break }
                guard nameFree else { continue }
                let keep = c.refs.indices.filter { c.refs[$0].kind == .name }
                c.refs = keep.map { c.refs[$0] }
                c.exactCase = keep.map { c.exactCase[$0] }
            }
            let explains = hasName || c.refs.contains { $0.kind == .abbreviation }
            for i in c.start..<c.end {
                covered[i] = true
                if hasName { coveredByName[i] = true }
                if explains { explained[i] = true }
            }
            accepted.append(c)
        }

        var result = assemble(accepted, limits: limits)
        result.explained = explained
        return result
    }

    /// Checks one span of the text against the dictionary and records it when some entry applies.
    private func consider(start: Int, length: Int, units: GlossaryUnits, shouted: Bool, into candidates: inout [Candidate]) {
        let n = units.count
        let end = start + length
        let lastScript = units.scripts[end - 1]
        var plural = false
        var pluralIsAWord = false
        if !units.isBoundary(end) && lastScript != .hangul && lastScript != .cjk {
            // Plural: "locks", "DMs". The "s" is not part of the span.
            guard lastScript == .word, length >= 2, units.scalars[end].value == 0x73,
                  !units.gapBefore[end], units.isBoundary(end + 1) else { return }
            // "was" is not several WAs, nor "des" several DEs — unless written just so.
            // The same for "boss", "toss", "pls": a word of its own, not BoS, ToS or PL in the plural.
            let writtenAsPlural = units.caseFlag[end] == 2 && !units.hasLowercase(start..<end)
            pluralIsAWord = !writtenAsPlural && GlossaryStopwords.contains(units.key(start..<(end + 1)))
            plural = true
        }
        guard let refs = map[units.key(start..<end)] else { return }
        let span = start..<end
        let signature = units.caseSignature(span)
        let lower = units.hasLowercase(span)

        // "see the" is not Seethe and "take down" not Takedown: a name the dictionary writes as
        // one word may be split in chat ("un goro", "kel thuzad") only when a piece of it is a
        // word that says something by itself.
        var splitIntoPlainWords = false
        var pieceStart = start
        var sawGap = false
        var specificPiece = false
        for i in (start + 1)...end where i == end || units.gapBefore[i] {
            if i < end { sawGap = true }
            if i - pieceStart >= 4 && !GlossaryStopwords.contains(units.key(pieceStart..<i)) { specificPiece = true }
            pieceStart = i
        }
        if sawGap && !specificPiece { splitIntoPlainWords = true }
        // "i'd" is not ID. The apostrophe leaves no gap (Un'Goro), so look at the source text.
        var apostropheInside = false
        let rawFirst = Int(units.rawIndex[start]), rawLast = Int(units.rawIndex[end - 1])
        if rawLast - rawFirst > length - 1, rawLast < units.raw.count {
            for i in rawFirst...rawLast where units.raw[i] == "'" || units.raw[i] == "\u{2019}" { apostropheInside = true; break }
        }

        var kept: [Ref] = []
        var exact: [Bool] = []
        for ref in refs {
            if splitIntoPlainWords && ref.flags & Ref.oneWord != 0 { continue }
            if ref.kind == .abbreviation {
                if apostropheInside && ref.flags & Ref.apostrophe == 0 { continue }
            }
            if plural {
                // "BoSs" may be several BoS; "boss" and "BOSS" are not.
                if ref.kind == .abbreviation && ref.flags & Ref.mixedCase != 0 {
                    if signature != ref.signature || units.caseFlag[end] != 2 { continue }
                } else if pluralIsAWord {
                    continue
                }
            }
            if ref.literal >= 0 {
                if !containsLiteral(literals[Int(ref.literal)], units: units, span: span) { continue }
            } else if ref.flags & Ref.standalone != 0 {
                guard signature == ref.signature, units.isHardBoundary(start), units.isHardBoundary(end) else { continue }
                if ref.flags & Ref.shortTextOnly != 0 && n > 3 { continue }
            }
            if ref.flags & Ref.linkOnly != 0 && !isLink(units, span: span) { continue }
            if ref.flags & Ref.properOnly != 0 {
                // In an all-capitals message a capital proves nothing.
                let written = units.caseFlag[start] == 1 && !(shouted && n > length)
                if !written && !isLink(units, span: span) { continue }
            }
            if ref.flags & Ref.needsCapital != 0 && !units.hasUppercase(span) { continue }
            if ref.flags & Ref.capsOnly != 0 {
                if lower { continue }
                // In an all-capitals message capitals prove nothing: "LF TANK IF YOU CAN".
                if shouted && n > length && GlossaryStopwords.isEverydayWord(units.key(span)) { continue }
            }
            kept.append(ref)
            exact.append(signature == ref.signature)
        }
        if kept.isEmpty { return }
        // "BRM" is Blackrock Mountain, not "BrM" the Brewmaster: when some entry is spelled exactly
        // as the chat wrote it, mixed-case abbreviations that are not step aside.
        if kept.count > 1, !lower, units.hasUppercase(span) {
            let exactExists = kept.indices.contains {
                kept[$0].kind == .abbreviation ? exact[$0] : kept[$0].flags & Ref.capsOnly != 0
            }
            if exactExists {
                let keep = kept.indices.filter {
                    !(kept[$0].kind == .abbreviation && kept[$0].flags & Ref.mixedCase != 0 && !exact[$0])
                }
                kept = keep.map { kept[$0] }
                exact = keep.map { exact[$0] }
            }
        }
        candidates.append(Candidate(start: start, end: end, refs: kept, exactCase: exact))
    }

    /// True when the span is written inside square brackets: "[Explorer]".
    private func isLink(_ units: GlossaryUnits, span: Range<Int>) -> Bool {
        let raw = units.raw
        var i = Int(units.rawIndex[span.lowerBound]) - 1
        while i >= 0, raw[i].properties.isWhitespace { i -= 1 }
        guard i >= 0, raw[i] == "[" else { return false }
        var j = Int(units.rawIndex[span.upperBound - 1]) + 1
        while j < raw.count, raw[j].properties.isWhitespace { j += 1 }
        return j < raw.count && raw[j] == "]"
    }

    private func containsLiteral(_ literal: [Unicode.Scalar], units: GlossaryUnits, span: Range<Int>) -> Bool {
        let raw = units.raw
        let first = Int(units.rawIndex[span.lowerBound])
        let last = Int(units.rawIndex[span.upperBound - 1])
        let lo = max(0, first - literal.count)
        let hi = min(raw.count, last + 1 + literal.count)
        guard hi - lo >= literal.count else { return false }
        var i = lo
        while i + literal.count <= hi {
            var same = true
            for j in 0..<literal.count where raw[i + j] != literal[j] { same = false; break }
            if same { return true }
            i += 1
        }
        return false
    }

    private func assemble(_ accepted: [Candidate], limits: Limits) -> Result {
        struct NameHit { var rank: UInt8; var length: Int; var start: Int; var entry: Int; var pair: GlossaryPair }
        struct AbbreviationHit { var tier: Int; var start: Int; var entry: Int32 }
        struct SkillHit { var length: Int; var start: Int; var pair: GlossaryPair }
        var nameHits: [NameHit] = []
        var abbreviationHits: [AbbreviationHit] = []
        var skillHits: [SkillHit] = []

        for c in accepted {
            for (k, ref) in c.refs.enumerated() {
                switch ref.kind {
                case .name:
                    let entry = names[Int(ref.entry)]
                    nameHits.append(NameHit(rank: ref.rank, length: c.end - c.start, start: c.start, entry: Int(ref.entry),
                                            pair: GlossaryIndex.pair(entry.line, side: Int(ref.side), alias: Int(ref.alias))))
                case .skill:
                    let line = skills[Int(ref.entry)]
                    skillHits.append(SkillHit(length: c.end - c.start, start: c.start,
                                              pair: GlossaryPair(korean: line.korean[0].text, english: line.english[0].text)))
                case .looseName:
                    let line = names[Int(ref.entry)].line
                    skillHits.append(SkillHit(length: c.end - c.start, start: c.start,
                                              pair: GlossaryPair(korean: line.korean[0].text, english: line.english[0].text)))
                case .abbreviation:
                    var tier = c.exactCase[k] ? 0 : 1
                    if ref.flags & Ref.variant != 0 { tier = 2 }
                    if ref.flags & Ref.standalone != 0 { tier = 3 }
                    abbreviationHits.append(AbbreviationHit(tier: tier, start: c.start, entry: ref.entry))
                }
            }
        }

        var result = Result()

        nameHits.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.length != $1.length { return $0.length > $1.length }
            return $0.start < $1.start
        }
        for hit in nameHits where result.names.count < limits.names && !result.names.contains(hit.pair) {
            result.names.append(hit.pair)
        }

        abbreviationHits.sort {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.entry < $1.entry
        }
        for hit in abbreviationHits where result.abbreviations.count < limits.abbreviations {
            let sense = abbreviations[Int(hit.entry)].sense
            if !result.abbreviations.contains(sense) { result.abbreviations.append(sense) }
        }

        skillHits.sort {
            if $0.length != $1.length { return $0.length > $1.length }
            return $0.start < $1.start
        }
        // A thing already given as a binding name is not offered again as a loose one.
        let named = Set(nameHits.map { names[$0.entry].line.english[0].text.lowercased() })
        for hit in skillHits where result.skills.count < limits.skills && !result.skills.contains(hit.pair)
            && !named.contains(hit.pair.english.lowercased()) {
            result.skills.append(hit.pair)
        }
        return result
    }

    /// The pair shown to the translation model. When the text used a nickname, that nickname and
    /// its "when this sense applies" hint are appended after a bar, so the model sees which
    /// word of the chat the pair is about: korean "언더시티", english "Undercity | UC".
    private static func pair(_ line: GlossaryNameLine, side: Int, alias: Int) -> GlossaryPair {
        var korean = line.korean[0].text
        var english = line.english[0].text
        if side == 0 {
            let a = line.korean[alias]
            if alias > 0 { korean += " | " + a.written } else if let note = a.note { korean += "(\(note))" }
        } else {
            let a = line.english[alias]
            if alias > 0 { english += " | " + a.written } else if let note = a.note { english += "(\(note))" }
        }
        return GlossaryPair(korean: korean, english: english)
    }
}
