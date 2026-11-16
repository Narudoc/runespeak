import Foundation

/// Loads the dictionary files and answers "which dictionary material is relevant to this chat text".
///
/// Files (missing ones are simply skipped):
/// - `paths.root`: my_terms.tsv, corrections.tsv — the user's own
/// - `paths.dataDirectory`: nicknames.tsv and, by flavor, official_names / abbreviations /
///   chat_commands / zone_places `.classic.tsv` or `.retail.tsv` — shipped with the app (see
///   `DictionaryFiles`)
public final class GlossaryStore: GlossaryProviding, @unchecked Sendable {

    private let paths: AppPaths
    private let lock = NSLock()

    // Guarded by `lock`. `index` and `commands` are immutable snapshots that are swapped whole.
    private var index: GlossaryIndex
    private var places: GlossaryPlaceIndex
    private var commands: CommandTable
    private var corrections: CorrectionSet
    private var flavor: GameFlavor
    private var warnings: [String]

    public init(paths: AppPaths, flavor: GameFlavor) {
        self.paths = paths
        self.flavor = flavor
        let loaded = GlossaryStore.load(paths: paths, flavor: flavor)
        index = loaded.index
        places = loaded.places
        commands = loaded.commands
        warnings = loaded.warnings
        corrections = GlossaryStore.loadCorrections(paths: paths)
    }

    /// What was odd about the files of the last load, one line each, for errors.log:
    /// a dictionary file that is missing, rows with a stray tab.
    public var loadWarnings: [String] {
        lock.lock(); defer { lock.unlock() }
        return warnings
    }

    // MARK: GlossaryProviding

