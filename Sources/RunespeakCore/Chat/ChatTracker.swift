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
/// Two situations look like a re-read and are not. A long message posted again makes the window
/// resemble an older stretch of the log; the line that history knows to be a different one gives
/// that away (`contradictsHistory`). And after the chat has faded out, a few lines alone on the
/// bottom rows are new chat even when the same words were said before (`isNewChatAfterFade`).
public final class ChatTracker: ChatTracking, @unchecked Sendable {

    // MARK: - Types

    private struct FrameLine {
        var text: String
        var parsed: ParsedChatLine
        var key: LineKey
        var color: RGBColor
        var box: CGRect
        var confidence: Double
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
        /// Appeared at the bottom of a window that had faded to empty: new chat even when it
        /// reads like something said before.
        var afterFade = false
        /// How many frames read the line as `text`, and the best-supported other reading.
        var votes = 1
        var rival: (line: FrameLine, votes: Int)?

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
    /// Empty frames in a row that count as "the chat has faded out", not as OCR missing a frame.
    private static let fadedAfterEmptyFrames = 3
    /// The game shows a line for two minutes by default. A line first seen longer ago than this
    /// is no longer on screen by itself; only scrolling or the mouse brings it back.
    private static let lineLifetime: TimeInterval = 150
    /// A read OCR is sure enough of to be taken at its word.
    private static let confidentRead = 0.45
    /// Most rows a frame has shown in the current layout.
    private var fullRows = 0

    private var senders = SenderMemory()

    public init(clientLocale: ClientLocale) {
        self.locale = clientLocale
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        senders.reset()
        history.removeAll()
        recent.removeAll()
        frameNo = 0
        lastViewFrame = 0
        rightLimit = 0
        leftEdge = .greatestFiniteMagnitude
        lineHeight = 0
        rowPitch = 0
        bottomRow = 0
        frameBottom = 0
        frameShift = nil
        fullRows = 0
    }

    // MARK: - Ingest

