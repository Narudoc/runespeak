import Foundation
import CoreGraphics

/// Turns successive OCR frames of the game chat window into a stream of new messages.
///
/// The tracker keeps a model of the chat log as a list of screen lines it has seen (`history`),
/// with what it knows about which lines sit directly below which. Every frame is aligned
/// against that list (fuzzy line similarity + sequence alignment):
///  - lines that align are re-reads of known lines and never produce output again, whether the
///    window merely stayed put, scrolled back, faded out and returned, or shows another tab that
///    repeats the same messages;
///  - lines hanging off the end of a known run are new chat and are reported at once, except the
///    bottom-most message, which waits one frame in case OCR missed part of it;
///  - lines that do not fit anywhere (first frame, tab switch, a line OCR skipped when it first
///    appeared) are held until a second frame shows them again, which keeps one-off misreads out.
///
/// Which lines are chat, and which rows belong to one message, is read off where they start:
/// every message starts on one column (learned from header rows) and the game indents wrapped
/// rows by a fixed step. Text that starts elsewhere, or far to the right of a chat row on the
/// same baseline, belongs to the world behind the window (names over characters) or to the
/// window's own buttons (tab labels) and is dropped before it reaches the list.
///
/// Two situations look like a re-read and are not. A long message posted again makes the window
/// resemble an older stretch of the log; the line that history knows to be a different one gives
/// that away (`contradictsHistory`). And after the chat has faded out, a few lines alone on the
/// bottom rows are new chat even when the same words were said before (`isNewChatAfterFade`).
///
/// Text of the game world drawn over a chat row (the name over a character that stands behind
/// the window) makes the row read as something else for as long as it is there. A message with
/// such a row is held back for a clean read, for `maxDoubtFrames` frames at most: its header
/// row reads as damaged, one of its rows reads differently in every frame, or a name stands
/// alone where a row must be. When the wait is over the message goes out as far as it is known
/// and nothing that is in doubt is passed on: the rows without their header row have no
/// speaker, a row that never read the same way twice is "…", and a message of one row is the
/// notice `unreadableNotice`. Once the rows read cleanly the message is reported again, whole,
/// and `corrections` names the earlier reports it stands in for. A message that went out on a
/// read OCR itself was unsure of is replaced the same way by a later read it is sure of.
///
/// Rows that go out without their header row are marked as a fragment
/// (`ChatMessage.isFragment`): the end of something somebody said, shown as read and never
/// translated by itself, until the whole message takes its place.
///
/// While a menu of the game is open over the chat (`ChatMenu`), its labels stand where the
/// channel tags are and stay put while the chat scrolls under them. Such frames are not looked
/// at: nothing is learned from them, and the first frame after the menu has closed is fitted to
/// what was known before. A row under a single label, a numbered channel tag that never closes
/// and a tag with a label in it are no chat either. Rows of chat that name those labels are
/// (people explain the settings to each other): a row that went out and is still there, a
/// wrapped row that begins with a label's words, a label behind a sound header.
///
/// A name that stands right behind the end of a row, or where its last words are, can be read
/// together with the row without OCR doubting any of it; nothing tells the two apart then,
/// and the message goes out with the name. Names move on and chat stays: when the row has
/// read without the name twice running, within `shedFrames` of going out, its message is
/// reported again without it (`hadWorldText`). Never the other way round. A header row that
/// stands on the row of a known line under the same tag and speaker, with other words behind
/// the colon, is that line read differently and no new message.
public final class ChatTracker: ChatTracking, @unchecked Sendable {

    // MARK: - Types

    private struct FrameLine {
        var text: String
        var parsed: ParsedChatLine
        var key: LineKey
        var color: RGBColor
        var box: CGRect
        var confidence: Double
        /// Glyphs of the game world were read into the front of this row: where it starts on
        /// screen says nothing about whether it is a wrapped row.
        var looseStart = false
        /// Nothing of the row was read: a name of the game world stands where it is. `text`
        /// is that name and is never passed on.
        var covered = false
    }

    private final class Entry {
        var text: String
        var parsed: ParsedChatLine
        var key: LineKey
        var color: RGBColor
        var box: CGRect
        var confidence: Double
        /// First screen line of a message.
        var isStart: Bool
        /// True when this line was never seen directly below its predecessor in `history`.
        var gapBefore: Bool
        /// `gapBefore` of the following entry before this one was inserted in front of it.
        var savedNextGap: Bool?
        let firstSeen: Date
        let bornFrame: Int
        var sightings = 1
        var lastSeenFrame: Int
        /// Vertical movement between the last two sightings when they were in consecutive frames.
        var lastShift: CGFloat?
        /// Not yet believed: seen once, somewhere new lines are not expected.
        var tentative: Bool
        let wasTentative: Bool
        /// Reported, or deliberately swallowed (late continuation, duplicate, orphan).
        var done = false
        /// Its text went out as part of a message.
        var reported = false
        /// Reported as something unreadable, then read as a sound header row: reported once
        /// more unless that message is out already.
        var revived = false
        /// Appeared at the bottom of a window that had faded to empty: new chat even when it
        /// reads like something said before.
        var afterFade = false
        /// How many frames read the line as `text`, and the best-supported other reading.
        var votes = 1
        var rival: (line: FrameLine, votes: Int)?
        /// Among the reads that agree with `text` but for a few glyphs: how many were `text`
        /// to the letter, and the other spelling with how often it was seen.
        var exact = 1
        var spelling: (line: FrameLine, count: Int)?
        /// Two unrelated reads of the row, seen equally often: which one is the line is open.
        var contested: Bool { rival.map { $0.votes >= votes } ?? false }
        /// Last frame in which the row read as something unrelated to both `text` and the
        /// rival reading: a third reading means something is moving over the row.
        var churnFrame = 0
        /// Sightings in a row that read as `text`.
        var streak = 1
        /// Frame in which a sounder read of the row replaced a damaged one.
        var adoptedFrame = 0
        /// Arrived below known chat as a headerless row with no message to belong to: the
        /// header row of its message may be hidden by text of the game world.
        var orphan = false
        /// Known only as a row with a name of the game world over it (`FrameLine.covered`).
        var covered = false
        /// Taken for a wrapped row only because the row above it was not read when it
        /// arrived: decided again once that row is known.
        var undecidedStart = false
        /// Id of the message this line last went out in, and that message as it was compared.
        var messageID: UUID?
        var emittedKey: LineKey?
        /// That message went out while part of it could not be read (see `ChatTracker.corrections`).
        var provisional = false
        /// ... for no other reason than that OCR was unsure of one of its rows.
        var unsure = false
        /// How sure OCR was of this line when its text went out.
        var reportedConfidence: Double?
        /// The line itself was left out of that message: no read of it could be trusted.
        var withheld = false
        /// The row as it went out, and the frame it went out in.
        var reportedText: String?
        var reportedKey: LineKey?
        var reportedFrame = 0
        /// Captures in a row in which the row read, for sure, as what went out without a name
        /// of the game world behind it (`hadWorldText`); at two the read is taken (`shed`) and
        /// its message is said again.
        var shedSightings = 0
        var shed = false

        init(_ l: FrameLine, isStart: Bool, gapBefore: Bool, tentative: Bool, frame: Int, now: Date) {
            text = l.text; parsed = l.parsed; key = l.key; color = l.color; box = l.box; confidence = l.confidence
            self.isStart = isStart; self.gapBefore = gapBefore; self.tentative = tentative
            wasTentative = tentative
            firstSeen = now; bornFrame = frame; lastSeenFrame = frame
        }
    }

    private enum Step {
        case match(Int, strict: Bool)
        /// Not in history; belongs in front of history index `boundary`.
        case new(boundary: Int)
    }

    // MARK: - State

    private let locale: ClientLocale
    private let lock = NSLock()
    private var history: [Entry] = []
    /// Keys of recently reported messages, oldest first.
    private var recent: [LineKey] = []
    private var frameNo = 0
    /// Number of the last frame that showed any text.
    private var lastViewFrame = 0
    private var rightLimit: CGFloat = 0
    private var leftEdge: CGFloat = .greatestFiniteMagnitude
    /// Left edges of recently seen header rows ("[Channel] [Name]: ..."), and their median: the
    /// column on which every message starts. `.greatestFiniteMagnitude` while unknown.
    private var headerSamples: [CGFloat] = []
    private var headerEdge: CGFloat = .greatestFiniteMagnitude
    /// How far headerless rows right below a header row were seen to start to its right, and
    /// what that says about the window: `indent` is the step by which wrapped rows are indented
    /// (the game's default, about 0.4 line heights), 0 while unknown; `flat` means the window
    /// is known not to indent them.
    private var indentSamples: [CGFloat] = []
    private var indent: CGFloat = 0
    private var flat = false
    /// Hash of the lines the columns were last learned from.
    private var lastColumnSignature = 0
    private var lineHeight: CGFloat = 0
    /// Vertical distance between two consecutive text rows; 0 when unknown.
    private var rowPitch: CGFloat = 0
    /// Vertical centre of the lowest text row the window has shown, and of the lowest line in
    /// the current frame. Chat is bottom-aligned, so text that stops above the lowest row means
    /// OCR missed what is below it.
    private var bottomRow: CGFloat = 0
    private var frameBottom: CGFloat = 0
    /// Scroll distance since the previous frame as agreed by the recognised lines; nil when unknown.
    private var geoShift: CGFloat?
    /// How far the known lines moved vertically since the previous frame; nil when unknown.
    private var frameShift: CGFloat?

    private static let maxHistory = 420
    private static let keepHistory = 300
    private static let maxRecent = 400
    private static let maxHoldFrames = 4
    private static let maxDistrustFrames = 6
    /// Frames a message whose header row reads as damaged (`ParsedChatLine.headerBroken`) is
    /// held back for a clean re-read: text of the world drifting over a chat row moves on,
    /// the row stays. At the default capture interval of 0.7 s this is 3.5 s.
    static let maxDoubtFrames = 5
    /// Frames after such a third reading during which the row is not taken at its word.
    private static let churnFrames = 2
    /// Frames after a message went out during which a row of it that reads without the name
    /// it went out with is said again (`hadWorldText`). A name that was behind a row when its
    /// message arrived moves on within seconds; much later, last words that are gone were
    /// more likely hidden by something than never there.
    static let shedFrames = 20
    /// Body of the line reported for a one-row message whose text could not be read in time:
    /// it says that something was said, and nothing about what.
    public static let unreadableNotice = "(다른 글자에 가려 읽지 못한 줄)"
    private static let noticeColour = RGBColor(r: 0.62, g: 0.62, b: 0.62)
    /// Empty frames in a row that count as "the chat has faded out", not as OCR missing a frame.
    private static let fadedAfterEmptyFrames = 3
    /// The game shows a line for two minutes by default. A line first seen longer ago than this
    /// is no longer on screen by itself; only scrolling or the mouse brings it back.
    private static let lineLifetime: TimeInterval = 150
    /// A read OCR is sure enough of to be taken at its word.
    private static let confidentRead = 0.45
    /// A read OCR has no doubt about. (The Korean model answers 1.0 for text it reads well
    /// and 0.5 or 0.3 for text it has to guess at, which includes two texts drawn over each
    /// other.)
    private static let sureRead = 0.9
    /// Most rows a frame has shown in the current layout.
    private var fullRows = 0

    private var senders = SenderMemory()
    /// Numbered channel tags seen in sound header rows ("1. General - Some Zone"), as skeletons.
    private var soundLabels: Set<[UInt32]> = []
    private var latestCorrections: [UUID: [UUID]] = [:]
    private var unreadableRows: UInt32 = 0

    public init(clientLocale: ClientLocale) {
        self.locale = clientLocale
    }

    /// A message whose header row or one of whose rows could not be read within the wait goes
    /// out as far as it is known: without its speaker, with "…" for the row, or as a notice
    /// that a line could not be read. When the rows read cleanly later (what was drawn over
    /// them has moved on, or the chat has scrolled them clear of it), the message is reported
    /// once more, whole. For the messages returned by the latest `ingest` that are such second
    /// reports: the ids of the earlier messages each one stands in for.
    public var corrections: [UUID: [UUID]] {
        lock.lock(); defer { lock.unlock() }
        return latestCorrections
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        senders.reset()
        soundLabels.removeAll()
        history.removeAll()
        recent.removeAll()
        frameNo = 0
        lastViewFrame = 0
        rightLimit = 0
        leftEdge = .greatestFiniteMagnitude
        forgetColumns()
        lineHeight = 0
        rowPitch = 0
        bottomRow = 0
        frameBottom = 0
        frameShift = nil
        fullRows = 0
        latestCorrections = [:]
    }

    // MARK: - Ingest