    public var entryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return index.nameCount
    }

    public var abbreviationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return index.abbreviations.count
    }

    /// Flavor of the files currently loaded.
    public var loadedFlavor: GameFlavor {
        lock.lock(); defer { lock.unlock() }
        return flavor
    }

    /// Number of zones with known places (0 means zone_places.<flavor>.tsv is missing: no place hints).
    public var placeZoneCount: Int {
        lock.lock(); defer { lock.unlock() }
        return places.zoneCount
    }

    /// Number of places in those zones.
    public var placeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return places.placeCount
    }

    /// The zone a channel label names, both names, when its places are known ("1. 공개 -
    /// 스톰원드" → 스톰윈드 / Stormwind City); nil for any other label.
    public func zone(forChannelLabel label: String) -> GlossaryPair? {
        lock.lock()
        let places = self.places
        lock.unlock()
        return places.zone(forChannelLabel: label).map { places.zone($0) }
    }

    public func hints(for texts: [String]) -> GlossaryHints {
        hints(forLines: texts.map { GlossaryLine(text: $0) })
    }

    public func hints(forLines lines: [GlossaryLine]) -> GlossaryHints {
        lock.lock()
        let index = self.index
        let places = self.places
        let corrections = self.corrections
        lock.unlock()

        var hints = GlossaryHints()
        var placeCount = 0
        for line in lines {
            let text = line.text
            let units = GlossaryUnits(text)
            let found = index.match(units)
            // Places of the zone the line was said in, for the words nothing above explains.
            if placeCount < GlossaryStore.batchLimits.places, let label = line.channelLabel,
               let zone = places.zone(forChannelLabel: label) {
                let offered = places.places(inZone: zone, units: units, explained: found.explained,
                                            limit: min(GlossaryPlaceIndex.placesPerLine, GlossaryStore.batchLimits.places - placeCount))
                if !offered.isEmpty {
                    let pair = places.zone(zone)
                    let entry = hints.zonePlaces.firstIndex { $0.zone == pair } ?? hints.zonePlaces.count
                    if entry == hints.zonePlaces.count { hints.zonePlaces.append(GlossaryZonePlaces(zone: pair, places: [])) }
                    for found in offered {
                        // The same place found by the same words in another line is one hint.
                        let place = GlossaryPlaceHint(korean: found.pair.korean, english: found.pair.english, written: found.written)
                        let known = hints.zonePlaces[entry].places.contains {
                            $0.english == place.english && $0.written.lowercased() == place.written.lowercased()
                        }
                        if known { continue }
                        hints.zonePlaces[entry].places.append(place)
                        placeCount += 1
                    }
                }
            }
            for pair in found.names where hints.names.count < GlossaryStore.batchLimits.names && !hints.names.contains(pair) {
                hints.names.append(pair)
            }
            for sense in found.abbreviations where hints.abbreviations.count < GlossaryStore.batchLimits.abbreviations && !hints.abbreviations.contains(sense) {
                hints.abbreviations.append(sense)
            }
            for pair in found.skills where hints.looseNames.count < GlossaryStore.batchLimits.skills && !hints.looseNames.contains(pair) {
                hints.looseNames.append(pair)
            }
            for example in corrections.similar(to: text, limit: GlossaryStore.correctionsPerText)
            where hints.corrections.count < GlossaryStore.batchLimits.corrections && !hints.corrections.contains(example) {
                hints.corrections.append(example)
            }
        }
        return hints
    }

    public func parseOutgoing(_ input: String) -> OutgoingCommand {
        lock.lock()
        let commands = self.commands
        lock.unlock()
        return commands.parse(input)
    }

    public func addCorrection(_ example: CorrectionExample) {
        let clean = CorrectionExample(
            source: GlossaryStore.singleLine(example.source),
            translation: GlossaryStore.singleLine(example.translation),
            note: example.note.map(GlossaryStore.singleLine).flatMap { $0.isEmpty ? nil : $0 })
        guard !clean.source.isEmpty, !clean.translation.isEmpty else { return }

        lock.lock(); defer { lock.unlock() }
        corrections.add(clean)
        appendToCorrectionsFile(GlossaryParser.correctionLine(clean))
    }

    public func reload(flavor: GameFlavor) {
        // Parsing happens outside the lock so hints() keeps answering from the old snapshot meanwhile.
        let loaded = GlossaryStore.load(paths: paths, flavor: flavor)
        lock.lock(); defer { lock.unlock() }
        self.flavor = flavor
        index = loaded.index
        places = loaded.places
        commands = loaded.commands
        warnings = loaded.warnings
        // corrections.tsv is read under the lock: addCorrection appends under the same lock, so the file
        // can never be read half-way through an append or miss a correction made during the reload.
        corrections = GlossaryStore.loadCorrections(paths: paths)
    }

    // MARK: Loading

    private static let batchLimits = (names: 80, abbreviations: 60, skills: 30, corrections: 10, places: 8)
    private static let correctionsPerText = 3

    private static func singleLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isNewline }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Kinds whose names people look for first when several official names share a spelling
    /// (only the first few senses of a spelling are kept). Unlisted kinds rank with items.
    private static let kindOrder: [String: Int] = [
        "zone": 0, "instance": 0, "class": 0, "race": 0, "spec": 0,
        "boss": 1, "faction": 1, "profession": 1,
        "subzone": 2, "mount": 3, "currency": 3,
        "item": 4, "spell": 5, "achievement": 6,
    ]

    /// Kinds whose one-word English names players type in any case ("lfm stratholme", "need mage").
    /// One-word names of the other kinds are too often ordinary words ("Honey", "Tiger", "Tower").
    private static let anyCaseKinds: Set<String> = ["zone", "instance", "boss", "faction", "class", "race", "profession", "spec"]

    /// Kinds whose one-word names are context-dependent in both languages ("Charge", "돌진").
    private static let looseKinds: Set<String> = ["spell", "spec"]

    private static func load(paths: AppPaths, flavor: GameFlavor)
        -> (index: GlossaryIndex, places: GlossaryPlaceIndex, commands: CommandTable, warnings: [String]) {
        let files = DictionaryFiles.names(for: flavor)
        let data = paths.dataDirectory
        var warnings: [String] = []
        func read(_ name: String) -> String {
            guard let text = GlossaryParser.readText(data.appendingPathComponent(name)) else {
                warnings.append("사전 파일이 없습니다: \(name)")
                return ""
            }
            return text
        }
        func table(_ name: String, _ columns: [String]) -> [[String]] {
            let parsed = GlossaryParser.tsvTable(read(name), columns: columns)
            if parsed.overlong > 0 {
                warnings.append("\(name): 칸이 머리글보다 많은 줄 \(parsed.overlong)개 (이름 안에 탭 문자가 있는지 확인하세요)")
            }
            return parsed.rows
        }

        var names: [GlossaryNameEntry] = []
        for line in GlossaryParser.parseNicknames(GlossaryParser.readText(paths.myTermsFile) ?? "") {
            names.append(GlossaryNameEntry(line: line, source: .mine))
        }

        let rows = GlossaryParser.officialNames(table(files.officialNames, GlossaryParser.officialColumns))
        let ordered = rows.indices.sorted {
            let a = kindOrder[rows[$0].kind] ?? 4, b = kindOrder[rows[$1].kind] ?? 4
            return a != b ? a < b : $0 < $1
        }

        // nicknames.tsv is one file for both flavors, but some places were renamed in Korean
        // between the classic and the live client. The loaded flavor's official table decides
        // the Korean name; the row's own stays as one more spelling that leads to it.
        var officialKorean = [String: String](minimumCapacity: rows.count)
        for i in ordered where officialKorean[rows[i].english] == nil { officialKorean[rows[i].english] = rows[i].korean }
        for var line in GlossaryParser.nicknames(table(DictionaryFiles.nicknames, GlossaryParser.nicknameColumns)) {
            if let korean = officialKorean[line.english[0].text], korean != line.korean[0].text {
                let own = line.korean[0]
                line.korean[0] = GlossaryAlias(text: korean, note: nil)
                if !line.korean.contains(where: { $0.text == own.text }) { line.korean.append(own) }
            }
            names.append(GlossaryNameEntry(line: line, source: .nickname))
        }

        names.reserveCapacity(names.count + rows.count)
        var skills: [GlossaryNameLine] = []
        // The same pair listed under two kinds (a city that is also a zone) is one name.
        var seen = Set<GlossaryPair>(minimumCapacity: rows.count)
        for i in ordered {
            let row = rows[i]
            guard seen.insert(GlossaryPair(korean: row.korean, english: row.english)).inserted else { continue }
            var line = GlossaryNameLine(korean: [GlossaryAlias(text: row.korean, note: nil)],
                                        english: [GlossaryAlias(text: row.english, note: nil)])
            let loose = looseKinds.contains(row.kind)
            if loose && isSingleWord(row.english) {
                // "Charge", "Fear", "Frost": as often an ordinary word as the spell or the
                // specialization, so the model gets these apart from the names it must use.
                skills.append(line)
                continue
            }
            if row.kind == "achievement" {
                line.korean[0].bracketed = true
                line.english[0].bracketed = true
            }
            let minor = !anyCaseKinds.contains(row.kind)
            names.append(GlossaryNameEntry(line: line, source: .official,
                                           properOnly: minor,
                                           priority: UInt8(kindOrder[row.kind] ?? 4),
                                           // "야수" (Beast Mastery) and "꿀단지" (an item) are ordinary
                                           // words; a two-syllable item or subzone name is not worth offering.
                                           looseKoreanFrom: loose ? 2 : (minor ? 3 : 0)))
        }
        let abbreviations = GlossaryParser.abbreviations(table(files.abbreviations, GlossaryParser.abbreviationColumns))
        let index = GlossaryIndex(names: names, abbreviations: abbreviations, skills: skills)

        // The official zone and instance names tell a misread channel label from the name of
        // a zone the places table has no row for.
        var zoneNames: [String] = []
        for row in rows where row.kind == "zone" || row.kind == "instance" {
            zoneNames.append(row.korean)
            zoneNames.append(row.english)
        }
        let places = GlossaryPlaceIndex(rows: GlossaryParser.zonePlaces(table(files.zonePlaces, GlossaryParser.zonePlaceColumns)),
                                        otherZoneNames: zoneNames)

        let commands = CommandTable(lines: GlossaryParser.commands(table(files.chatCommands, GlossaryParser.commandColumns)))
        return (index, places, commands, warnings)
    }

    private static func isSingleWord(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || $0 == "'" || $0 == "\u{2019}" }
    }

    private static func loadCorrections(paths: AppPaths) -> CorrectionSet {
        var corrections = CorrectionSet()
        for example in GlossaryParser.parseCorrections(GlossaryParser.readText(paths.correctionsFile) ?? "") {
            corrections.add(example)
        }
        return corrections
    }

    /// One O_APPEND write per line, so a crash can at worst lose the line being written, never
    /// damage earlier ones. Called with `lock` held.
    private func appendToCorrectionsFile(_ line: String) {
        let url = paths.correctionsFile
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        var payload = Data()
        if !fm.fileExists(atPath: url.path) {
            let header = "# Runespeak이 [다시 번역]의 결과를 한 줄씩 덧붙이는 교정 기록입니다.\n"
                + "# 칸은 탭으로 나뉩니다: 원문, 고친 번역, 설명(비워도 됨). 필요 없는 줄은 지워도 됩니다.\n"
                + GlossaryParser.correctionColumns.joined(separator: "\t") + "\n"
            guard fm.createFile(atPath: url.path, contents: Data(header.utf8)) else { return }
        } else if let handle = try? FileHandle(forReadingFrom: url) {
            // A hand-edited file may not end with a line break.
            if let size = try? handle.seekToEnd(), size > 0 {
                try? handle.seek(toOffset: size - 1)
                if let last = try? handle.read(upToCount: 1), last != Data([0x0A]) { payload.append(0x0A) }
            }
            try? handle.close()
        }
        payload.append(Data((line + "\n").utf8))

        let fd = open(url.path, O_WRONLY | O_APPEND)
        guard fd >= 0 else { return }
        defer { close(fd) }
        payload.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }
}

