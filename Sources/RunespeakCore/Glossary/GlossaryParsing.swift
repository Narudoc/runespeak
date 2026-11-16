import Foundation
import CoreFoundation

/// One spelling of a name: "ZG (the raid)" → text "ZG", note "the raid".
struct GlossaryAlias: Sendable, Hashable {
    var text: String
    /// "When this sense applies" explanation written in parentheses after the alias.
    var note: String?
    /// A name that reaches chat as a link: "[Explorer]". `text` holds the name without the brackets.
    var bracketed = false
    /// The alias as written in the file, note included.
    var written: String { note.map { "\(text)(\($0))" } ?? text }
}

/// One name with every spelling it goes by in each language: a row of my_terms.tsv or
/// nicknames.tsv. The first spelling of each side is the name itself.
struct GlossaryNameLine: Sendable, Hashable {
    var korean: [GlossaryAlias]
    var english: [GlossaryAlias]
}

/// One row of official_names.<flavor>.tsv.
struct GlossaryOfficialName: Sendable, Hashable {
    /// Lower-cased: zone, instance, boss, spec, spell, item, achievement ... Unknown kinds are kept as they are.
    var kind: String
    var korean: String
    var english: String
}

/// One row of zone_places.<flavor>.tsv: a place and the zone it lies in. A row without a place
/// (`place` nil) gives one more Korean name the zone goes by.
struct GlossaryZonePlace: Sendable, Hashable {
    var zone: GlossaryPair
    var place: GlossaryPair?
}

/// One row of abbreviations.<flavor>.tsv.
struct GlossaryAbbreviationLine: Sendable, Hashable {
    var abbreviation: String
    /// The row as the translation model gets it.
    var sense: GlossaryAbbreviation
    /// Other spellings, from the "also" column.
    var variants: [String]
}

/// One row of chat_commands.<flavor>.tsv.
struct GlossaryCommandLine: Sendable, Hashable {
    /// Chat type, upper-cased: SAY, WHISPER ...
    var type: String
    /// The English command to emit; nil when the row does not name one.
    var canonical: String?
    /// Every accepted spelling, with the leading slash, as written.
    var commands: [String]
}

enum GlossaryParser {

    // MARK: Reading

    /// Reads a text file leniently: UTF-8 (with or without BOM), UTF-16 with BOM, or CP949 —
    /// my_terms.tsv is edited by hand, and some editors still save Korean text that way.
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let s = String(data: data, encoding: .utf16) { return s }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        if let s = String(data: data, encoding: cp949) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    private static func lines(_ text: String) -> [Substring.UTF8View.SubSequence] {
        text.utf8.split(omittingEmptySubsequences: true) { $0 == 0x0A || $0 == 0x0D }
    }

    // MARK: Aliases