    public func ingest(_ frame: OCRFrame, now: Date) -> [ChatMessage] {
        lock.lock(); defer { lock.unlock() }
        latestCorrections = [:]
        // A menu of the game is open over the chat: its labels stand where the channel tags
        // are and stay put while the chat scrolls under them, so no row of this frame can be
        // taken at its word. The frame does not count at all: nothing is learned from it and
        // nothing waits through it, and the first frame after the menu has closed is fitted
        // to what was known before it opened.
        if menuIsOpen(over: frame) { return [] }
        let lines = prepare(frame)
        frameNo += 1
        var anchored = false
        frameShift = nil
        var afterFade = false
        if !lines.isEmpty {
            func confident(_ steps: [Step]) -> Bool {
                steps.contains { if case .match(_, strict: true) = $0 { return true } else { return false } }
            }
            dropFadeInGuess(lines)
            afterFade = isNewChatAfterFade(lines, now: now)
            // Nearly every frame shows the previous view, scrolled by a few lines at most. Looking
            // there first keeps old chat that resembles the new lines (people repeating themselves,
            // a countdown before every pull) from being mistaken for the current position.
            // The other likely place is the newest chat, where the view lands after scrolling back.
            var steps: [Step] = []
            var bestScore = -Double.infinity
            var windows: [Range<Int>] = []
            if let near = neighbourhood(of: lines.count) { windows.append(near) }
            let tail = max(0, history.count - 2 * lines.count - 4)..<history.count
            if !tail.isEmpty, windows.first.map({ $0.upperBound < history.count }) ?? true { windows.append(tail) }
            // The lines of a window that had faded out are new chat whatever they resemble.
            if afterFade { windows = [] }
            for window in windows {
                let candidate = align(lines, window: window)
                if confident(candidate.steps), candidate.score > bestScore {
                    steps = candidate.steps; bestScore = candidate.score; anchored = true
                }
            }
            if !anchored, !afterFade {
                steps = align(lines, window: 0..<history.count).steps
                anchored = confident(steps)
            }
            if !anchored, !afterFade, let same = loneRowReadAgain(lines) {
                steps = [same]
                anchored = true
            }
            // A repost of a long message makes the window look like an older stretch of the log
            // (same advert, one other line, same advert). The one line that differs gives it away:
            // history knows which line sits there, and it is not this one. New chat only ever
            // appears below the newest line, so the frame is fitted there instead.
            if anchored, contradictsHistory(lines, steps) {
                let pinned = align(lines, window: tail, pinnedToEnd: true).steps
                if isPlainContinuation(pinned), confident(pinned), !contradictsHistory(lines, pinned) {
                    steps = pinned
                }
            }
            updateGeometry(lines, imageSize: frame.imageSize, sameLayout: anchored || afterFade)
            geoShift = nil
            if anchored {
                matchByPosition(lines, steps: &steps)
                matchByRow(lines, steps: &steps)
            }
            apply(lines, steps: steps, anchored: anchored, afterFade: afterFade, now: now)
            lastViewFrame = frameNo
        }
        let out = settle(anchored: anchored)
        prune()
        return out
    }

    /// The only line on screen, on the row of the only line the previous frame showed, when
    /// one of the two reads is a damaged header row, or the two are one speaker's header with
    /// different words behind it: the same row, read again. (A new message would have pushed
    /// the old line up a row, and both would show.) With nothing else on screen there is no
    /// second line to tell how far the window moved.
    private func loneRowReadAgain(_ lines: [FrameLine]) -> Step? {
        guard lines.count == 1, lineHeight > 0, let line = lines.first else { return nil }
        let shown = history.indices.filter { history[$0].lastSeenFrame == frameNo - 1 }
        guard shown.count == 1, let j = shown.first else { return nil }
        let e = history[j]
        guard abs(e.box.midY - line.box.midY) < 0.35 * lineHeight,
              line.parsed.headerBroken || (e.parsed.headerBroken && (!e.done || e.provisional))
                || isSameRowReadDifferently(line, e) else { return nil }
        return .match(j, strict: false)
    }

    // MARK: - Something drawn over the chat

    /// Rows the last view showed that went out as chat.
    private func rowsOfLastView() -> [Entry] {
        guard lastViewFrame > 0 else { return [] }
        return history.filter { $0.lastSeenFrame == lastViewFrame && $0.reported && !$0.withheld && !$0.tentative && !$0.covered }
    }

    /// How far the rows of the last view have moved since, read off the rows that still read
    /// as one of them did: the distance most of those agree on. nil when no row is recognised.
    private func shiftSinceLastView(_ rows: [(key: LineKey, y: CGFloat)], known: [Entry]) -> CGFloat? {
        guard lineHeight > 0 else { return nil }
        var moves: [CGFloat] = []
        for row in rows {
            for e in known where LineSimilarity.compare(row.key, e.key).isStrict { moves.append(row.y - e.box.midY) }
        }
        var best: (count: Int, move: CGFloat)?
        for move in moves {
            let agreeing = moves.filter { abs($0 - move) < 0.35 * lineHeight }.count
            if best == nil || agreeing > best!.count || (agreeing == best!.count && abs(move) < abs(best!.move)) {
                best = (agreeing, move)
            }
        }
        return best?.move
    }

    /// Whether the game's chat menu is open over the rows of `frame` (`ChatMenu`), judged with
    /// what is known about the window. A row that went out as chat and is still there is chat,
    /// whatever it names; a wrapped row that begins with the words of a label is one of the
    /// message above it; and a row that was chat a moment ago and has a label in it now has the
    /// label drawn over it.
    private func menuIsOpen(over frame: OCRFrame) -> Bool {
        var found = ChatMenu.sightings(in: frame.lines, locale: locale)
        guard !found.isEmpty else { return false }
        let known = rowsOfLastView()
        let keys = frame.lines.map { LineKey(text: $0.text, parsed: ChatLineParser.parse($0.text, locale: locale, color: $0.color)) }
        let shift = shiftSinceLastView(zip(keys, frame.lines).map { (key: $0, y: $1.box.midY) }, known: known) ?? 0
        found = found.compactMap { sighting in
            var sighting = sighting
            let key = keys[sighting.line]
            if known.contains(where: { !$0.provisional && LineSimilarity.compare(key, $0.key).isStrict }) { return nil }
            if sighting.leads, isWrappedChat(frame.lines[sighting.line], among: frame.lines) {
                sighting.strong = false
            } else if !sighting.strong, lineHeight > 0,
                      let was = known.first(where: { abs($0.box.midY + shift - sighting.y) < 0.35 * lineHeight }),
                      !LineSimilarity.compare(key, was.key).isStrict {
                sighting.strong = true
            }
            return sighting
        }
        return ChatMenu.isOpen(found)
    }

    /// Whether a row that begins with the words of a menu label is a wrapped row of chat: it
    /// stands where wrapped rows start, right below a row of chat in its own colour. (A label
    /// of the menu is white or gold and stands where the menu puts it.)
    private func isWrappedChat(_ line: OCRLine, among lines: [OCRLine]) -> Bool {
        let height = line.box.height
        guard height > 0, line.box.width > 0 else { return false }
        let rowAbove = lines.filter { $0.box.width > 0 && line.box.midY - $0.box.midY > 0.5 * height && line.box.midY - $0.box.midY < 1.6 * height }
        guard let above = rowAbove.min(by: { $0.box.minX < $1.box.minX }), !ChatTracker.coloursDiffer(above.color, line.color) else { return false }
        let parsed = ChatLineParser.parse(above.text, locale: locale, color: above.color)
        guard !parsed.isDamagedHeader else { return false }
        let right = line.box.minX - above.box.minX
        if parsed.hasPrefix {
            // Below a header row: the wrap indent to its right, where that is known.
            if headerEdge < .greatestFiniteMagnitude, indent > 0, abs(above.box.minX - headerEdge) < 0.3 * height {
                return abs(right - indent) < 0.4 * height
            }
            return right > -0.3 * height && right < 1.2 * height
        }
        // Below another wrapped row: on its column.
        return ChatMenu.labelAtStart(of: above.text, locale: locale) == nil && abs(right) < 0.4 * height
    }

    // MARK: - Fade

    /// True for the first frame after the chat had faded out when it shows only a few lines on
    /// the bottom rows and nothing in it can be an old line still on screen. Scrolling back or
    /// moving the mouse over the chat brings a whole window back; a new message shows alone.
    private func isNewChatAfterFade(_ lines: [FrameLine], now: Date) -> Bool {
        guard lastViewFrame > 0, frameNo - lastViewFrame > ChatTracker.fadedAfterEmptyFrames,
              fullRows > 0, lines.count < fullRows || fullRows == 1, bottomRow > 0 else { return false }
        let bottom = lines.map(\.box.midY).max() ?? 0
        let slack = 0.6 * (rowPitch > 0 ? rowPitch : lineHeight)
        guard abs(bottom - bottomRow) < max(slack, 1) else { return false }
        let young = history.filter { !$0.tentative && now.timeIntervalSince($0.firstSeen) < ChatTracker.lineLifetime }
        return !lines.contains { line in young.contains { LineSimilarity.compare(line.key, $0.key) != .none } }
    }

    /// The frame after such a guess shows a full window again: the "new" lines were a glimpse of
    /// the old ones fading back in.
    private func dropFadeInGuess(_ lines: [FrameLine]) {
        guard fullRows > 1, lines.count >= fullRows else { return }
        history.removeAll { $0.afterFade && $0.tentative }
    }

    // MARK: - Frame preparation

    /// Gap, in line heights, beyond which two boxes on one text row are not one chat line. Words
    /// of a chat line sit a space apart, and an inline icon is one line height wide.
    private static let wideGap: CGFloat = 2

    private static let columnSamples = 31

    private func forgetColumns() {
        headerSamples = []
        headerEdge = .greatestFiniteMagnitude
        indentSamples = []
        indent = 0
        flat = false
    }