// MARK: - Corrections

/// Corrected translations, looked up by similarity so an OCR slip ("GADGETZN" for "GADGETZAN") or
/// a slightly different wording still finds the correction.
struct CorrectionSet: Sendable {
    private struct Item: Sendable {
        var example: CorrectionExample
        var key: [Unicode.Scalar]
        var bigrams: [UInt64]   // sorted
    }
    private var items: [Item] = []
    private var byKey: [String: Int] = [:]

    var count: Int { items.count }

    /// A later example for the same source text replaces the earlier one.
    mutating func add(_ example: CorrectionExample) {
        let units = GlossaryUnits(example.source, keepRaw: false)
        guard units.count > 0 else { return }
        let item = Item(example: example, key: units.scalars, bigrams: CorrectionSet.bigrams(units.scalars))
        let key = units.fullKey
        if let existing = byKey[key] {
            items[existing] = item
        } else {
            byKey[key] = items.count
            items.append(item)
        }
    }

    func similar(to text: String, limit: Int) -> [CorrectionExample] {
        if items.isEmpty || limit <= 0 { return [] }
        let units = GlossaryUnits(text, keepRaw: false)
        let n = units.count
        guard n > 0 else { return [] }
        let key = units.scalars
        let grams = CorrectionSet.bigrams(key)
        var scored: [(score: Double, index: Int)] = []
        for (i, item) in items.enumerated() {
            let m = item.key.count
            let shorter = min(n, m), longer = max(n, m)
            if m == n && item.key == key { scored.append((1, i)); continue }
            // Very short lines ("gg", "inv") are only ever matched exactly.
            if shorter < 5 { continue }
            let ratio = Double(shorter) / Double(longer)
            var best = 0.0
            if ratio >= 0.66 {
                let dice = CorrectionSet.dice(grams, item.bigrams)
                if dice >= CorrectionSet.threshold { best = dice }
            }
            // The corrected line quoted inside a longer message, or the other way round.
            if best == 0, shorter >= 8, ratio >= 0.6,
               CorrectionSet.contains(n >= m ? key : item.key, n >= m ? item.key : key) {
                best = 0.8 + 0.2 * ratio
            }
            if best > 0 { scored.append((best, i)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index > $1.index }
        return scored.prefix(limit).map { items[$0.index].example }
    }

    private static let threshold = 0.8

    private static func bigrams(_ key: [Unicode.Scalar]) -> [UInt64] {
        guard key.count >= 2 else { return [] }
        var out: [UInt64] = []
        out.reserveCapacity(key.count - 1)
        for i in 0..<(key.count - 1) {
            out.append((UInt64(key[i].value) << 32) | UInt64(key[i + 1].value))
        }
        out.sort()
        return out
    }

    /// Sørensen–Dice coefficient over two sorted bigram multisets.
    private static func dice(_ a: [UInt64], _ b: [UInt64]) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        var i = 0, j = 0, shared = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { shared += 1; i += 1; j += 1 }
            else if a[i] < b[j] { i += 1 }
            else { j += 1 }
        }
        return 2 * Double(shared) / Double(a.count + b.count)
    }

