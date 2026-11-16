import Foundation
import CoreGraphics

/// The game's own context menu over the chat window (right click on a chat tab): an opaque
/// panel with a column of short labels. While it is open, the chat rows under it read as the
/// stub of their channel tag, a label, and whatever shows to the right of the panel
/// ("[1. 편집 모드 [Some Name]: text"), and the labels stay put while the chat scrolls under
/// them. None of that is chat.
///
/// The texts are those of the client's string tables. Labels of one common word ("설정",
/// "Display") prove nothing inside a sentence and count only where they are all a row reads as.
enum ChatMenu {
    struct Label {
        let text: String
        /// Place in the menu, top to bottom; nil for an entry that is only there in some states
        /// of the window and whose place is not known.
        let rank: Int?
        let compact: [Character]
        /// One common word: counts only as a whole row.
        let wholeRowOnly: Bool

        init(_ text: String, _ rank: Int?, wholeRowOnly: Bool = false) {
            self.text = text; self.rank = rank; self.wholeRowOnly = wholeRowOnly
            compact = ChatMenu.compact(text)
        }
    }

    static let koKR: [Label] = [
        Label("편집 모드", 0), Label("상호작용 비활성화", 1), Label("상호작용 활성화", 1),
        Label("창 이름 변경", 2), Label("새 대화창 생성", 3),
        // The same heading in the Classic Era client and in the current one.
        Label("디스플레이 설정", 4), Label("화면 설정", 4),
        Label("글자 크기", 5), Label("배경 설정", 6), Label("필터 설정", 7), Label("설정", 8, wholeRowOnly: true),
        Label("대화창 잠금 해제", nil), Label("대화창 잠금", nil), Label("창 잠금 해제", nil), Label("창 잠금", nil),
        Label("대화창 초기화", nil), Label("대화창 삭제", nil), Label("대화창 닫기", nil),
    ]
    static let enUS: [Label] = [
        Label("Edit Mode", 0), Label("Make Noninteractive", 1), Label("Make Interactive", 1),
        Label("Rename Window", 2), Label("Create New Window", 3),
        Label("Display", 4, wholeRowOnly: true), Label("Font Size", 5), Label("Background", 6, wholeRowOnly: true),
        Label("Filters", 7, wholeRowOnly: true), Label("Settings", 8, wholeRowOnly: true),
        Label("Unlock Window", nil), Label("Lock Window", nil), Label("Reset Chat Windows", nil),
        Label("Remove Window", nil), Label("Close Window", nil),
    ]

    static func labels(for locale: ClientLocale) -> [Label] { locale == .koKR ? koKR : enUS }

    static func compact(_ text: String) -> [Character] {
        Array(text.lowercased().filter { !$0.isWhitespace })
    }

    private static func index(of needle: [Character], in hay: [Character]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle {
            return i
        }
        return nil
    }

    /// Most of a channel tag that can show left of the panel before the label ("[1.", "[길").
    private static let stub = 4

    /// The label a row reads as, or begins with behind at most the stub of a channel tag. The
    /// longest label that fits ("대화창 잠금 해제" before "대화창 잠금").
    static func labelAtStart(of text: String, locale: ClientLocale) -> Label? {
        let row = compact(text)
        var best: Label?
        for label in labels(for: locale) where label.compact.count > (best?.compact.count ?? 0) {
            if label.wholeRowOnly {
                if row == label.compact { best = label }
            } else if let at = index(of: label.compact, in: row), at <= stub {
                best = label
            }
        }
        return best
    }

    /// A label of several words anywhere in `text`: in a row, or in what was read as a channel
    /// tag ("1. 필터 설정습지").
    static func labelInside(_ text: String, locale: ClientLocale) -> Label? {
        let row = compact(text)
        var best: Label?
        for label in labels(for: locale) where !label.wholeRowOnly && label.compact.count > (best?.compact.count ?? 0) {
            if index(of: label.compact, in: row) != nil { best = label }
        }
        return best
    }

    /// A label of the menu found in a row, and what the row says about it.
    struct Sighting {
        let label: Label
        /// Index of the row among the lines it was found in, and its vertical centre.
        let line: Int
        let y: CGFloat
        /// The label is all the row reads as (behind at most the stub of a channel tag).
        let alone: Bool
        /// The row begins with the label itself, with not even the stub of a tag in front of
        /// it: how a wrapped row of chat about these very settings begins as well.
        let leads: Bool
        /// The row cannot be chat: nothing but the label, or a header row that is damaged
        /// (the label stands where its tag or its speaker was). A label inside a sentence, or
        /// behind a sound header, may as well be somebody talking about the menu.
        var strong: Bool
    }

    /// The labels of the menu in the rows of a frame, one per row at most.
    static func sightings(in lines: [OCRLine], locale: ClientLocale) -> [Sighting] {
        var found: [Sighting] = []
        for (n, line) in lines.enumerated() {
            let row = compact(line.text)
            if let label = labelAtStart(of: line.text, locale: locale) {
                let at = label.wholeRowOnly ? 0 : (index(of: label.compact, in: row) ?? 0)
                let alone = at + label.compact.count == row.count
                let damaged = !alone && ChatLineParser.parse(line.text, locale: locale, color: line.color).isDamagedHeader
                found.append(Sighting(label: label, line: n, y: line.box.midY, alone: alone, leads: at == 0, strong: alone || damaged))
            } else if let label = labelInside(line.text, locale: locale) {
                let damaged = ChatLineParser.parse(line.text, locale: locale, color: line.color).isDamagedHeader
                found.append(Sighting(label: label, line: n, y: line.box.midY, alone: false, leads: false, strong: damaged))
            }
        }
        return found
    }

    /// Whether what was found says that the menu is open: two different labels in rows that
    /// cannot be chat, or three labels of which one is in such a row, in the order the menu
    /// lists them. One label proves nothing, and neither does any number of them in rows that
    /// read as chat: people do talk about the settings of the chat window, and name them.
    static func isOpen(_ sightings: [Sighting]) -> Bool {
        let strong = sightings.filter(\.strong)
        guard !strong.isEmpty else { return false }
        return distinctInOrder(strong) >= 2 || distinctInOrder(sightings) >= 3
    }

    /// The same judged from the rows alone, with nothing known about what the window showed
    /// before (`ChatTracker` knows more: which rows are chat it has already seen).
    static func isOpen(over lines: [OCRLine], locale: ClientLocale) -> Bool {
        isOpen(sightings(in: lines, locale: locale))
    }

    /// Number of different labels on different rows, 0 when two of them stand in the wrong order.
    private static func distinctInOrder(_ found: [Sighting]) -> Int {
        var seen: [Sighting] = []
        for item in found.sorted(by: { $0.y < $1.y }) {
            if seen.contains(where: { $0.label.text == item.label.text }) { continue }
            // Two labels read on one row are one row.
            if let last = seen.last, item.y - last.y < 4 { continue }
            seen.append(item)
        }
        let ranks = seen.compactMap(\.label.rank)
        for (a, b) in zip(ranks, ranks.dropFirst()) where b < a { return 0 }
        return seen.count
    }
}