    private func prepare(_ frame: OCRFrame) -> [FrameLine] {
        let sorted = frame.lines.enumerated()
            .filter { !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            // One label of the game's chat menu (the rest of the menu lies outside the captured
            // region): the row under it cannot be read, and the label is no chat. A wrapped row
            // of chat that begins with the same words is.
            .filter { item in
                guard ChatMenu.labelAtStart(of: item.element.text, locale: locale) != nil else { return true }
                let leads = ChatMenu.sightings(in: [item.element], locale: locale).first?.leads ?? false
                return leads && isWrappedChat(item.element, among: frame.lines)
            }
            .sorted { a, b in
                let ya = a.element.box.midY, yb = b.element.box.midY
                return ya != yb ? ya < yb : a.offset < b.offset
            }
            .map(\.element)
        // Boxes sharing a text row.
        var rows: [[OCRLine]] = []
        for line in sorted {
            if let last = rows.last, last.allSatisfy({ ChatTracker.sameRow($0.box, line.box) }) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        // Boxes a normal gap apart are one screen line that OCR split. Across a wide gap they are
        // different things: chat on the left and, say, the name floating over a character that
        // stands behind the chat window on the right.
        var pieces: [[FrameLine]] = rows.map { row in
            var merged: [OCRLine] = []
            for b in row.sorted(by: { $0.box.minX < $1.box.minX }) {
                guard let a = merged.last,
                      b.box.minX - a.box.maxX <= ChatTracker.wideGap * max(a.box.height, b.box.height) else {
                    merged.append(b)
                    continue
                }
                var joined = a
                joined.text = a.text.trimmingCharacters(in: .whitespaces) + " " + b.text.trimmingCharacters(in: .whitespaces)
                joined.box = a.box.union(b.box)
                joined.color = a.box.width >= b.box.width ? a.color : b.color
                joined.confidence = min(a.confidence, b.confidence)
                merged[merged.count - 1] = joined
            }
            return merged.compactMap { piece in
                let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                var parsed = ChatLineParser.parse(text, locale: locale, color: piece.color)
                // A speaker of several words that do not read like a name, in a read OCR
                // itself distrusts: a name with something drawn over it, not somebody's name.
                if parsed.hasPrefix, piece.confidence < 0.4, let sender = parsed.sender, sender.contains(" "),
                   !ChatTracker.isPlainName(sender) {
                    parsed.headerBroken = true
                }
                let key = LineKey(text: text, parsed: parsed)
                guard key.count > 0 else { return nil }
                if parsed.hasPrefix, !parsed.headerBroken, parsed.channel == .publicChannel, parsed.sender != nil,
                   piece.confidence >= ChatTracker.sureRead, soundLabels.count < 64 {
                    soundLabels.insert(key.tag)
                }
                return FrameLine(text: text, parsed: parsed, key: key, color: piece.color, box: piece.box,
                                 confidence: piece.confidence)
            }
        }
        pieces.removeAll { $0.isEmpty }

        // A top row of several short labels far apart is a row of buttons (the chat tabs, which
        // fade in when the mouse comes near), not chat.
        if let top = pieces.first, top.count >= 2,
           top.allSatisfy({ !$0.parsed.hasPrefix && $0.box.width < 4 * $0.box.height }) {
            pieces.removeFirst()
        }

        // The tab labels are also set in smaller type than the chat below them, which tells
        // them from chat when OCR joined them into one piece ("General Combat Trade").
        if pieces.count >= 3, let top = pieces.first, top.allSatisfy({ !$0.parsed.hasPrefix && $0.parsed.timestamp == nil }) {
            let below = pieces.dropFirst().flatMap { $0 }.map(\.box.height).filter { $0 > 0 }.sorted()
            let tallest = top.map(\.box.height).max() ?? 0
            if !below.isEmpty, tallest > 0, tallest < 0.7 * below[below.count / 2],
               top.reduce(0, { $0 + TextFold.columns($1.text) }) <= 40 {
                pieces.removeFirst()
            }
        }

        // Names floating over characters behind the window ("Some Player", "<Some Guild>").
        // One that is all its row reads as may stand where a row of chat is: it is kept as a
        // hidden row until the rows around it tell (below).
        // (Not what stands right below a row that ends inside a link, where its wrapped rows
        // start: the rest of that link in the link's own colour, with its closing bracket read
        // as a letter or not at all, "the Silver Moonl".)
        let openLinks: [FrameLine?] = pieces.map { row in row.first { ChatLinks.leavesLinkOpen($0.text) } }
        pieces = pieces.enumerated().map { n, row in
            let above = n > 0 ? openLinks[n - 1] : nil
            let chat = row.compactMap { piece -> FrameLine? in
                guard isWorldLabel(piece) else { return piece }
                if let above, isRestOfLink(piece, below: above) { return piece }
                return linkWithMisreadBrackets(piece)
            }
            guard chat.isEmpty, var hidden = row.first else { return chat }
            unreadableRows &+= 1
            hidden.covered = true
            hidden.parsed.headerBroken = true
            hidden.key = LineKey(unreadable: unreadableRows)
            return [hidden]
        }
        pieces.removeAll { $0.isEmpty }

        // Where chat can be: every message starts on one column and wrapped rows start a fixed
        // step to its right. Text that starts elsewhere belongs to the world behind the window.
        var all = pieces.flatMap { $0 }.filter { !$0.covered }
        let heights = all.map(\.box.height).filter { $0 > 0 }.sorted()
        let height = heights.isEmpty ? lineHeight : heights[heights.count / 2]
        // A box much taller than a text row took in glyphs that are not on the row: part of a
        // name drawn over its start. The stray glyph is dropped and the row is no longer
        // judged by where its box begins.
        if height > 0, heights.count >= 3 {
            pieces = pieces.map { row in row.map { $0.covered ? $0 : tallRowWithoutStrayGlyph($0, rowHeight: height) ?? $0 } }
            all = pieces.flatMap { $0 }.filter { !$0.covered }
        }
        // A header row whose box is much taller than a text row took in something beside the
        // window (a button of the chat frame): its box does not start where its text starts.
        var heads = all.filter { isColumnHeader($0) && $0.box.width > 0 && $0.box.height <= 1.3 * height }
            .map(\.box.minX).sorted()
        if heads.isEmpty { heads = all.filter { isColumnHeader($0) && $0.box.width > 0 }.map(\.box.minX).sorted() }
        var edge: CGFloat?
        var slack = height
        if heads.count >= 2 { edge = heads[heads.count / 2] }
        else if headerEdge < .greatestFiniteMagnitude { edge = headerEdge }
        else if let only = heads.first { edge = only }
        else {
            // No header row seen yet (the window shows only notices, or the tail of a message).
            // Chat hugs the left side of the captured region: whatever starts in its right half,
            // or far to the right of the leftmost text, is not a row of chat.
            let half = frame.imageSize.width * 0.5
            let lefts = all.filter { $0.box.width > 0 && (half <= 0 || $0.box.minX < half) }.map(\.box.minX)
            edge = lefts.min() ?? 0
            slack = .greatestFiniteMagnitude
        }
        func inColumns(_ l: FrameLine) -> Bool {
            guard let edge, height > 0, l.box.width > 0 else { return true }
            // Room for the wrap indent and for a row whose first glyph is an icon OCR skipped.
            return l.box.minX >= edge - slack && l.box.minX <= edge + 2 * height
        }
        let kept: [FrameLine] = pieces.compactMap { row in
            if let hidden = row.first, hidden.covered { return hidden }
            let candidates = row.filter(inColumns)
            if let header = candidates.first(where: { $0.parsed.hasPrefix }) { return header }
            if let first = candidates.first { return first }
            // A header is its own evidence, wherever it stands.
            if let header = row.first(where: { $0.parsed.hasPrefix }) { return header }
            // A row that starts left of the chat because a button beside the window was read
            // as its first glyph (") Some Name dances.").
            guard let edge, slack < .greatestFiniteMagnitude, height > 0 else { return nil }
            return row.lazy.compactMap { self.withoutGlyphBesideTheWindow($0, edge: edge, rowHeight: height) }.first
        }
        // Chat has no empty rows: a name of the world exactly one row below one row of chat
        // and one row above another stands on a row of chat. Anywhere else it stands on
        // nothing, and is dropped. So is one that starts on the message column or on the
        // column of wrapped rows: that may as well be a short notice of the game itself, or
        // a link whose brackets were not read, with nothing under it.
        return kept.enumerated().compactMap { i, line in
            guard line.covered else { return line }
            guard rowPitch > 0, lineHeight > 0, i > 0, i + 1 < kept.count, !kept[i - 1].covered, !kept[i + 1].covered,
                  let edge, slack < .greatestFiniteMagnitude else { return nil }
            // (While the wrap indent is not known, the game's usual one, under half a row.)
            let offset = line.box.minX - edge
            if offset >= -0.3 * lineHeight, offset <= max(indent, 0.5 * lineHeight) + 0.3 * lineHeight { return nil }
            let up = line.box.midY - kept[i - 1].box.midY, down = kept[i + 1].box.midY - line.box.midY
            return abs(up - rowPitch) < 0.4 * lineHeight && abs(down - rowPitch) < 0.4 * lineHeight ? line : nil
        }
    }

    /// `line` without its first one or two glyphs when its box starts well left of the message
    /// column `edge` and, going by the width of its glyphs, the text behind them starts on
    /// the chat columns; nil otherwise. Where the row starts is then only roughly known.
    private func withoutGlyphBesideTheWindow(_ line: FrameLine, edge: CGFloat, rowHeight: CGFloat) -> FrameLine? {
        guard line.parsed.timestamp == nil, line.box.width > 0, line.box.minX < edge - rowHeight,
              let space = line.text.firstIndex(of: " "), line.text.distance(from: line.text.startIndex, to: space) <= 2 else { return nil }
        let text = line.text[space...].trimmingCharacters(in: .whitespaces)
        guard text.count >= 4 else { return nil }
        let columns = CGFloat(max(1, TextFold.columns(line.text)))
        let skipped = CGFloat(TextFold.columns(line.text[..<space]) + 1)
        let start = line.box.minX + line.box.width * skipped / columns
        guard start >= edge - rowHeight, start <= edge + 2 * rowHeight else { return nil }
        let parsed = ChatLineParser.parse(text, locale: locale, color: line.color)
        let key = LineKey(text: text, parsed: parsed)
        guard key.count > 0 else { return nil }
        var out = FrameLine(text: text, parsed: parsed, key: key, color: line.color,
                            box: CGRect(x: start, y: line.box.minY, width: line.box.maxX - start, height: line.box.height),
                            confidence: line.confidence)
        out.looseStart = !parsed.hasPrefix
        return out
    }

    /// A row that reads like a name plate and not like chat: a few words of letters, possibly
    /// with a "<Guild>" tag, with no chat header, in a colour no player channel uses. The name
    /// colours of the world (blue and green) are those of system text, and system text of a
    /// Korean client is a Korean sentence, so there a row without Hangul is enough; on an
    /// English client every word must be capitalised like a name.
    private func isWorldLabel(_ l: FrameLine) -> Bool {
        guard !l.parsed.hasPrefix, l.parsed.timestamp == nil else { return false }
        guard ChatColors.channel(for: l.color) == .system else { return false }
        var words: [Substring] = []
        var guilds = 0
        var rest = Substring(l.text)
        // "<Guild Name>" groups, also with one angle bracket lost to OCR at either end of the row.
        while let open = rest.firstIndex(of: "<") {
            words += rest[..<open].split(separator: " ")
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: ">") else {
                guard after.contains(where: \.isLetter) else { return false }
                guilds += 1
                rest = ""
                break
            }
            guard after[..<close].contains(where: \.isLetter) else { return false }
            guilds += 1
            rest = after[after.index(after: close)...]
        }
        if rest.last == ">", rest.dropLast().contains(where: \.isLetter), !rest.dropLast().contains(">") {
            // "...Patrol>": the tail of a guild tag whose start is hidden.
            guilds += 1
            rest = ""
        }
        words += rest.split(separator: " ")
        guard words.count <= 4, guilds <= 1, guilds == 1 || !words.isEmpty else { return false }
        var letters = 0
        for w in words {
            for c in w {
                if c.isLetter {
                    if c.unicodeScalars.contains(where: { TextFold.isWide($0.value) }) { return false }
                    letters += 1
                } else if c != "'" && c != "-" && c != "’" { return false }
            }
            if locale == .enUS, w.first?.isUppercase != true { return false }
        }
        if guilds == 0 {
            // A lone short word proves nothing.
            guard letters >= 4 else { return false }
            if locale == .enUS, words.count < 2 { return false }
        }
        return true
    }

    /// Whether `line` stands where the wrapped rows of `above` start, on the row below it.
    private func isRestOfLink(_ line: FrameLine, below above: FrameLine) -> Bool {
        let height = max(line.box.height, above.box.height)
        guard height > 0, line.box.width > 0, above.box.width > 0 else { return false }
        let down = line.box.midY - above.box.midY
        let right = line.box.minX - above.box.minX
        return down > 0.5 * height && down < 1.6 * height && right > -0.3 * height && right < 1.5 * height
    }

    /// A row in the green of an item link that is nothing but a link ("[Some Item]") reads
    /// like a name of the world when its brackets are taken for thin letters ("ISome Iteml").
    /// No name comes out with such a letter at both ends: the row is given its brackets back.
    private func linkWithMisreadBrackets(_ line: FrameLine) -> FrameLine? {
        let chars = Array(line.text)
        guard chars.count >= 5, "Il1|".contains(chars[0]), chars[1].isUppercase,
              "lI1|j".contains(chars[chars.count - 1]), chars[chars.count - 2].isLowercase else { return nil }
        let text = "[" + String(chars[1..<(chars.count - 1)]) + "]"
        let parsed = ChatLineParser.parse(text, locale: locale, color: line.color)
        guard !parsed.hasPrefix else { return nil }
        return FrameLine(text: text, parsed: parsed, key: LineKey(text: text, parsed: parsed), color: line.color,
                         box: line.box, confidence: line.confidence)
    }

    /// `line` without its first one or two glyphs when its box is much taller than a text row
    /// and those glyphs stand apart as a token of their own; nil when it is an ordinary row.
    private func tallRowWithoutStrayGlyph(_ line: FrameLine, rowHeight: CGFloat) -> FrameLine? {
        guard !line.parsed.hasPrefix, line.parsed.timestamp == nil, line.box.height > 1.3 * rowHeight,
              let space = line.text.firstIndex(of: " "), line.text.distance(from: line.text.startIndex, to: space) <= 2 else { return nil }
        let text = line.text[space...].trimmingCharacters(in: .whitespaces)
        guard text.count >= 4 else { return nil }
        let parsed = ChatLineParser.parse(text, locale: locale, color: line.color)
        let key = LineKey(text: text, parsed: parsed)
        guard key.count > 0 else { return nil }
        var out = FrameLine(text: text, parsed: parsed, key: key, color: line.color, box: line.box,
                            confidence: line.confidence)
        out.looseStart = !parsed.hasPrefix
        return out
    }

    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let h = min(a.height, b.height)
        guard h > 0 else { return false }
        guard abs(a.midY - b.midY) < 0.45 * h else { return false }
        let slack = 0.25 * h
        return b.minX >= a.maxX - slack || a.minX >= b.maxX - slack
    }

    private func updateGeometry(_ lines: [FrameLine], imageSize: CGSize, sameLayout: Bool) {
        if !sameLayout {
            // Nothing recognisable on screen: the window may have been resized or re-wrapped,
            // so what was known about its text area no longer holds.
            rightLimit = 0
            leftEdge = .greatestFiniteMagnitude
            forgetColumns()
            rowPitch = 0
            bottomRow = 0
            fullRows = 0
        }
        fullRows = max(fullRows, lines.count)
        frameBottom = lines.map(\.box.midY).max() ?? 0
        bottomRow = max(bottomRow, frameBottom)
        let heights = lines.filter { !$0.covered }.map(\.box.height).filter { $0 > 0 }.sorted()
        if !heights.isEmpty { lineHeight = heights[heights.count / 2] }
        if lineHeight > 0 {
            // Typical distance between neighbouring rows. Box centres wobble by a few pixels
            // with the glyphs in the line, hence a median over the frame, smoothed over frames.
            let steps = zip(lines, lines.dropFirst()).map { $1.box.midY - $0.box.midY }
                .filter { $0 >= 0.7 * lineHeight }.sorted()
            // Once known, only steps of about one row refine it: a frame with a missing line
            // in every gap must not pass two rows off as one.
            let single = rowPitch > 0
                ? steps.filter { $0 > 0.75 * rowPitch && $0 < 1.3 * rowPitch }
                : steps.filter { $0 < 1.5 * (steps.first ?? 0) && $0 < 2.2 * lineHeight }
            if !single.isEmpty {
                let median = single[single.count / 2]
                rowPitch = rowPitch == 0 ? median : 0.7 * rowPitch + 0.3 * median
            }
        }
        for l in lines where l.box.width > 0 && !l.covered {
            rightLimit = max(rightLimit, l.box.maxX)
            leftEdge = min(leftEdge, l.box.minX)
        }
        // The same read of an unchanged picture is ingested several times; it is one sample.
        var hasher = Hasher()
        for l in lines {
            hasher.combine(l.text)
            hasher.combine(Int(l.box.minX.rounded()))
            hasher.combine(Int(l.box.minY.rounded()))
        }
        let signature = hasher.finalize()
        if signature != lastColumnSignature || !sameLayout {
            lastColumnSignature = signature
            learnColumns(lines)
        }
        // The dragged region is rarely much wider than the text area; this keeps a window that
        // so far only showed short lines from making every line look "full".
        if imageSize.width > 0 { rightLimit = max(rightLimit, imageSize.width * 0.55) }
    }