    private static func contains(_ haystack: [Unicode.Scalar], _ needle: [Unicode.Scalar]) -> Bool {
        guard needle.count <= haystack.count, let first = needle.first else { return false }
        var i = 0
        while i + needle.count <= haystack.count {
            if haystack[i] == first {
                var same = true
                for j in 1..<needle.count where haystack[i + j] != needle[j] { same = false; break }
                if same { return true }
            }
            i += 1
        }
        return false
    }
}

// MARK: - Chat commands

/// Maps every spelling of a chat command (/s, /say, /ㄴ, /말) to the English command the game
/// understands in any client language.
struct CommandTable: Sendable {
    private struct Command: Sendable {
        var canonical: String
        var takesTarget: Bool
    }
    private var bySpelling: [String: Command] = [:]

    /// Chat types whose first word after the command is a player or channel, not message text.
    private static let targetTypes: Set<String> = ["WHISPER", "SMART_WHISPER", "BN_WHISPER", "CHANNEL"]

    /// The enUS client's chat commands: enough to work when chat_commands.<flavor>.tsv is
    /// missing, and the base the file is laid over. Korean spellings come from the file; the
    /// Korean-keyboard forms of these (/ㄴ for /s) are worked out in `parse`.
    private static let builtIn: [(type: String, commands: [String])] = [
        ("SAY", ["/s", "/say"]),
        ("YELL", ["/y", "/yell", "/sh", "/shout"]),
        ("PARTY", ["/p", "/party"]),
        ("GUILD", ["/g", "/gc", "/gu", "/guild"]),
        ("OFFICER", ["/o", "/osay", "/officer"]),
        ("RAID", ["/ra", "/raid", "/rsay"]),
        ("RAID_WARNING", ["/rw"]),
        ("INSTANCE_CHAT", ["/i", "/instance"]),
        ("SMART_WHISPER", ["/w", "/whisper", "/t", "/tell", "/send"]),
        ("REPLY", ["/r", "/reply"]),
        ("EMOTE", ["/e", "/em", "/me", "/emote"]),
        ("CHANNEL", ["/c", "/csay"]),
    ]