    public func ingest(_ frame: OCRFrame, now: Date) -> [ChatMessage] {
        lock.lock(); defer { lock.unlock() }
        frameNo += 1
        let lines = prepare(frame)
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

    private func prepare(_ frame: OCRFrame) -> [FrameLine] {
        var rows: [OCRLine] = []
        let sorted = frame.lines.enumerated()
            .filter { !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { a, b in
                let ya = a.element.box.midY, yb = b.element.box.midY
                return ya != yb ? ya < yb : a.offset < b.offset
            }
            .map(\.element)
        for line in sorted {
            // Two boxes on one text row are one screen line that OCR split at a wide gap.
            if let last = rows.last, ChatTracker.sameRow(last.box, line.box) {
                let leftFirst = last.box.minX <= line.box.minX
                let a = leftFirst ? last : line, b = leftFirst ? line : last
                var merged = a
                merged.text = a.text.trimmingCharacters(in: .whitespaces) + " " + b.text.trimmingCharacters(in: .whitespaces)
                merged.box = a.box.union(b.box)
                merged.color = a.box.width >= b.box.width ? a.color : b.color
                merged.confidence = min(a.confidence, b.confidence)
                rows[rows.count - 1] = merged
            } else {
                rows.append(line)
            }
        }
        return rows.compactMap { row in
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            let parsed = ChatLineParser.parse(text, locale: locale, color: row.color)
            let key = LineKey(text: text, parsed: parsed)
            guard key.count > 0 else { return nil }
            return FrameLine(text: text, parsed: parsed, key: key, color: row.color, box: row.box, confidence: row.confidence)
        }
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
            rowPitch = 0
            bottomRow = 0
            fullRows = 0
        }
        fullRows = max(fullRows, lines.count)
        frameBottom = lines.map(\.box.midY).max() ?? 0
        bottomRow = max(bottomRow, frameBottom)
        let heights = lines.map(\.box.height).filter { $0 > 0 }.sorted()
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
        for l in lines where l.box.width > 0 {
            rightLimit = max(rightLimit, l.box.maxX)
            leftEdge = min(leftEdge, l.box.minX)
        }
        // The dragged region is rarely much wider than the text area; this keeps a window that
        // so far only showed short lines from making every line look "full".
        if imageSize.width > 0 { rightLimit = max(rightLimit, imageSize.width * 0.55) }
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

    private func isConfidentHeader(_ line: FrameLine) -> Bool {
        line.parsed.hasPrefix && line.confidence >= ChatTracker.confidentRead
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
        for (i, step) in steps.enumerated() {
            guard case .match(let j, _) = step else { continue }
            taken.insert(j)
            let e = history[j]
            if e.lastSeenFrame == frameNo - 1 { samples.append((i, lines[i].box.midY - e.box.midY)) }
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
            if let j = history.indices.first(where: { j in
                let e = history[j]
                return e.lastSeenFrame == frameNo - 1 && !taken.contains(j) && abs(e.box.midY + shift - y) < 0.35 * lineHeight
                    && !isAnotherLine(lines[i], than: e)
            }) {
                taken.insert(j)
                steps[i] = .match(j, strict: false)
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
                e.box = line.box
                if e.tentative && e.sightings >= 2 { e.tentative = false }
                func adopt(_ l: FrameLine) {
                    e.text = l.text; e.parsed = l.parsed; e.key = l.key
                    e.color = l.color; e.confidence = l.confidence
                }
                if strict {
                    e.votes += 1
                    // Remember how the line usually reads, so that one odd first read does not
                    // weaken every later comparison; before it is reported, keep the best read.
                    if e.done ? line.confidence >= e.confidence : line.confidence > e.confidence + 0.05 { adopt(line) }
                } else {
                    // Same line by position, read differently. The reading most frames agree on
                    // wins; OCR's own confidence breaks the tie in favour of the newcomer.
                    var support = 1
                    if let r = e.rival, LineSimilarity.compare(r.line.key, line.key).isStrict { support = r.votes + 1 }
                    e.rival = (line, support)
                    let outvoted = support > e.votes || (support == e.votes && line.confidence > e.confidence + 0.05)
                    if outvoted {
                        let wasDistrusted = e.confidence < 0.4
                        let unrelated = LineSimilarity.compare(line.key, e.key) == .none
                        let old = FrameLine(text: e.text, parsed: e.parsed, key: e.key, color: e.color,
                                            box: e.box, confidence: e.confidence)
                        adopt(line)
                        e.rival = (old, e.votes)
                        e.votes = support
                        // Reported from a read OCR itself distrusted, and the row has since read
                        // as something else altogether: report the line again, properly this time.
                        if e.done, e.isStart, wasDistrusted, unrelated { e.done = false }
                    }
                }
                if !rowGap, previousMatchIndex == j - 1 || previousInsertBoundary == j { e.gapBefore = false }
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
                                          box: e.box.offsetBy(dx: 0, dy: shift), confidence: e.confidence)
                        unknownAbove = false
                    }
                }
                let entry = Entry(line, isStart: startsMessage(line, above: above),
                                  gapBefore: unknownAbove, tentative: !isLive, frame: frameNo, now: now)
                entry.afterFade = afterFade
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

    /// Whether `line` is the first screen line of a message, judged from the line above it.
    private func startsMessage(_ line: FrameLine, above: FrameLine?) -> Bool {
        if line.parsed.hasPrefix || line.parsed.timestamp != nil { return true }
        guard let above else {
            // Top of the window: a headerless line is normally the tail of a message whose first
            // line has scrolled out. System and emote lines are the exception.
            return line.parsed.channel == .system || line.parsed.channel == .emote
        }
        let hasGeometry = lineHeight > 0 && line.box.width > 0 && above.box.width > 0
        if hasGeometry, leftEdge < .greatestFiniteMagnitude, line.box.minX - leftEdge > 0.8 * lineHeight {
            return false    // indented continuation
        }
        if ChatColors.distance(line.color, above.color) > 0.35, !line.text.hasPrefix("[") {
            return true     // wrapped lines keep the colour of their message
        }
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
            } else if !e.gapBefore, !out.isEmpty, out[out.count - 1].end == i - 1 {
                out[out.count - 1].end = i
            } else {
                out.append(Group(start: i, end: i, isMessage: false))
            }
        }
        return out
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

        for g in groups() {
            let range = g.start...g.end
            if !g.isMessage {
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
                // Late lines of a message that was already reported are swallowed.
                for i in range {
                    let e = history[i]
                    if e.tentative && e.lastSeenFrame != frameNo { remove.insert(i) } else { e.done = true }
                }
                continue
            }
            let seenNow = range.contains { history[$0].lastSeenFrame == frameNo }
            let inside = anchored && g.start > seenLo && g.end < seenHi
            let vanishedAtBottom = anchored && g.start == seenHi + 1 && !head.gapBefore && bottomInPlace
            let next = g.end + 1
            // Another message is known to start right below this one, so it is complete.
            let closed = next < history.count && history[next].isStart && !history[next].gapBefore
                && !history[next].tentative

            if !seenNow {
                if head.tentative {
                    if inside || vanishedAtBottom || !isCredible(range, recentCount: recentBefore) {
                        range.forEach { remove.insert($0) }
                    } else {
                        report(range, into: &emitted, recentCount: recentBefore)
                    }
                } else if vanishedAtBottom || rowWasReread(head) {
                    // Shown for one frame as the newest line, then gone (or read as something
                    // else) while its neighbours stayed put: a misread, not chat.
                    range.forEach { remove.insert($0) }
                } else if inside && !closed && frameNo - head.bornFrame < ChatTracker.maxHoldFrames {
                    // OCR skipped it this once, and what follows it is not known to be the next
                    // message: its last line may still be missing.
                } else {
                    // Scrolled out of view, or complete. Unconfirmed extra lines go.
                    for i in range where history[i].tentative { remove.insert(i) }
                    report(range, skipping: remove, into: &emitted, recentCount: recentBefore)
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
            // A read OCR itself distrusts gets a few frames to be replaced by a better one,
            // unless it keeps coming out the same.
            if live.contains(where: { history[$0].confidence < 0.4 && history[$0].votes < 3 }),
               frameNo - head.bornFrame < ChatTracker.maxDistrustFrames {
                continue
            }
            if closed || settled {
                report(range, skipping: remove, into: &emitted, recentCount: recentBefore)
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

    /// True when the window did not scroll since the previous frame and another line now sits on
    /// the row where `head` was: the same pixels, read differently.
    private func rowWasReread(_ head: Entry) -> Bool {
        guard lineHeight > 0, let shift = frameShift, abs(shift) < 0.5 * lineHeight,
              head.lastSeenFrame == frameNo - 1 else { return false }
        return history.contains {
            $0.lastSeenFrame == frameNo && $0 !== head && abs($0.box.midY - head.box.midY) < 0.5 * lineHeight
        }
    }

    /// A message seen in a single frame only is reported when it reads like real chat and is not
    /// a garbled re-read of something already reported.
    private func isCredible(_ range: ClosedRange<Int>, recentCount: Int) -> Bool {
        let entries = range.map { history[$0] }
        guard entries.allSatisfy({ $0.confidence >= 0.45 }) else { return false }
        let (text, parsed) = assemble(entries)
        guard parsed.hasPrefix, parsed.sender != nil, !parsed.body.isEmpty else { return false }
        let key = LineKey(text: text, parsed: parsed)
        return !recent.prefix(recentCount).contains { LineSimilarity.compare(key, $0) != .none }
    }

    private func assemble(_ entries: [Entry]) -> (text: String, parsed: ParsedChatLine) {
        var text = ""
        for e in entries {
            if text.isEmpty { text = e.text; continue }
            // Chinese and Japanese wrap between any two characters; everything else at a space.
            let glue = text.unicodeScalars.last.map(ChatTracker.isSpaceless) == true
                && e.text.unicodeScalars.first.map(ChatTracker.isSpaceless) == true
            text += glue ? e.text : " " + e.text
        }
        return (text, ChatLineParser.parse(text, locale: locale, color: entries.first?.color))
    }

    private static func isSpaceless(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return (v >= 0x3040 && v <= 0x30FF) || (v >= 0x3400 && v <= 0x4DBF) || (v >= 0x4E00 && v <= 0x9FFF)
            || (v >= 0x3000 && v <= 0x303F) || (v >= 0xFF00 && v <= 0xFF60)
    }

    private func report(_ range: ClosedRange<Int>, skipping: Set<Int> = [], into out: inout [ChatMessage], recentCount: Int) {
        let entries = range.filter { !skipping.contains($0) }.map { history[$0] }
        guard let head = entries.first else { return }
        entries.forEach { $0.done = true; $0.tentative = false }
        let (text, parsed) = assemble(entries)
        let key = LineKey(text: text, parsed: parsed)
        // Lines that arrived outside the live flow may be old chat laid out differently (window
        // resized, other tab): the same message is not reported a second time.
        if head.wasTentative, !head.afterFade,
           recent.prefix(recentCount).contains(where: { LineSimilarity.isSameMessage(key, $0) }) {
            return
        }
        recent.append(key)
        let sender = parsed.sender.map { senders.resolve($0) }
        out.append(ChatMessage(channel: parsed.channel, channelLabel: parsed.channelLabel, sender: sender,
                               body: parsed.body, rawText: text, color: head.color, firstSeen: head.firstSeen))
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