    private func learnColumns(_ lines: [FrameLine]) {
        guard lineHeight > 0 else { return }
        func keep(_ samples: inout [CGFloat]) -> CGFloat? {
            if samples.count > ChatTracker.columnSamples { samples.removeFirst(samples.count - ChatTracker.columnSamples) }
            return samples.isEmpty ? nil : samples.sorted()[samples.count / 2]
        }
        // A box much taller than a text row took in something that is not on the row (a button
        // beside the window): where it starts is not where the row starts.
        func tellsTheColumn(_ l: FrameLine) -> Bool {
            isColumnHeader(l) && l.box.width > 0 && l.box.height <= 1.3 * lineHeight
        }
        headerSamples += lines.filter(tellsTheColumn).map(\.box.minX)
        headerEdge = keep(&headerSamples) ?? .greatestFiniteMagnitude
        // A headerless row right below a header row and a little to its right is a wrapped row.
        // A notice in a system or emote colour is a line of its own and says nothing about how
        // the window wraps. Only a header row that stands on the message column counts: the
        // step is measured from where it starts.
        for (a, b) in zip(lines, lines.dropFirst()) where tellsTheColumn(a) && !b.parsed.hasPrefix
            && abs(a.box.minX - headerEdge) <= 0.3 * lineHeight
            && !b.covered && b.parsed.timestamp == nil && b.box.width > 0
            && b.parsed.channel != .system && b.parsed.channel != .emote
            && canBeWrapped(b, from: a) {
            let step = b.box.midY - a.box.midY
            let offset = b.box.minX - a.box.minX
            if step > 0, step < 1.6 * lineHeight, abs(offset) < 1.5 * lineHeight { indentSamples.append(offset) }
        }
        // Most such rows are wrapped rows; the odd system line under a chat line is not, hence
        // the median (the lower one of an even number: a header box that reaches a few pixels
        // left of its text makes a sample too large, never too small).
        _ = keep(&indentSamples)
        let median = indentSamples.isEmpty ? 0 : indentSamples.sorted()[(indentSamples.count - 1) / 2]
        indent = indentSamples.count >= 2 && median > 0.25 * lineHeight ? median : 0
        flat = indentSamples.count >= 4 && median < 0.15 * lineHeight
    }

    /// Whether the headerless row `b` right below the header row `a` may be a wrapped row of
    /// it, for learning how the window indents: a row in another colour, one that opens with a
    /// link or a quoted name, and what is left of a damaged header row are as likely lines of
    /// their own on the message column (a notice that begins with a link, the speech of a
    /// creature whose header was not recognised), and a few of those would "unlearn" the indent.
    private func canBeWrapped(_ b: FrameLine, from a: FrameLine) -> Bool {
        guard !b.parsed.headerBroken, let first = b.text.first else { return false }
        if first == "[" || first == "\"" || first == "“" || first == "'" || first == "‘" { return false }
        return !ChatTracker.coloursDiffer(a.color, b.color)
    }

    /// Whether two sampled glyph colours are colours of different chat lines. Apart from the
    /// plain distance, two channel colours of different hue that lie close together count as
    /// different (the pink of a public channel and the pale yellow of a creature's speech);
    /// shades of one hue do not (guild and officer green, a row sampled a little darker).
    static func coloursDiffer(_ a: RGBColor, _ b: RGBColor) -> Bool {
        if ChatColors.distance(a, b) > 0.35 { return true }
        guard let x = ChatColors.channel(for: a), let y = ChatColors.channel(for: b), x != y else { return false }
        func hue(_ c: RGBColor) -> RGBColor {
            let peak = max(c.r, max(c.g, c.b))
            return peak > 0 ? RGBColor(r: c.r / peak, g: c.g / peak, b: c.b / peak) : c
        }
        return ChatColors.distance(hue(a), hue(b)) >= 0.2
    }

    /// How far right of the message column a row must start to count as a wrapped row.
    private var indentThreshold: CGFloat { indent > 0 ? 0.5 * indent : 0.22 * lineHeight }

    /// Whether `line` starts on the column of wrapped rows; nil while the columns are unknown.
    private func isIndented(_ line: FrameLine) -> Bool? {
        guard !flat, headerEdge < .greatestFiniteMagnitude, lineHeight > 0, line.box.width > 0 else { return nil }
        return line.box.minX - headerEdge > indentThreshold
    }

    // MARK: - Alignment

    /// Aligns the frame against history. Global in the frame, local in history: the frame may sit
    /// anywhere in history and may run past the end of a known run of lines.
    /// The part of history around what the last non-empty frame showed, wide enough for the
    /// view to have scrolled a full window either way.
    private func neighbourhood(of lineCount: Int) -> Range<Int>? {
        var lo = Int.max, hi = -1
        for (i, e) in history.enumerated() where e.lastSeenFrame == lastViewFrame {
            lo = min(lo, i); hi = max(hi, i)
        }
        guard hi >= 0 else { return nil }
        let reach = lineCount + 2
        return max(0, lo - reach)..<min(history.count, hi + 1 + reach)
    }

    private func align(_ lines: [FrameLine], window: Range<Int>, pinnedToEnd: Bool = false) -> (steps: [Step], score: Double) {
        let n = lines.count, m = window.count
        let total = history.count
        let offset = window.lowerBound
        if m == 0 { return (lines.map { _ in .new(boundary: total) }, -0.1 * Double(n)) }

        // Pair scores, computed on demand. NaN = not computed, infinity = no match; `strictPair`
        // tells a confident match from a "possibly the same line, read badly" one.
        var pair = [Double](repeating: .nan, count: n * m)
        var strictPair = [Bool](repeating: false, count: n * m)
        let weights = lines.map { 1.5 + Double(min($0.key.count, 30)) / 10 }
        let hist = Array(history[window])
        // Lines that were on screen a moment ago are the likeliest to be on screen now.
        let recentFrame = frameNo - 2
        func score(_ i: Int, _ j: Int) -> Double {
            let cached = pair[i * m + j]
            if !cached.isNaN { return cached }
            let v: Double
            // An identical read counts double a merely similar one: a block of look-alike older
            // lines (the same people repeating themselves) must not outweigh the true position,
            // where all but the newest lines match exactly.
            let recency = hist[j].lastSeenFrame >= recentFrame ? 1.5 : 0
            switch LineSimilarity.compare(lines[i].key, hist[j].key) {
            case .none: v = .infinity
            case .loose: v = recency - 2.5
            case .strict(let q):
                v = (q >= 1 ? weights[i] : weights[i] * 0.5 * q) + recency
                strictPair[i * m + j] = true
            }
            pair[i * m + j] = v
            return v
        }

        let width = m + 1
        let minusInf = -Double.infinity
        var dp = [Double](repeating: minusInf, count: (n + 1) * width)
        var back = [UInt8](repeating: 0, count: (n + 1) * width)   // 1 match, 2 skip history, 3 skip frame
        for j in 0...m { dp[j] = 0 }

        for i in 0...n {
            for j in 0...m {
                let cur = dp[i * width + j]
                if cur == minusInf { continue }
                if i < n {
                    if j < m {
                        let s = score(i, j)
                        if s != .infinity {
                            let v = cur + s
                            let t = (i + 1) * width + j + 1
                            if v >= dp[t] { dp[t] = v; back[t] = 1 }
                        }
                    }
                    // An unknown line is expected past the end of a run. Between two lines known to
                    // be adjacent it can only be a line OCR missed earlier or an unrecognisable
                    // misread, both rare; the stiff price keeps the frame from being fitted onto
                    // older chat that merely shares some lines with it.
                    let atRunEnd = offset + j == total || history[offset + j].gapBefore
                    let v = cur - (atRunEnd ? 0.1 : 3)
                    let t = (i + 1) * width + j
                    if v > dp[t] { dp[t] = v; back[t] = 3 }
                }
                if i > 0 && i < n && j < m {
                    // A known line missing from the frame (OCR dropped it, or another tab hides it).
                    let v = cur - (hist[j].tentative ? 0.05 : 1.5)
                    let t = i * width + j + 1
                    if v > dp[t] { dp[t] = v; back[t] = 2 }
                }
            }
        }

        var bestJ = 0
        var best = minusInf
        for j in 0...m where dp[n * width + j] >= best { best = dp[n * width + j]; bestJ = j }
        // The frame must end at the end of history or below it.
        if pinnedToEnd { bestJ = m; best = dp[n * width + m] }

        var steps = [Step](repeating: .new(boundary: total), count: n)
        var i = n, j = bestJ
        while i > 0 {
            switch back[i * width + j] {
            case 1:
                i -= 1; j -= 1
                steps[i] = .match(offset + j, strict: strictPair[i * m + j])
            case 2:
                j -= 1
            default:
                i -= 1
                steps[i] = .new(boundary: offset + j)
            }
        }
        return (steps, best)
    }

    /// 2 for a sound header row, 1 for a damaged one, nil for a row that is no header row.
    private static func headerRank(_ parsed: ParsedChatLine) -> Int? {
        if parsed.headerBroken { return 1 }
        return parsed.hasPrefix ? 2 : nil
    }

    private func isConfidentHeader(_ line: FrameLine) -> Bool {
        line.parsed.hasPrefix && line.confidence >= ChatTracker.confidentRead
    }

    /// A header row good enough to tell where messages start: where a row begins does not
    /// depend on how well its end was read, so a recognised tag vouches for a doubtful read.
    private func isColumnHeader(_ line: FrameLine) -> Bool {
        line.parsed.hasPrefix && (line.confidence >= ChatTracker.confidentRead || !line.parsed.headerTag.isEmpty)
    }

    /// Whether the colour sampled from a header row is the colour of its message. With only a
    /// word or two behind the header, a class-coloured name or text of the world over the end
    /// of the row outweighs it.
    private func hasMessageColour(_ header: FrameLine) -> Bool {
        if header.parsed.body.reduce(0, { $0 + ($1.isLetter || $1.isNumber ? 1 : 0) }) >= 8 { return true }
        // A short message whose sampled colour is the colour of the channel its tag names:
        // nothing else was mistaken for it.
        guard !header.parsed.headerTag.isEmpty, header.parsed.channel != .unknown,
              let sampled = ChatColors.channel(for: header.color) else { return false }
        if sampled == header.parsed.channel { return true }
        let greens: Set<ChatChannel> = [.guild, .officer], oranges: Set<ChatChannel> = [.raid, .instance, .raidWarning]
        return (greens.contains(sampled) && greens.contains(header.parsed.channel))
            || (oranges.contains(sampled) && oranges.contains(header.parsed.channel))
    }

    /// Both read with confidence and nothing alike: two different lines, not two reads of one.
    /// A short body under the same name does not count: "gg" really is read as "88" at times.
    private func isAnotherLine(_ line: FrameLine, than e: Entry) -> Bool {
        guard isConfidentHeader(line), e.confidence >= ChatTracker.confidentRead,
              LineSimilarity.compare(line.key, e.key) == .none else { return false }
        // Against a line without a header the comparison was on the whole text already.
        if !e.key.hasHeader || min(line.key.body.count, e.key.body.count) >= 6 { return true }
        let a = line.key.name, b = e.key.name
        return TextFold.distance(a, b, limit: max(1, max(a.count, b.count) / 2)) == nil
    }

    /// Whether `line`, on the row of the known line `e`, is that row read differently although
    /// the two have little in common: it reads as what went out for the row (whatever the row
    /// has read as in between), or the two are one speaker's header row with different words.
    /// Nobody says two things on one row, and what is drawn over a row leaves its start
    /// alone as often as not.
    private func isSameRowReadDifferently(_ line: FrameLine, _ e: Entry) -> Bool {
        if let went = e.reportedKey, LineSimilarity.compare(went, line.key).isStrict { return true }
        return isSameSpeakerSayingOtherWords(line, e)
    }

    /// Two sound header rows with the same tag and the same speaker and other words behind
    /// the colon. Not when `line` says what `e` says and goes on, unless it goes on with what
    /// a name of the world reads as: a row first read without its last words and whole later
    /// is told from a row read wrong, and the whole read stays a line of its own.
    private func isSameSpeakerSayingOtherWords(_ line: FrameLine, _ e: Entry) -> Bool {
        guard line.parsed.hasPrefix, e.parsed.hasPrefix, !line.parsed.headerBroken, !e.parsed.headerBroken, !e.covered,
              !line.key.name.isEmpty, line.key.name == e.key.name, line.key.tag == e.key.tag else { return false }
        let now = line.key.body, known = e.key.body
        guard now != known, !now.isEmpty, !known.isEmpty else { return false }
        guard now.count > known.count, now.starts(with: known) else { return true }
        let more = line.parsed.body.split(separator: " ").dropFirst(e.parsed.body.split(separator: " ").count)
        return !more.isEmpty && ChatTracker.readsLikeAName(more.joined(separator: " "))
    }