    /// One entry of an "aliases" cell. A parenthesis that ends the entry is its hint, with or
    /// without a space before it: "ZG (the raid)". "[Explorer]" is a name that reaches chat as a link.
    static func alias(_ piece: String) -> GlossaryAlias? {
        if piece.isEmpty { return nil }
        if piece.hasPrefix("["), piece.hasSuffix("]"), piece.count > 2 {
            let inner = piece.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, !inner.contains("["), !inner.contains("]") {
                return GlossaryAlias(text: inner, note: nil, bracketed: true)
            }
        }
        guard piece.hasSuffix(")") else { return GlossaryAlias(text: piece, note: nil) }
        var depth = 0
        var open: String.Index?
        var i = piece.endIndex
        while i > piece.startIndex {
            i = piece.index(before: i)
            let c = piece[i]
            if c == ")" { depth += 1 }
            else if c == "(" {
                depth -= 1
                if depth == 0 { open = i; break }
            }
        }
        guard let open, open > piece.startIndex else { return GlossaryAlias(text: piece, note: nil) }
        let text = piece[..<open].trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return GlossaryAlias(text: piece, note: nil) }
        let note = String(piece[piece.index(after: open)..<piece.index(before: piece.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        return GlossaryAlias(text: text, note: note.isEmpty ? nil : note)
    }

    // MARK: Tab-separated dictionary files

    /// Data rows of a tab-separated file, each reduced to the wanted columns in the order asked
    /// for. Lines whose first visible character is '#' are comments. The first other line is the
    /// header when it names at least one wanted column: columns are then found by name (extra
    /// columns and another order are fine) and a wanted column the header lacks comes back
    /// empty. A file without such a line is read by position, its first line included.
    /// `overlong` counts the rows that had more cells than the header: a tab typed inside a
    /// name. Their surplus cells are joined to the last header column instead of being lost.
    static func tsvTable(_ text: String, columns: [String]) -> (rows: [[String]], overlong: Int) {
        var positions: [Int?]?
        var width = 0
        var overlong = 0
        var out: [[String]] = []
        for line in lines(text) {
            if line.first(where: { $0 != 0x20 && $0 != 0x09 }) == 0x23 { continue }
            var fields = line.split(separator: 0x09, omittingEmptySubsequences: false).map { field($0) }
            if positions == nil {
                let header = fields.map { $0.lowercased() }
                if columns.contains(where: { header.contains($0) }) {
                    positions = columns.map { header.firstIndex(of: $0) }
                    width = header.count
                    continue
                }
                positions = columns.indices.map { Optional($0) }
            }
            if width > 0, fields.count > width {
                let surplus = fields[width...].filter { !$0.isEmpty }
                if !surplus.isEmpty {
                    fields[width - 1] = ([fields[width - 1]] + surplus).filter { !$0.isEmpty }.joined(separator: " ")
                    overlong += 1
                }
                fields.removeSubrange(width...)
            }
            var row: [String] = []
            row.reserveCapacity(columns.count)
            var blank = true
            for p in positions ?? [] {
                let value = p.flatMap { $0 < fields.count ? fields[$0] : nil } ?? ""
                if !value.isEmpty { blank = false }
                row.append(value)
            }
            if !blank { out.append(row) }
        }
        return (out, overlong)
    }

    static func tsvRows(_ text: String, columns: [String]) -> [[String]] {
        tsvTable(text, columns: columns).rows
    }

    private static func field(_ bytes: Substring.UTF8View.SubSequence) -> String {
        var slice = bytes
        while let first = slice.first, first == 0x20 { slice = slice.dropFirst() }
        while let last = slice.last, last == 0x20 { slice = slice.dropLast() }
        return String(decoding: slice, as: UTF8.self)
    }

    /// official_names.<flavor>.tsv: kind, korean, english.
    static let officialColumns = ["kind", "korean", "english"]
    /// nicknames.tsv and the user's my_terms.tsv.
    static let nicknameColumns = ["korean", "english", "aliases"]
    static let correctionColumns = ["source", "translation", "note"]
    static let abbreviationColumns = ["abbr", "also", "english", "korean", "note"]
    static let commandColumns = ["chat_type", "canonical", "aliases"]
    /// zone_places.<flavor>.tsv.
    static let zonePlaceColumns = ["zone_korean", "zone_english", "korean", "english"]

    static func parseOfficialNames(_ text: String) -> [GlossaryOfficialName] {
        officialNames(tsvRows(text, columns: officialColumns))
    }

    static func officialNames(_ rows: [[String]]) -> [GlossaryOfficialName] {
        var out: [GlossaryOfficialName] = []
        for row in rows where !row[1].isEmpty && !row[2].isEmpty {
            out.append(GlossaryOfficialName(kind: row[0].lowercased(), korean: row[1], english: row[2]))
        }
        return out
    }

    /// zone_places.<flavor>.tsv: zone_korean, zone_english, korean, english. A row needs both
    /// names of its zone; a place needs both of its names, and a row that has neither is the
    /// zone's other Korean name.
    static func parseZonePlaces(_ text: String) -> [GlossaryZonePlace] {
        zonePlaces(tsvRows(text, columns: zonePlaceColumns))
    }

    static func zonePlaces(_ rows: [[String]]) -> [GlossaryZonePlace] {
        var out: [GlossaryZonePlace] = []
        out.reserveCapacity(rows.count)
        for row in rows where !row[0].isEmpty && !row[1].isEmpty && row[2].isEmpty == row[3].isEmpty {
            out.append(GlossaryZonePlace(zone: GlossaryPair(korean: row[0], english: row[1]),
                                         place: row[2].isEmpty ? nil : GlossaryPair(korean: row[2], english: row[3])))
        }
        return out
    }

    /// nicknames.tsv and my_terms.tsv: korean, english, aliases ("UC, Under (hint)"). An alias
    /// written in Hangul joins the Korean side, any other the English side.
    static func parseNicknames(_ text: String) -> [GlossaryNameLine] {
        nicknames(tsvRows(text, columns: nicknameColumns))
    }

    static func nicknames(_ rows: [[String]]) -> [GlossaryNameLine] {
        var out: [GlossaryNameLine] = []
        for row in rows where !row[0].isEmpty && !row[1].isEmpty {
            var line = GlossaryNameLine(korean: [GlossaryAlias(text: row[0], note: nil)],
                                        english: [GlossaryAlias(text: row[1], note: nil)])
            for piece in splitList(row[2]) {
                guard let alias = alias(piece) else { continue }
                let hangul = alias.text.unicodeScalars.contains { $0.value >= 0xAC00 && $0.value <= 0xD7A3 }
                if hangul {
                    if !line.korean.contains(where: { $0.text == alias.text && $0.note == alias.note }) { line.korean.append(alias) }
                } else if !line.english.contains(where: { $0.text == alias.text && $0.note == alias.note }) {
                    line.english.append(alias)
                }
            }
            out.append(line)
        }
        return out
    }

    /// Splits a comma-separated cell; commas inside a parenthesised hint do not split.
    static func splitList(_ cell: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var current = ""
        for c in cell {
            if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) }
            if (c == "," || c == "，") && depth == 0 {
                out.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// abbreviations.<flavor>.tsv: abbr, also, english, korean, note.
    static func parseAbbreviations(_ text: String) -> [GlossaryAbbreviationLine] {
        abbreviations(tsvRows(text, columns: abbreviationColumns))
    }

    static func abbreviations(_ rows: [[String]]) -> [GlossaryAbbreviationLine] {
        var out: [GlossaryAbbreviationLine] = []
        for row in rows where !row[0].isEmpty {
            guard let sense = abbreviationSense(abbreviation: row[0], english: row[2], korean: row[3], note: row[4]) else { continue }
            var variants: [String] = []
            for spelling in splitList(row[1]) where spelling != row[0] && !variants.contains(spelling) {
                variants.append(spelling)
            }
            out.append(GlossaryAbbreviationLine(abbreviation: row[0], sense: sense, variants: variants))
        }
        return out
    }

    /// One abbreviation sense for the prompt. A Korean cell that only repeats the English one
    /// is dropped, a note the author wrapped in parentheses is unwrapped, and a row that
    /// explains nothing gives no sense.
    static func abbreviationSense(abbreviation: String, english: String, korean: String, note: String) -> GlossaryAbbreviation? {
        if english.isEmpty && korean.isEmpty && note.isEmpty { return nil }
        let bare = note.hasPrefix("(") && note.hasSuffix(")") ? String(note.dropFirst().dropLast()) : note
        return GlossaryAbbreviation(abbr: abbreviation, english: english, korean: korean == english ? "" : korean,
                                    note: bare.trimmingCharacters(in: .whitespaces))
    }

    /// chat_commands.<flavor>.tsv: chat_type, canonical, aliases (space separated).
    static func parseCommands(_ text: String) -> [GlossaryCommandLine] {
        commands(tsvRows(text, columns: commandColumns))
    }

    static func commands(_ rows: [[String]]) -> [GlossaryCommandLine] {
        var out: [GlossaryCommandLine] = []
        for row in rows where !row[0].isEmpty {
            func spellings(_ cell: String) -> [String] {
                cell.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
                    .filter { $0.hasPrefix("/") && $0.count > 1 }
            }
            let canonical = spellings(row[1]).first
            var all = spellings(row[2])
            if let canonical, !all.contains(canonical) { all.insert(canonical, at: 0) }
            if all.isEmpty { continue }
            out.append(GlossaryCommandLine(type: row[0].uppercased(), canonical: canonical, commands: all))
        }
        return out
    }

    // MARK: corrections.tsv

    /// corrections.tsv: source, translation, note (may be empty).
    static func parseCorrections(_ text: String) -> [CorrectionExample] {
        var out: [CorrectionExample] = []
        for row in tsvRows(text, columns: correctionColumns) where !row[0].isEmpty && !row[1].isEmpty {
            out.append(CorrectionExample(source: row[0], translation: row[1], note: row[2].isEmpty ? nil : row[2]))
        }
        return out
    }

    /// The row `addCorrection` writes. Tabs and line breaks inside a field become spaces so the
    /// row reads back as the same three fields.
    static func correctionLine(_ example: CorrectionExample) -> String {
        func flat(_ s: String) -> String {
            s.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        var line = flat(example.source) + "\t" + flat(example.translation)
        if let note = example.note.map(flat), !note.isEmpty { line += "\t" + note }
        return line
    }
}