    init(lines: [GlossaryCommandLine]) {
        let base = CommandTable.builtIn.map { GlossaryCommandLine(type: $0.type, canonical: $0.commands[0], commands: $0.commands) }
        for line in base + lines {
            // Without a canonical column value, the first plain-English spelling is the one every
            // client understands; a row of Korean spellings only borrows the built-in command of its chat type.
            guard let canonical = line.canonical
                ?? line.commands.first(where: { $0.dropFirst().allSatisfy { $0.isASCII } })
                ?? CommandTable.builtIn.first(where: { $0.type == line.type })?.commands[0] else { continue }
            let command = Command(canonical: canonical.lowercased(), takesTarget: CommandTable.targetTypes.contains(line.type))
            for spelling in line.commands {
                bySpelling[CommandTable.fold(spelling)] = command
            }
        }
    }

    private static func fold(_ spelling: String) -> String {
        spelling.precomposedStringWithCompatibilityMapping.lowercased()
    }

    /// Letters of the Korean two-set keyboard by the Latin key they sit on: a command typed with
    /// the Korean input source still on ("/ㄱㅁ" for "/ra") is the same key presses.
    private static let keyboard: [Character: Character] = [
        "ㅂ": "q", "ㅈ": "w", "ㄷ": "e", "ㄱ": "r", "ㅅ": "t", "ㅛ": "y", "ㅕ": "u", "ㅑ": "i", "ㅐ": "o", "ㅔ": "p",
        "ㅁ": "a", "ㄴ": "s", "ㅇ": "d", "ㄹ": "f", "ㅎ": "g", "ㅗ": "h", "ㅓ": "j", "ㅏ": "k", "ㅣ": "l",
        "ㅋ": "z", "ㅌ": "x", "ㅊ": "c", "ㅍ": "v", "ㅠ": "b", "ㅜ": "n", "ㅡ": "m",
    ]

    private func lookup(_ word: Substring, folded: String) -> Command? {
        if let command = bySpelling["/" + folded] { return command }
        var latin = ""
        // The word as typed: folding turns these letters into another Unicode block.
        for c in word {
            guard let key = CommandTable.keyboard[c] else { return nil }
            latin.append(key)
        }
        return bySpelling["/" + latin]
    }

    func parse(_ input: String) -> OutgoingCommand {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // A Korean IME in full-width mode types "／".
        guard let first = text.first, first == "/" || first == "／" else {
            return OutgoingCommand(command: nil, text: text)
        }
        let afterSlash = text.dropFirst()
        let wordEnd = afterSlash.firstIndex(where: { $0.isWhitespace }) ?? afterSlash.endIndex
        let word = afterSlash[..<wordEnd]
        let rest = afterSlash[wordEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        if word.isEmpty { return OutgoingCommand(command: nil, text: text) }

        // Numbered channels: "/1 hello", "/2 WTS ...".
        let folded = CommandTable.fold(String(word))
        if folded.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return OutgoingCommand(command: "/" + folded, text: rest)
        }

        guard let command = lookup(word, folded: folded) else {
            // Not a chat command (/roll 100, /invite Name, /dance): nothing in it is to be translated.
            return OutgoingCommand(command: text, text: "")
        }
        guard command.takesTarget else {
            return OutgoingCommand(command: command.canonical, text: rest)
        }
        let targetEnd = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
        let target = rest[..<targetEnd]
        if target.isEmpty { return OutgoingCommand(command: command.canonical, text: "") }
        let message = rest[targetEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        return OutgoingCommand(command: "\(command.canonical) \(target)", text: message)
    }
}