    /// True when the alignment puts a cleanly read message between two lines history knows to
    /// be neighbours, in place of a line it has nothing in common with.
    private func contradictsHistory(_ lines: [FrameLine], _ steps: [Step]) -> Bool {
        for (i, step) in steps.enumerated() {
            guard case .new(let b) = step, b > 0, b < history.count, !history[b].gapBefore,
                  !history[b].tentative, !history[b - 1].tentative else { continue }
            if isAnotherLine(lines[i], than: history[b]), isAnotherLine(lines[i], than: history[b - 1]) { return true }
        }
        return false
    }

    /// Known lines on top, then only lines below the end of history.
    private func isPlainContinuation(_ steps: [Step]) -> Bool {
        guard case .match = steps.first else { return false }
        return !steps.contains { if case .new(let b) = $0 { return b < history.count } else { return false } }
    }

    /// Chat only ever moves as a block: once the scroll distance since the previous frame is
    /// known from the lines that were recognised, an unrecognised line sitting exactly where a
    /// known line must now be IS that line, however differently it was read this time.
    private func matchByPosition(_ lines: [FrameLine], steps: inout [Step]) {
        guard lineHeight > 0 else { return }
        var taken = Set<Int>()
        var samples: [(line: Int, shift: CGFloat)] = []
        var strictSamples = 0
        for (i, step) in steps.enumerated() {
            guard case .match(let j, let strict) = step else { continue }
            taken.insert(j)
            let e = history[j]
            if e.lastSeenFrame == frameNo - 1 {
                samples.append((i, lines[i].box.midY - e.box.midY))
                if strict { strictSamples += 1 }
            }
        }
        guard !samples.isEmpty else { return }
        let sorted = samples.map(\.shift).sorted()
        let shift = sorted[sorted.count / 2]
        // Most recognised lines must agree on how far the window moved ...
        let outliers = samples.filter { abs($0.shift - shift) >= 0.4 * lineHeight }
        guard outliers.count * 3 <= samples.count else { return }
        geoShift = shift
        // ... and a line that claims to have moved differently was paired with the wrong twin
        // ("gg" under "gg"): it is a line of its own, above or below the one it resembles.
        for o in outliers {
            guard case .match(let j, _) = steps[o.line] else { continue }
            taken.remove(j)
            steps[o.line] = .new(boundary: o.shift > shift ? j + 1 : j)
        }
        for (i, step) in steps.enumerated() {
            guard case .new(var boundary) = step else { continue }
            let y = lines[i].box.midY
            let onRow = history.indices.first { j in
                let e = history[j]
                return e.lastSeenFrame == frameNo - 1 && !taken.contains(j) && abs(e.box.midY + shift - y) < 0.35 * lineHeight
            }
            if let j = onRow {
                let e = history[j]
                // A damaged header on the row of a known line is that line with something
                // drawn over it, and a sound header on the row of a damaged one that is still
                // waiting (or went out in doubt) is the clean read it waits for. Otherwise two
                // confident headers that have nothing in common are two lines (another chat
                // tab showing the same neighbours).
                // So is a sound header under the same tag and the same name with other words
                // behind the colon, and a row that reads as what went out for it (see
                // `isSameRowReadDifferently`); for those one line that is known for sure to
                // have stayed where it was is enough to tell which row this is.
                let placed = samples.count - outliers.count >= 2
                let sameRowForSure = (placed
                    && (lines[i].parsed.headerBroken || (e.parsed.headerBroken && (!e.done || e.provisional))))
                    || ((placed || (outliers.isEmpty && strictSamples >= 1)) && isSameRowReadDifferently(lines[i], e))
                if sameRowForSure || !isAnotherLine(lines[i], than: e) {
                    taken.insert(j)
                    steps[i] = .match(j, strict: false)
                    continue
                }
                // Another line where that one was: it goes below the stale entry, so that the
                // rows under it are its wrapped rows and not the stale entry's.
                steps[i] = .new(boundary: j + 1)
                continue
            }
            // A new line belongs below every line that was above its row a moment ago, even
            // when OCR skipped that line in this frame.
            while boundary < history.count, !taken.contains(boundary),
                  history[boundary].lastSeenFrame == frameNo - 1,
                  history[boundary].box.midY + shift < y - 0.5 * lineHeight {
                boundary += 1
            }
            steps[i] = .new(boundary: boundary)
        }
    }

    /// The same idea without the previous frame: lines known to sit on consecutive rows keep
    /// doing so. An unrecognised line N rows below (or above) a recognised one is the line N
    /// places after (before) it in history, when history knows those lines to be adjacent.
    private func matchByRow(_ lines: [FrameLine], steps: inout [Step]) {
        guard rowPitch > 0, lineHeight > 0 else { return }
        var taken = Set<Int>()
        for case .match(let j, _) in steps { taken.insert(j) }

        /// History index `rows` believed lines away from `from`, nil when the chain of known
        /// adjacency breaks first. Unconfirmed lines do not count as rows.
        func walk(from: Int, rows: Int, down: Bool) -> Int? {
            var j = from, left = rows
            while left > 0 {
                if down {
                    guard j + 1 < history.count, !history[j + 1].gapBefore else { return nil }
                    j += 1
                } else {
                    guard j > 0, !history[j].gapBefore else { return nil }
                    j -= 1
                }
                if !history[j].tentative { left -= 1 }
            }
            return j
        }
        func rows(between a: Int, and b: Int) -> Int? {
            let distance = abs(lines[a].box.midY - lines[b].box.midY)
            let n = (distance / rowPitch).rounded()
            guard n >= 1, abs(distance - n * rowPitch) < 0.35 * lineHeight else { return nil }
            return Int(n)
        }
        // Only valid while the frame shows history's own layout: another chat tab can show the
        // same lines with different neighbours. The recognised lines tell: their spacing on
        // screen must be their spacing in history.
        let matched = steps.indices.filter { if case .match = steps[$0] { return true } else { return false } }
        var agreeing = 0
        for (p, q) in zip(matched, matched.dropFirst()) {
            guard case .match(let a, _) = steps[p], case .match(let b, _) = steps[q], a < b else { return }
            if history[a].tentative || history[b].tentative { continue }
            guard let n = rows(between: p, and: q), let reached = walk(from: a, rows: n, down: true) else { continue }
            if reached == b { agreeing += 1; continue }
            // Two identical lines in a row ("gg", "gg") and the upper one on screen was paired
            // with the lower one in history: move it up when that makes the spacing right.
            guard let twin = walk(from: b, rows: n, down: false), twin < a, !taken.contains(twin),
                  LineSimilarity.compare(lines[p].key, history[twin].key).isStrict else { return }
            taken.remove(a)
            taken.insert(twin)
            steps[p] = .match(twin, strict: true)
            agreeing += 1
        }
        guard agreeing >= 1 else { return }

        for i in steps.indices {
            guard case .new = steps[i] else { continue }
            var found: Int?
            if let p = steps[..<i].lastIndex(where: { if case .match = $0 { return true } else { return false } }),
               case .match(let a, _) = steps[p], let n = rows(between: p, and: i) {
                found = walk(from: a, rows: n, down: true)
            }
            if found == nil,
               let q = steps[(i + 1)...].firstIndex(where: { if case .match = $0 { return true } else { return false } }),
               case .match(let b, _) = steps[q], let n = rows(between: i, and: q) {
                found = walk(from: b, rows: n, down: false)
            }
            if let j = found, !taken.contains(j), !isAnotherLine(lines[i], than: history[j]) {
                taken.insert(j)
                steps[i] = .match(j, strict: false)
            }
        }
    }

    // MARK: - Applying a frame

    private func apply(_ lines: [FrameLine], steps: [Step], anchored: Bool, afterFade: Bool, now: Date) {
        let m = history.count
        var inserts: [(boundary: Int, entry: Entry)] = []
        var previous: Entry?
        var previousMatchIndex: Int?
        var previousInsertBoundary: Int?
        // True while every line since the last matched one extended a known run.
        var live = false

        for (i, line) in lines.enumerated() {
            // Without one confident match the frame shows something else entirely (first frame,
            // other tab, a burst that replaced the whole window): chance resemblances are ignored.
            let step: Step = anchored ? steps[i] : .new(boundary: m)
            // An empty text row above this line: OCR skipped a line, so what is directly above is unknown.
            let rowGap = i > 0 && rowPitch > 0 && line.box.midY - lines[i - 1].box.midY > 1.6 * rowPitch
            switch step {
            case .match(let j, let strict):
                let e = history[j]
                if e.lastSeenFrame != frameNo {
                    e.lastShift = e.lastSeenFrame == frameNo - 1 ? line.box.midY - e.box.midY : nil
                    e.sightings += 1
                    e.lastSeenFrame = frameNo
                }
                // A name over the row tells where the row is, not where its text starts and ends.
                e.box = line.covered && !e.covered
                    ? CGRect(x: e.box.minX, y: line.box.midY - e.box.height / 2, width: e.box.width, height: e.box.height)
                    : line.box
                if e.tentative && e.sightings >= 2 { e.tentative = false }
                func adopt(_ l: FrameLine) {
                    e.text = l.text; e.parsed = l.parsed; e.key = l.key
                    e.color = l.color; e.confidence = l.confidence
                }
                func snapshot() -> FrameLine {
                    FrameLine(text: e.text, parsed: e.parsed, key: e.key, color: e.color, box: e.box, confidence: e.confidence)
                }
                let lineRank = ChatTracker.headerRank(line.parsed), entryRank = ChatTracker.headerRank(e.parsed)
                // The row went out with a name of the world read into it, and reads without
                // one now: once is a glimpse, twice running is the row.
                let sheds = e.reported && !e.withheld && !line.covered && line.confidence >= ChatTracker.sureRead
                    && frameNo - e.reportedFrame <= ChatTracker.shedFrames
                    && !LanguageGate.isUnreadable(line.parsed.hasPrefix ? line.parsed.body : line.text)
                    && (e.reportedText.map { hadWorldText($0, where: line) } ?? false)
                e.shedSightings = sheds ? e.shedSightings + 1 : 0
                if sheds, e.shedSightings >= 2 {
                    adopt(line)
                    e.votes = 2; e.rival = nil
                    e.exact = 2; e.spelling = nil
                    e.churnFrame = 0
                    e.streak = 2
                    // What went out is no longer what this row is measured against.
                    e.reportedConfidence = min(e.reportedConfidence ?? line.confidence, line.confidence)
                    e.shed = true
                } else if line.covered {
                    // Hidden in this frame: nothing is learned about what the row reads as.
                    e.streak = 0
                } else if e.covered {
                    // The first read of a row known only as hidden.
                    adopt(line)
                    e.covered = false
                    e.votes = 1; e.rival = nil
                    e.exact = 1; e.spelling = nil
                    e.churnFrame = 0
                    e.streak = 1
                    e.adoptedFrame = frameNo
                    e.done = false
                    e.isStart = startsMessage(line, above: i > 0 && !rowGap && !lines[i - 1].covered ? lines[i - 1] : nil)
                } else if !strict, lineRank == 2, entryRank == nil, e.isStart {
                    // A sound header row where a headerless line was read, and the two reads
                    // have little in common: the earlier one was the row with something drawn
                    // over it (a name over the channel tag leaves nothing that reads as chat).
                    adopt(line)
                    e.votes = 1; e.rival = nil
                    e.exact = 1; e.spelling = nil
                    e.streak = 1
                    if e.done { e.done = false; e.revived = true }
                } else if let lineRank, let entryRank, lineRank != entryRank {
                    // One of the two reads has a damaged header: the sounder one is the line,
                    // however often the damaged one is seen while something covers the row.
                    if lineRank > entryRank, !e.done || e.provisional {
                        adopt(line)
                        e.votes = 1; e.rival = nil
                        e.exact = 1; e.spelling = nil
                        e.churnFrame = 0
                        e.streak = 1
                        e.adoptedFrame = frameNo
                        // Its message went out without this row: it is said again, whole.
                        e.done = false
                    }
                } else if strict {
                    e.votes += 1
                    e.streak += 1
                    if line.text == e.text {
                        e.exact += 1
                        if line.confidence > e.confidence { e.color = line.color; e.confidence = line.confidence }
                    } else {
                        // Remember how the line usually reads, so that one odd first read does
                        // not weaken every later comparison. Before the line is reported the
                        // read to keep is the surer one, then the one seen more often, then
                        // the newer one: what was drawn over the row a moment ago is gone.
                        let count = (e.spelling.map { $0.line.text == line.text ? $0.count : 0 } ?? 0) + 1
                        let surer = e.done ? line.confidence >= e.confidence : line.confidence > e.confidence + 0.05
                        let steadier = !e.done && line.confidence >= e.confidence - 0.05 && count >= e.exact
                        if surer || steadier {
                            let old = snapshot(), oldCount = e.exact
                            adopt(line)
                            e.exact = count
                            e.spelling = (old, oldCount)
                        } else {
                            e.spelling = (line, count)
                        }
                    }
                } else {
                    // Same line by position, read differently. The reading most frames agree on
                    // wins; OCR's own confidence breaks the tie in favour of the newcomer.
                    var support = 1
                    if let r = e.rival {
                        if LineSimilarity.compare(r.line.key, line.key).isStrict {
                            support = r.votes + 1
                        } else {
                            // A third reading: whatever is drawn over the row is moving.
                            e.churnFrame = frameNo
                        }
                    }
                    e.rival = (line, support)
                    // A row that was left out of its message for want of a read to trust takes
                    // the first read that comes twice.
                    // So does a reading OCR is clearly surer of, once it has come twice: what
                    // was drawn over the row is gone.
                    let believed = support >= 2 && (e.withheld || line.confidence >= e.confidence + 0.2)
                    let outvoted = support > e.votes || (support == e.votes && line.confidence > e.confidence + 0.05)
                    if outvoted || believed {
                        let wasDistrusted = e.confidence < 0.4
                        let unrelated = LineSimilarity.compare(line.key, e.key) == .none
                        let old = snapshot()
                        adopt(line)
                        // What a withheld row went by was never believed, and what OCR was
                        // unsure of has lost to what it is sure of: neither is a rival, however
                        // many frames showed it.
                        e.rival = outvoted && !e.withheld ? (old, e.votes) : nil
                        e.votes = support
                        e.exact = 1; e.spelling = nil
                        e.withheld = false
                        e.streak = min(support, 2)
                        // Reported from a read OCR itself distrusted, and the row has since read
                        // as something else altogether: report the line again, properly this time.
                        if e.done, e.isStart, wasDistrusted, unrelated { e.done = false }
                    } else {
                        e.streak = 0
                    }
                }
                // First seen before the columns were known and taken for a message of its own:
                // a row on the column of wrapped rows, right below another row, is not.
                if e.isStart, !e.done, !e.covered, !line.covered, !e.parsed.hasPrefix, i > 0, !rowGap, isIndented(line) == true,
                   !startsMessage(line, above: lines[i - 1]) {
                    e.isStart = false
                }
                if !rowGap, previousMatchIndex == j - 1 || previousInsertBoundary == j {
                    e.gapBefore = false
                    // Born while the row above it was not read: now that it is, the row is
                    // judged like any other (a notice on the message column is no wrapped row).
                    if e.undecidedStart, i > 0 {
                        e.undecidedStart = false
                        if !e.done, !e.isStart, !e.covered, !line.covered, !lines[i - 1].covered,
                           startsMessage(line, above: lines[i - 1]) {
                            e.isStart = true
                        }
                    }
                }
                previous = e
                previousMatchIndex = j
                previousInsertBoundary = nil
                live = true
            case .new(let boundary):
                let atRunEnd = boundary == m || history[boundary].gapBefore
                let isLive = anchored && live && atRunEnd
                if !isLive { live = false }
                var above = i > 0 && !rowGap ? lines[i - 1] : nil
                var unknownAbove = previous == nil || rowGap
                // The line on the row above may be one OCR skipped this time but read last time.
                if above == nil, let shift = geoShift, rowPitch > 0, boundary > 0, inserts.last?.boundary != boundary {
                    let e = history[boundary - 1]
                    if e.lastSeenFrame == frameNo - 1,
                       abs(e.box.midY + shift + rowPitch - line.box.midY) < 0.35 * lineHeight {
                        above = FrameLine(text: e.text, parsed: e.parsed, key: e.key, color: e.color,
                                          box: e.box.offsetBy(dx: 0, dy: shift), confidence: e.confidence, covered: e.covered)
                        unknownAbove = false
                    }
                }
                // A hidden row says nothing about the row under it, and is where a message
                // starts until it reads as something else.
                let entry = Entry(line, isStart: line.covered || startsMessage(line, above: above?.covered == true ? nil : above),
                                  gapBefore: unknownAbove, tentative: !isLive, frame: frameNo, now: now)
                entry.afterFade = afterFade
                entry.covered = line.covered
                entry.undecidedStart = !entry.isStart && above == nil && !line.covered
                entry.orphan = isLive && !entry.isStart && i > 0
                if boundary < m, previousInsertBoundary != boundary {
                    // First of a run inserted here; the last of the run takes this over below.
                    entry.savedNextGap = history[boundary].gapBefore
                } else if let last = inserts.last, previousInsertBoundary == boundary {
                    entry.savedNextGap = last.entry.savedNextGap
                    last.entry.savedNextGap = nil
                }
                inserts.append((boundary, entry))
                previous = entry
                previousMatchIndex = nil
                previousInsertBoundary = boundary
            }
        }

        let shifts = history.compactMap { $0.lastSeenFrame == frameNo && $0.bornFrame != frameNo ? $0.lastShift : nil }.sorted()
        if !shifts.isEmpty { frameShift = shifts[shifts.count / 2] }

        guard !inserts.isEmpty else { return }
        // Stable by boundary: lines for one place keep their order on screen.
        inserts = inserts.enumerated().sorted {
            $0.element.boundary != $1.element.boundary ? $0.element.boundary < $1.element.boundary : $0.offset < $1.offset
        }.map(\.element)
        var merged: [Entry] = []
        merged.reserveCapacity(m + inserts.count)
        var k = 0
        for j in 0...m {
            while k < inserts.count, inserts[k].boundary == j { merged.append(inserts[k].entry); k += 1 }
            if j < m { merged.append(history[j]) }
        }
        history = merged
    }

    /// Whether `line` is the first screen line of a message, judged from where it starts and
    /// from the line above it.
    private func startsMessage(_ line: FrameLine, above: FrameLine?) -> Bool {
        let indented = isIndented(line)
        if line.parsed.hasPrefix || line.parsed.timestamp != nil {
            // "[Some Item]: 5g" at the start of a wrapped row reads like a "[Name]:" header, but
            // no message starts on the column of wrapped rows.
            if indented == true, above != nil, indent > 0, headerSamples.count >= 3,
               line.parsed.timestamp == nil, line.parsed.headerTag.isEmpty,
               abs(line.box.minX - headerEdge - indent) <= 0.5 * indentThreshold {
                return false
            }
            return true
        }
        // What is left of a header row something was drawn over. A wrapped row that starts
        // with a link looks the same and is told by its column.
        if line.parsed.headerBroken, indented == false || (indented == nil && ChatLineParser.opensLikeHeader(line.text)) {
            return true
        }
        let ownColour = line.parsed.channel == .system || line.parsed.channel == .emote
        guard let above else {
            // Top of the window: a headerless line is normally the tail of a message whose first
            // line has scrolled out. System and emote lines are the exception.
            return ownColour && indented != true
        }
        // The colour sampled from a row is that of its text outside link brackets. A row with
        // next to none (the rest of a link that wrapped, in the link's own colour, which may
        // be the orange of an emote or the yellow of a notice) has no colour that says
        // anything; a notice that begins with a link ("[Some Item]을 만들었습니다.") has.
        let ownText = ChatLinks.hasBrackets(line.text) ? ChatLinks.lettersOutsideLinks(line.text) : Int.max
        // The row above ends inside a link and this one stands on the column of wrapped rows,
        // where no line of its own can start: the rest of that link, in whatever colour and
        // however its brackets were read ("Vowl[Bring Back a Ring]").
        if indented == true, ChatLinks.leavesLinkOpen(above.text), ChatLinks.hasBrackets(line.text) { return false }
        // The same told by the brackets alone, wherever the box of the row begins: it closes a
        // link it never opened, right below a row that opened one and did not close it. No
        // line of its own begins in the middle of a link.
        if ChatLinks.leavesLinkOpen(above.text), ChatLinks.closesUnopenedLink(line.text), line.box.minX >= above.box.minX {
            return false
        }
        // The same with the closing bracket read as a letter, or not read ("the Silver Moonl
        // pst me" in the yellow of a quest link): nothing in the row says link, but it stands
        // exactly where wrapped rows start, right below a row that ends inside one. A notice
        // of its own stands on the message column.
        if indented == true, ChatLinks.leavesLinkOpen(above.text),
           line.box.minX - headerEdge <= (indent > 0 ? indent + indentThreshold : lineHeight) {
            return false
        }
        let differs = ChatTracker.coloursDiffer(line.color, above.color) && ownText >= 2
        // A system or emote line in its own colour below something else.
        if differs, ownColour { return true }
        // Its box does not show where the row starts; a row in the colour of the one above is
        // taken for its continuation.
        if line.looseStart, !differs { return false }
        let hasGeometry = lineHeight > 0 && line.box.width > 0 && above.box.width > 0
        if let indented {
            if indented { return false }    // wrapped row
        } else if headerEdge == .greatestFiniteMagnitude, hasGeometry, leftEdge < .greatestFiniteMagnitude,
                  line.box.minX - leftEdge > 0.8 * lineHeight {
            // Indented continuation, judged without having seen a header row. (Not in a window
            // known to indent nothing: there the leftmost text ever seen proves nothing.)
            return false
        }
        // Wrapped lines keep the colour of their message. The colour read off a header row
        // with little text behind it is not to be trusted for this.
        if differs, !above.parsed.hasPrefix || hasMessageColour(above) { return true }
        // The window is known to indent wrapped rows and this row is not indented.
        if indented == false, indent > 0 { return true }
        guard hasGeometry, rightLimit > 0 else { return false }
        // The game wraps only when the next word does not fit: if this line's first word would
        // have fitted behind the line above, it was not wrapped from it.
        let columns = max(1, TextFold.columns(line.text))
        let perColumn = line.box.width / CGFloat(columns)
        let firstWord = line.text.split(separator: " ").first.map { TextFold.columns($0) } ?? columns
        let needed = CGFloat(min(firstWord, 24) + 1) * perColumn * 1.1 + 0.02 * rightLimit
        return rightLimit - above.box.maxX > needed
    }

    // MARK: - Deciding what to report

    private struct Group {
        var start: Int
        var end: Int        // inclusive
        var isMessage: Bool
    }

    private func groups() -> [Group] {
        var out: [Group] = []
        for (i, e) in history.enumerated() {
            if e.isStart {
                out.append(Group(start: i, end: i, isMessage: true))
            } else if !e.gapBefore, !out.isEmpty, out[out.count - 1].end == i - 1,
                      !out[out.count - 1].isMessage || wraps(e, from: history[out[out.count - 1].start]) {
                out[out.count - 1].end = i
            } else {
                out.append(Group(start: i, end: i, isMessage: false))
            }
        }
        return out
    }

    /// Whether the headerless row `e` can be a wrapped row of the message that starts with
    /// `head`. Wrapped rows keep the colour of their message: a row in the colour of a player
    /// channel under a headerless line in another colour (a system notice, or a name of the
    /// world read where the real header row is) belongs to a message whose header was not read.
    private func wraps(_ e: Entry, from head: Entry) -> Bool {
        guard !head.parsed.hasPrefix, head !== e,
              let channel = ChatColors.channel(for: e.color), channel != .system, channel != .emote,
              e.key.count >= 4 else { return true }
        // What is left of a channel header row with something drawn over it has the colour
        // of whatever covers it; the rows below are its wrapped rows all the same.
        if head.covered || (head.parsed.headerBroken && ChatLineParser.opensLikeHeader(head.text)) { return true }
        return ChatColors.channel(for: head.color) == channel || ChatColors.distance(head.color, e.color) <= 0.35
    }

    private func settle(anchored: Bool) -> [ChatMessage] {
        var seenLo = Int.max, seenHi = -1
        for (i, e) in history.enumerated() where e.lastSeenFrame == frameNo {
            seenLo = min(seenLo, i); seenHi = max(seenHi, i)
        }
        // Did the known lines stay where they were? Then nothing below them scrolled out of view.
        let bottomInPlace = frameShift.map { abs($0) < max(1, 0.5 * lineHeight) } ?? false

        let rowMissingBelow = seenHi >= 0 && rowPitch > 0 && bottomRow - frameBottom > 0.6 * rowPitch

        var remove = Set<Int>()
        var emitted: [ChatMessage] = []
        let recentBefore = recent.count
        // Set while a message above is held back for a better read of one of its rows: what
        // was said after it waits too, so that messages come out in the order they were said.
        var heldAbove = false

        for g in groups() {
            let range = g.start...g.end
            if !g.isMessage {
                let first = history[g.start]
                // Rows of chat that arrived under a row that did not read as their header: it
                // may be hidden by text of the game world. They wait for it like a message
                // with a damaged header row, and go out without it when it does not come.
                if first.orphan, !first.done, isChatWithoutHeader(range) {
                    let seenNow = range.contains { history[$0].lastSeenFrame == frameNo }
                    if seenNow, frameNo - first.bornFrame < ChatTracker.maxDoubtFrames {
                        heldAbove = true
                        continue
                    }
                    if heldAbove { continue }
                    // Seen twice, or once and read for sure: rows that the chat has carried
                    // out of view are not read a second time.
                    if range.allSatisfy({ history[$0].sightings >= 2 || history[$0].confidence >= ChatTracker.sureRead }) {
                        reportRows(range.map { history[$0] }, under: nil, into: &emitted, recentCount: recentBefore)
                        continue
                    }
                }
                // Tail of a message whose head was never seen: nothing to report.
                for i in range {
                    let e = history[i]
                    e.done = true
                    if e.tentative && e.lastSeenFrame != frameNo { remove.insert(i) }
                }
                continue
            }
            let head = history[g.start]
            if head.done {
                if head.provisional || range.contains(where: { history[$0].shed }), anchored, readsCleanly(range) {
                    // Went out while part of it could not be read, or with a name of the
                    // world read into one of its rows, and all of it reads now.
                    report(range, into: &emitted, recentCount: recentBefore)
                    continue
                }
                // Late lines of a message that was already reported are swallowed.
                for i in range {
                    let e = history[i]
                    if e.tentative && e.lastSeenFrame != frameNo { remove.insert(i) } else { e.done = true }
                }
                continue
            }
            let seenNow = range.contains { history[$0].lastSeenFrame == frameNo }
            // Went out in doubt before and was opened again by a clean read of its header row:
            // the earlier report stands until this one can replace it, and nothing waits for it.
            let again = head.messageID != nil
            let inside = anchored && g.start > seenLo && g.end < seenHi
            let vanishedAtBottom = anchored && g.start == seenHi + 1 && !head.gapBefore && bottomInPlace
            let next = g.end + 1
            // Another message is known to start right below this one, so it is complete.
            let closed = next < history.count && history[next].isStart && !history[next].gapBefore
                && !history[next].tentative
            // A header row that reads as damaged waits for a clean read of its row, and a row
            // that reads as two or more different things for one of them to come again.
            let doubtful = head.parsed.headerBroken || range.contains { !remove.contains($0) && isUnsteady(history[$0]) }
            let waiting = frameNo - head.bornFrame < ChatTracker.maxDoubtFrames

            if !seenNow {
                if again {
                    range.forEach { history[$0].done = true }
                } else if head.tentative {
                    if inside || vanishedAtBottom || !isCredible(range, recentCount: recentBefore) {
                        range.forEach { remove.insert($0) }
                    } else if heldAbove {
                        // Decided once the message above is out.
                    } else {
                        report(range, into: &emitted, recentCount: recentBefore)
                    }
                } else if vanishedAtBottom || rowWasReread(head) {
                    // Shown for one frame as the newest line, then gone (or read as something
                    // else) while its neighbours stayed put: a misread, not chat.
                    range.forEach { remove.insert($0) }
                } else if inside && head.parsed.headerBroken && waiting {
                    // Its row was not read this time; the clean read it waits for may still come.
                    heldAbove = true
                } else if heldAbove {
                } else if inside && !closed && frameNo - head.bornFrame < ChatTracker.maxHoldFrames {
                    // OCR skipped it this once, and what follows it is not known to be the next
                    // message: its last line may still be missing.
                } else {
                    // Scrolled out of view, or complete. Unconfirmed extra lines go.
                    for i in range where history[i].tentative { remove.insert(i) }
                    report(range, skipping: remove, into: &emitted, recentCount: recentBefore, inDoubt: doubtful)
                }
                continue
            }

            // Tentative lines the frame skipped over while showing their neighbours were noise.
            // One below the lowest visible line, with its row empty, is just a line OCR missed
            // this time: it gets a few frames to come back.
            var stillTentative = false
            for i in range where history[i].tentative {
                let e = history[i]
                let awaited = i > seenHi && rowMissingBelow && frameNo - e.bornFrame < ChatTracker.maxHoldFrames
                if e.lastSeenFrame == frameNo || awaited || !anchored {
                    stillTentative = true
                } else if i < seenLo {
                    // Scrolled out above the window while the rest of its message is still
                    // there to vouch for it.
                    e.tentative = false
                } else {
                    remove.insert(i)
                }
            }
            if head.tentative || stillTentative { continue }
            let live = range.filter { !remove.contains($0) }
            var settled = live.allSatisfy { history[$0].bornFrame < frameNo }
            // The newest message with an unread row below it is probably missing its last line;
            // give OCR a few more frames to deliver it.
            if settled, g.end == seenHi, rowMissingBelow, frameNo - head.bornFrame < ChatTracker.maxHoldFrames {
                settled = false
            }
            // A sound read that has just replaced a damaged one is believed when it comes again.
            let unconfirmed = head.adoptedFrame > 0 && head.votes < 2
            if again {
                // The earlier report stands until the clean read of the header row has come
                // twice and every row reads cleanly (`readsCleanly` takes it up from there).
                if unconfirmed, frameNo - head.adoptedFrame < ChatTracker.maxDoubtFrames { continue }
                if unconfirmed || doubtful {
                    range.forEach { history[$0].done = true }
                    continue
                }
            } else if (unconfirmed && (waiting || frameNo == head.adoptedFrame)) || (doubtful && waiting) {
                heldAbove = true
                continue
            }
            // A read OCR itself distrusts gets a few frames to be replaced by a better one,
            // unless it keeps coming out the same.
            if live.contains(where: { history[$0].confidence < 0.4 && history[$0].votes < 3 }),
               frameNo - head.bornFrame < ChatTracker.maxDistrustFrames {
                continue
            }
            if (closed || settled) && (again || !heldAbove) {
                report(range, skipping: remove, into: &emitted, recentCount: recentBefore, inDoubt: doubtful || unconfirmed)
            }
        }

        if !remove.isEmpty {
            var kept: [Entry] = []
            kept.reserveCapacity(history.count)
            var pendingGap: Bool?
            for (i, e) in history.enumerated() {
                if remove.contains(i) {
                    // The line after a removed one gets back what was known about its predecessor.
                    if let saved = e.savedNextGap { pendingGap = saved }
                    else if e.gapBefore { pendingGap = true }
                    continue
                }
                if let gap = pendingGap { e.gapBefore = gap || kept.isEmpty; pendingGap = nil }
                kept.append(e)
            }
            history = kept
        }
        return emitted
    }

    /// Whether what a row reads as cannot be taken at its word yet: two unrelated reads seen
    /// equally often, or a third one a moment ago.
    private func isUnsteady(_ e: Entry) -> Bool { e.contested || isChurning(e) }

    /// Three or more unrelated reads of the row, the last of them a moment ago, and the one
    /// it goes by not yet seen twice running: something is moving over it, and none of the
    /// reads can be taken for the row.
    private func isChurning(_ e: Entry) -> Bool {
        e.churnFrame > 0 && frameNo - e.churnFrame <= ChatTracker.churnFrames && e.streak < 2
    }

    /// Whether every row of a message that went out in doubt now reads cleanly: all of them
    /// on screen, the header sound, and no row whose reading is still open.
    private func readsCleanly(_ range: ClosedRange<Int>) -> Bool {
        let head = history[range.lowerBound]
        guard !head.parsed.headerBroken else { return false }
        // A message that went out on a read OCR was unsure of is said again only on one it
        // is sure of, and no row may read less surely than it did when it went out: the
        // second report must be the better one.
        let needed = head.unsure ? ChatTracker.sureRead : ChatTracker.confidentRead
        return range.allSatisfy { i in
            let e = history[i]
            return e.lastSeenFrame == frameNo && !e.tentative && !isUnsteady(e) && e.votes >= 2
                && e.confidence >= max(needed, (e.reportedConfidence ?? 0) - 0.01)
        }
    }

    /// Whether headerless rows are chat that can go out without its header: in the colour of
    /// a player channel, and not what a name of the game world reads as.
    private func isChatWithoutHeader(_ range: ClosedRange<Int>) -> Bool {
        let rows = range.map { history[$0] }
        guard let first = rows.first, !rows.contains(where: \.tentative),
              let channel = ChatColors.channel(for: first.color), channel != .system, channel != .emote,
              rows.reduce(0, { $0 + $1.key.count }) >= 6 else { return false }
        return !ChatTracker.readsLikeAName(assemble(rows).text)
    }

    /// "Some Name", "Some Name <Some Guild>", "<Guild>": up to four capitalised words and
    /// guild tags, which is what a name of the game world reads as and what somebody says
    /// only now and then.
    static func readsLikeAName(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return true }
        guard words.count <= 4 else { return false }
        var inTag = false
        for word in words {
            var w = word
            if w.hasPrefix("<") { inTag = true; w = w.dropFirst() }
            let closes = w.hasSuffix(">")
            if closes { w = w.dropLast() }
            if inTag {
                // A guild is named as its members please ("<EXAMPLE>").
                guard w.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }) else { return false }
            } else if !isNameWord(w) {
                return false
            }
            if closes { inTag = false }
        }
        return true
    }

    /// A capital and lower-case letters behind it ("Thornwood", "O'Neil"), or a word of
    /// another script.
    private static func isNameWord<S: StringProtocol>(_ word: S) -> Bool {
        guard let first = word.first, first.isLetter, word.count >= 2 else { return false }
        if !first.isASCII { return word.allSatisfy { $0.isLetter } }
        return first.isUppercase && word.dropFirst().allSatisfy { ($0.isLetter && $0.isLowercase) || $0 == "'" || $0 == "’" || $0 == "-" }
    }

    /// One to three such words: what a player's name looks like.
    static func isPlainName(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        return (1...3).contains(words.count) && words.allSatisfy(isNameWord)
    }

    /// A damaged header row that has read the same way for the whole wait and still has the
    /// shape of one ("[1. General] [Some Name: text", "[1. General] Some Name: text"): its
    /// brackets are simply not read. What stands behind the colon is taken for what was said,
    /// unless it reads like a name, which is what a name of the world over the end of the
    /// row leaves there. The same for a speaker with a one-letter word in the name that OCR
    /// was sure of every time: somebody's name after all.
    private func readsLikeSpeech(_ head: Entry) -> Bool {
        guard head.parsed.hasPrefix, head.exact >= 3, head.rival == nil, head.churnFrame == 0,
              head.confidence >= ChatTracker.confidentRead else { return false }
        var said = head.parsed.body
        if head.parsed.unclosedName {
            guard let sender = head.parsed.sender, ChatTracker.isPlainName(sender) else { return false }
        } else if head.parsed.oddName {
            guard head.confidence >= 0.9 else { return false }
        } else if head.parsed.unclosedTag {
            // The tag of a channel known from sound rows, without its closing bracket.
            guard soundLabels.contains(head.key.tag), let sender = head.parsed.sender, ChatTracker.isPlainName(sender) else { return false }
        } else if head.parsed.sender == nil, !head.parsed.headerTag.isEmpty, let colon = said.firstIndex(of: ":") {
            guard ChatTracker.isPlainName(String(said[..<colon])) else { return false }
            said = String(said[said.index(after: colon)...])
        } else {
            return false
        }
        return !ChatTracker.readsLikeAName(said.trimmingCharacters(in: .whitespaces))
    }

    /// Whether `was`, a row as it went out, is the row `line` with a name of the game world
    /// read into it: the same row and then up to four name words ("... please? Some Name",
    /// "... <Some Guild>"), or, for a header row, the same header with nothing but such
    /// words where `line` has what was said. Only this way round: a row that reads WITH a
    /// name later is the row with a name behind it, and what went out stands.
    private func hadWorldText(_ was: String, where line: FrameLine) -> Bool {
        guard was != line.text else { return false }
        let words = was.split(separator: " ")
        for n in 1...4 where words.count > n {
            let name = words.suffix(n).joined(separator: " ")
            guard ChatTracker.readsLikeAName(name) else { continue }
            let rest = words.dropLast(n).joined(separator: " ")
            let key = LineKey(text: rest, parsed: ChatLineParser.parse(rest, locale: locale, color: line.color))
            guard key.hasHeader == line.key.hasHeader else { continue }
            // Behind the end of the row: the row is what stood in front of the name, give or
            // take a glyph, and nothing more (the same row read with its last word spelt
            // differently is no row without a name).
            if line.key.count <= key.count + 1, LineSimilarity.isSameMessage(key, line.key) { return true }
            // Over the last words of the row: the row begins with what stood in front of
            // the name and goes on with something that is nothing like the name (and not the
            // name with a glyph read differently).
            let more = Array(line.key.body.dropFirst(key.body.count)), named = TextFold.skeleton(name)
            if key.tag == line.key.tag, key.name == line.key.name, key.body.count >= 6, more.count >= 3,
               line.key.body.starts(with: key.body),
               TextFold.distance(more, named, limit: max(1, max(more.count, named.count) / 2)) == nil { return true }
        }
        guard line.parsed.hasPrefix, !line.parsed.headerBroken, !line.parsed.body.isEmpty else { return false }
        let old = ChatLineParser.parse(was, locale: locale, color: line.color)
        guard old.hasPrefix, !old.headerBroken, !old.body.isEmpty,
              ChatTracker.readsLikeAName(old.body), !ChatTracker.readsLikeAName(line.parsed.body) else { return false }
        // The same speaker on the same channel, with nothing of the two bodies in common
        // (not the same words in another case or with a glyph read differently).
        let named = TextFold.bodySkeleton(old.body), said = line.key.body
        guard TextFold.distance(named, said, limit: max(1, max(named.count, said.count) / 2)) == nil else { return false }
        let head = ParsedChatLine(timestamp: nil, channel: old.channel, channelLabel: nil, sender: nil, body: "", hasPrefix: true,
                                  headerTag: old.headerTag, headerName: old.headerName)
        let mine = ParsedChatLine(timestamp: nil, channel: line.parsed.channel, channelLabel: nil, sender: nil, body: "", hasPrefix: true,
                                  headerTag: line.parsed.headerTag, headerName: line.parsed.headerName)
        return LineSimilarity.isSameMessage(LineKey(text: "", parsed: head), LineKey(text: "", parsed: mine))
    }

    /// True when the window did not scroll since the previous frame and another line now sits on
    /// the row where `head` was: the same pixels, read differently.
    private func rowWasReread(_ head: Entry) -> Bool {
        guard lineHeight > 0, let shift = frameShift, head.lastSeenFrame == frameNo - 1 else { return false }
        // A damaged header is expected to be re-read: its row is followed through a scroll.
        guard abs(shift) < 0.5 * lineHeight || head.parsed.headerBroken else { return false }
        return history.contains {
            $0.lastSeenFrame == frameNo && $0 !== head && abs($0.box.midY - head.box.midY - shift) < 0.5 * lineHeight
        }
    }

    /// A message seen in a single frame only is reported when it reads like real chat and is not
    /// a garbled re-read of something already reported.
    private func isCredible(_ range: ClosedRange<Int>, recentCount: Int) -> Bool {
        let entries = range.map { history[$0] }
        guard entries.allSatisfy({ $0.confidence >= 0.45 }) else { return false }
        let (text, parsed) = assemble(entries)
        guard parsed.hasPrefix, !parsed.headerBroken, parsed.sender != nil, !parsed.body.isEmpty else { return false }
        let key = LineKey(text: text, parsed: parsed)
        return !recent.prefix(recentCount).contains { LineSimilarity.compare(key, $0) != .none }
    }

    /// The rows as one text. A row in `eliding` stands in it as "…": no read of it could be
    /// trusted (a header row keeps its header).
    private func assemble(_ entries: [Entry], eliding: [Entry] = []) -> (text: String, parsed: ParsedChatLine) {
        var text = ""
        for e in entries {
            var piece = e.text
            if eliding.contains(where: { $0 === e }) {
                let body = e.parsed.body
                if e === entries.first, e.parsed.hasPrefix, !body.isEmpty, e.text.hasSuffix(body) {
                    piece = String(e.text.dropLast(body.count)) + "…"
                } else if text.hasSuffix("…") {
                    continue
                } else {
                    piece = "…"
                }
            }
            if text.isEmpty { text = piece; continue }
            // Chinese and Japanese wrap between any two characters; everything else at a space.
            let glue = text.unicodeScalars.last.map(ChatTracker.isSpaceless) == true
                && piece.unicodeScalars.first.map(ChatTracker.isSpaceless) == true
            text += glue ? piece : " " + piece
        }
        var parsed = ChatLineParser.parse(text, locale: locale, color: entries.first?.color)
        // A link bracket read as a thin letter, where the brackets that were read leave no
        // doubt about it (only a whole message tells: a row may begin or end inside a link).
        if parsed.hasPrefix, entries.count > 1 || ChatLinks.hasBrackets(parsed.body), text.hasSuffix(parsed.body) {
            let mended = ChatLinks.mendBrackets(inBody: parsed.body)
            if mended != parsed.body {
                text = String(text.dropLast(parsed.body.count)) + mended
                parsed = ChatLineParser.parse(text, locale: locale, color: entries.first?.color)
            }
        }
        return (text, parsed)
    }

    private static func isSpaceless(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return (v >= 0x3040 && v <= 0x30FF) || (v >= 0x3400 && v <= 0x4DBF) || (v >= 0x4E00 && v <= 0x9FFF)
            || (v >= 0x3000 && v <= 0x303F) || (v >= 0xFF00 && v <= 0xFF60)
    }

    /// Ids of the messages a message made of `entries` stands in for: those its lines went
    /// out in while part of them could not be read, and the one its first line was reported
    /// as before (a line is reported a second time only when it has turned out to read as
    /// something else: one row of the chat is one line of the list).
    private func earlierReports(of entries: [Entry]) -> [UUID] {
        var ids: [UUID] = []
        for (n, e) in entries.enumerated() where e.provisional || n == 0 {
            if let id = e.messageID, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// Hands `message` out and notes on its lines that they went out in it.
    private func send(_ message: ChatMessage, lines: [Entry], spoken: [Entry], key: LineKey?, provisional: Bool,
                      into out: inout [ChatMessage]) {
        let earlier = earlierReports(of: lines)
        for e in lines {
            e.messageID = message.id
            e.provisional = provisional
            e.unsure = false
            e.emittedKey = nil
            e.shed = false
            e.shedSightings = 0
            e.reportedText = nil
            e.reportedKey = nil
        }
        lines.first?.emittedKey = key
        for e in spoken {
            e.reported = true
            e.reportedConfidence = e.confidence
            e.reportedFrame = frameNo
            if !e.withheld { e.reportedText = e.text; e.reportedKey = e.key }
        }
        if let key { recent.append(key) }
        if !earlier.isEmpty { latestCorrections[message.id] = earlier }
        out.append(message)
    }

    /// Whether the tag of a damaged header row can be shown as the channel of what stands
    /// under it. A numbered tag that never closes, or one with a label of the game's menu in
    /// it, names no channel: what reads as its name is whatever is drawn over the row.
    private func namesItsChannel(_ head: Entry) -> Bool {
        guard head.parsed.hasPrefix, !head.parsed.unclosedTag else { return false }
        return head.parsed.channelLabel.flatMap { ChatMenu.labelInside($0, locale: locale) } == nil
    }

    /// Rows of chat without their header row, as a message with no speaker: under the channel
    /// of the header (`head`, when its tag at least was read) or the one their colour says.
    /// `head` nil: rows that never had a header row to stand under.
    private func reportRows(_ rows: [Entry], under head: Entry?, into out: inout [ChatMessage], recentCount: Int) {
        guard let first = rows.first else { return }
        let lines = (head.map { [$0] } ?? []) + rows
        lines.forEach { $0.done = true; $0.tentative = false }
        let unsteady = rows.filter(isChurning)
        let (body, _) = assemble(rows, eliding: unsteady)
        let tagged = head.map(namesItsChannel) ?? false
        let label = tagged ? head?.parsed.channelLabel : nil
        let raw = (label.map { "[\($0)] " } ?? "") + body
        // Without a readable tag the colour of the rows says which channel they are.
        var channel = (tagged ? head?.parsed.channel : nil) ?? ChatColors.channel(for: first.color) ?? .unknown
        if channel == .system || channel == .emote { channel = .unknown }
        let parsed = ParsedChatLine(timestamp: nil, channel: channel, channelLabel: label,
                                    sender: nil, body: body, hasPrefix: true)
        let key = LineKey(text: raw, parsed: parsed)
        // Said before, by itself or as part of a message that went out whole: rows of old chat
        // read again without their header row (something is drawn over it) are no news.
        if recent.prefix(recentCount).contains(where: { LineSimilarity.isSameMessage(key, $0) || LineSimilarity.isPart(key, of: $0) }) {
            // The rows stay unsaid, and the message stays open: somebody else may have ended on
            // the same words. A clean read of the header row takes it up again, and it goes
            // out whole unless that very message is out already (`revived`).
            if let head {
                head.provisional = true
                head.revived = true
            }
            return
        }
        head?.withheld = true
        unsteady.forEach { $0.withheld = true }
        send(ChatMessage(channel: channel, channelLabel: label, sender: nil, body: body, rawText: raw,
                         color: first.color, firstSeen: (head ?? first).firstSeen, isFragment: true),
             lines: lines, spoken: rows, key: key, provisional: true, into: &out)
    }

    /// `inDoubt`: the wait for a better read of the message has run out with its header row
    /// still damaged or one of its rows still reading differently from frame to frame.
    private func report(_ range: ClosedRange<Int>, skipping: Set<Int> = [], into out: inout [ChatMessage],
                        recentCount: Int, inDoubt: Bool = false) {
        let entries = range.filter { !skipping.contains($0) }.map { history[$0] }
        guard let head = entries.first else { return }
        entries.forEach { $0.done = true; $0.tentative = false }
        // A row that opens with a bracketed word and is no header may also be a notice in a
        // format unknown here ("[Name] is away: ..."): it goes out as it reads, as a line of no
        // channel, which is never translated.
        if head.parsed.headerBroken, head.covered || head.parsed.hasPrefix || ChatLineParser.opensLikeHeader(head.text),
           !readsLikeSpeech(head) {
            // No clean read of the header row came in time. What stands behind its tag is not
            // known to be chat and is never passed on; the wrapped rows below it are, and go
            // out under the channel alone unless they were part of a message already.
            let rows = entries.dropFirst().filter { !$0.reported }
            if !rows.isEmpty, rows.count == entries.count - 1 {
                reportRows(Array(rows), under: head, into: &out, recentCount: recentCount)
            } else if entries.count == 1, head.messageID == nil {
                // A message of one row: all that is known is that something was said there.
                let label = namesItsChannel(head) ? head.parsed.channelLabel : nil
                let raw = (label.map { "[\($0)] " } ?? "") + ChatTracker.unreadableNotice
                head.withheld = true
                send(ChatMessage(channel: .unknown, channelLabel: label, sender: nil, body: ChatTracker.unreadableNotice,
                                 rawText: raw, color: ChatTracker.noticeColour, firstSeen: head.firstSeen),
                     lines: entries, spoken: [], key: nil, provisional: true, into: &out)
            }
            return
        }
        let earlier = earlierReports(of: entries)
        // The rows under this header went out without it when it could not be read in time,
        // as part of another message: what was said is known already, and saying it twice
        // helps nobody.
        if !head.reported, entries.count > 1, entries.dropFirst().allSatisfy(\.reported), earlier.isEmpty { return }
        let unsteady = inDoubt ? entries.filter(isChurning) : []
        let (text, parsed) = assemble(entries, eliding: unsteady)
        let key = LineKey(text: text, parsed: parsed)
        // A hidden row right below may be one more row of this message.
        let hiddenBelow = range.upperBound + 1 < history.count && history[range.upperBound + 1].covered
        // A row OCR was unsure of may be the row with something drawn over it: a later read
        // it is sure of takes this one's place.
        let unsure = entries.contains { $0.confidence < ChatTracker.sureRead }
        // A row that has shed a name is said again however little the name was.
        let shed = entries.contains(where: \.shed)
        entries.forEach { $0.shed = false }
        if !earlier.isEmpty, !shed, let said = head.emittedKey, LineSimilarity.isSameMessage(key, said) {
            // The second look says what the first did: that report stands.
            entries.forEach { $0.provisional = hiddenBelow || unsure }
            head.unsure = unsure && !hiddenBelow
            return
        }
        // Lines that arrived outside the live flow may be old chat laid out differently (window
        // resized, other tab) or read differently (something drawn over part of it): the same
        // message is not reported a second time, whether it reads as all of what went out or
        // as its first row alone, under a tag that reads as something else.
        if (head.wasTentative && !head.afterFade) || head.revived,
           recent.prefix(recentCount).contains(where: {
               LineSimilarity.isSameMessage(key, $0) || LineSimilarity.isReRead(key, of: $0) || LineSimilarity.isReRead(head.key, of: $0)
           }) {
            return
        }
        // A second report must be the better one: what went out as language is not replaced by
        // what OCR makes of text it could not read this time, however sure it claims to be.
        if !earlier.isEmpty, LanguageGate.isUnreadable(parsed.body), !parsed.body.isEmpty,
           let was = head.reportedText.map({ ChatLineParser.parse($0, locale: locale, color: head.color) }),
           was.hasPrefix, !was.body.isEmpty, !LanguageGate.isUnreadable(was.body) {
            return
        }
        unsteady.forEach { $0.withheld = true }
        let sender = parsed.sender.map { senders.resolve($0) }
        let doubted = inDoubt || head.parsed.headerBroken || !unsteady.isEmpty || hiddenBelow
        send(ChatMessage(channel: parsed.channel, channelLabel: parsed.channelLabel, sender: sender,
                         body: parsed.body, rawText: text, color: head.color, firstSeen: head.firstSeen),
             lines: entries, spoken: entries, key: key, provisional: doubted || unsure, into: &out)
        head.unsure = unsure && !doubted
    }

    /// One line per known screen line with what the tracker believes about it, oldest first.
    /// For tests and for looking at a replay; nothing in the app reads it.
    func debugSnapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return history.enumerated().map { i, e in
            var flags: [String] = []
            if e.isStart { flags.append("start") }
            if e.gapBefore { flags.append("gap") }
            if e.tentative { flags.append("tentative") }
            if e.done { flags.append("done") }
            if e.reported { flags.append("reported") }
            if e.parsed.headerBroken { flags.append("damaged") }
            if e.contested { flags.append("contested") }
            if isChurning(e) { flags.append("churning") }
            if e.orphan { flags.append("orphan") }
            if e.covered { flags.append("covered") }
            if e.provisional { flags.append("provisional") }
            if e.withheld { flags.append("withheld") }
            return "\(i) born=\(e.bornFrame) seen=\(e.lastSeenFrame) votes=\(e.votes) exact=\(e.exact) streak=\(e.streak) "
                + "conf=\(e.confidence) [\(flags.joined(separator: ","))] |\(e.text)|"
        }
    }

    private func prune() {
        if recent.count > ChatTracker.maxRecent { recent.removeFirst(recent.count - ChatTracker.maxRecent) }
        guard history.count > ChatTracker.maxHistory else { return }
        var drop = history.count - ChatTracker.keepHistory
        // Never forget a line that is still waiting to be reported.
        if let firstOpen = history.firstIndex(where: { !$0.done }) { drop = min(drop, firstOpen) }
        guard drop > 0 else { return }
        history.removeFirst(drop)
        history.first?.gapBefore = true
    }
}
