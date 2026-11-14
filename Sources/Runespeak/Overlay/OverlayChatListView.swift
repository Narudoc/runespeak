import AppKit
import RunespeakCore

/// Text view that draws its text at a caller-chosen vertical offset, so a short chat log sits at the
/// bottom of the panel like the game's own chat frame.
private final class OverlayChatTextView: NSTextView {
    var contentOrigin = NSPoint.zero {
        didSet {
            guard contentOrigin != oldValue else { return }
            invalidateTextContainerOrigin()
            needsDisplay = true
        }
    }
    var menuProvider: ((NSPoint) -> NSMenu?)?

    override var textContainerOrigin: NSPoint { contentOrigin }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Swallow left clicks: nothing to select or edit, and NSTextView's own handling would try to
    // make the (never-key) panel key.
    override func mouseDown(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(convert(event.locationInWindow, from: nil))
    }
    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .arrow)
    }
}

private final class OverlayPillButton: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.92).cgColor
        layer?.borderColor = NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.3, alpha: 0.7).cgColor
        layer?.borderWidth = 1
        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(calibratedRed: 1, green: 0.86, blue: 0.4, alpha: 1)
        addSubview(label)
        label.sizeToFit()
        setFrameSize(NSSize(width: label.frame.width + 16, height: label.frame.height + 6))
        label.setFrameOrigin(NSPoint(x: 8, y: 3))
        layer?.cornerRadius = frame.height / 2
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// The scrolling chat log of the overlay: bottom-anchored, newest line last, one paragraph per entry.
@MainActor
final class OverlayChatListView: NSView {
    struct Hover {
        let entry: ChatEntry
        /// Bounds of the entry's lines, in this view's coordinates.
        let rect: NSRect
    }

    /// Called for a right click; the argument is the entry under the pointer, nil for empty space.
    var menuProvider: ((ChatEntry?) -> NSMenu?)?
    /// The user scrolled the log (wheel or scroller).
    var onUserScroll: (() -> Void)?

    private let scrollView = NSScrollView()
    private let textView: OverlayChatTextView
    private let jumpButton = OverlayPillButton(title: "↓ 최신 채팅")

    /// Everything in the text storage, oldest first: `retiredCount` lines the app has already
    /// trimmed from its history, then the lines last passed to `update`.
    private var entries: [ChatEntry] = []
    private var retiredCount = 0
    private static let retiredLimit = 100
    /// UTF-16 length of each entry's paragraph (without its newline) and where it starts in the storage.
    private var lineLengths: [Int] = []
    private var lineStarts: [Int] = []
    private var cachedStyle: LineStyle?
    private var fontSize: CGFloat = 14
    private var pinnedToBottom = true
    private var isAdjustingScroll = false
    private let verticalPadding: CGFloat = 4

    override init(frame frameRect: NSRect) {
        // Explicit TextKit 1 stack: glyph-level hit testing below relies on NSLayoutManager.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 6
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        textView = OverlayChatTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textView.textContainerInset = .zero
        textView.menuProvider = { [weak self] point in self?.menu(atTextViewPoint: point) }

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        jumpButton.isHidden = true
        jumpButton.onClick = { [weak self] in self?.scrollToNewest() }
        addSubview(jumpButton)

        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Content

    func update(entries newEntries: [ChatEntry], fontSize newFontSize: CGFloat) {
        guard newFontSize != fontSize || !entries[retiredCount...].elementsEqual(newEntries) else { return }
        let anchor = pinnedToBottom ? nil : topVisibleAnchor()
        if newFontSize != fontSize || !applyIncrementally(newEntries) {
            entries = newEntries
            retiredCount = 0
            fontSize = newFontSize
            rebuildText()
        }
        relayout(restoring: anchor)
    }

    func scrollToNewest() {
        pinnedToBottom = true
        relayout(restoring: nil)
    }

    private struct LineStyle {
        let fontSize: CGFloat
        let base: [NSAttributedString.Key: Any]
        let warningFont: NSFont

        init(fontSize: CGFloat) {
            self.fontSize = fontSize
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.paragraphSpacing = max(1, fontSize * 0.14)
            paragraph.lineHeightMultiple = 1.04
            // Same trick the game uses: a tight dark shadow keeps coloured text readable on any backdrop.
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.95)
            shadow.shadowOffset = NSSize(width: 1, height: -1)
            shadow.shadowBlurRadius = 1.5
            base = [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .paragraphStyle: paragraph, .shadow: shadow]
            warningFont = NSFont.systemFont(ofSize: max(9, fontSize * 0.85), weight: .medium)
        }
    }

    private var lineStyle: LineStyle {
        if let cachedStyle, cachedStyle.fontSize == fontSize { return cachedStyle }
        let style = LineStyle(fontSize: fontSize)
        cachedStyle = style
        return style
    }

    /// One entry as one paragraph, without the trailing newline.
    private func attributedLine(for entry: ChatEntry, style: LineStyle) -> NSAttributedString {
        let color = entry.message.color.overlayNSColor
        let line = NSMutableAttributedString()
        func append(_ text: String, _ textColor: NSColor, font: NSFont? = nil) {
            var attributes = style.base
            attributes[.foregroundColor] = textColor
            if let font { attributes[.font] = font }
            line.append(NSAttributedString(string: text, attributes: attributes))
        }
        let prefix = OverlayChatFormat.prefix(for: entry.message)
        switch entry.state {
        case .translated(let text):
            append(prefix + Self.singleLine(text), color)
        case .original:
            append(Self.singleLine(OverlayChatFormat.originalLine(for: entry.message)), color)
        case .pending:
            append(prefix + Self.singleLine(entry.message.body), color.withAlphaComponent(0.55))
            append("  ⋯", NSColor.white.withAlphaComponent(0.5))
        case .failed:
            append(prefix + Self.singleLine(entry.message.body), color.withAlphaComponent(0.85))
            append("  ⚠", NSColor(calibratedRed: 1, green: 0.78, blue: 0.2, alpha: 1), font: style.warningFont)
        }
        return line
    }

    private func rebuildText() {
        let style = lineStyle
        let newline = NSAttributedString(string: "\n", attributes: style.base)
        let result = NSMutableAttributedString()
        lineLengths.removeAll(keepingCapacity: true)
        for (index, entry) in entries.enumerated() {
            if index > 0 { result.append(newline) }
            let line = attributedLine(for: entry, style: style)
            lineLengths.append(line.length)
            result.append(line)
        }
        recomputeLineStarts()
        textView.textStorage?.setAttributedString(result)
    }

    /// The usual changes — a new line at the bottom, the oldest lines trimmed off the top, one line's
    /// translation arriving — edit only the affected paragraphs, so the layout of the other few
    /// hundred lines is reused. Returns false when the change has another shape (caller rebuilds).
    private func applyIncrementally(_ newEntries: [ChatEntry]) -> Bool {
        let live = entries[retiredCount...]
        guard let storage = textView.textStorage, let firstNew = newEntries.first,
              let firstKept = live.firstIndex(where: { $0.id == firstNew.id }) else { return false }
        let kept = entries.count - firstKept
        guard kept <= newEntries.count else { return false }
        for i in 0..<kept where entries[firstKept + i].id != newEntries[i].id { return false }

        let style = lineStyle
        storage.beginEditing()
        // Deleting at the top makes TextKit lay out every line below again (tens of ms with a full
        // history), and once the history is at its cap that would happen for each new chat line.
        // So lines trimmed by the app stay in the log as plain scroll-back and are cut in batches.
        var firstLive = firstKept
        if firstLive > Self.retiredLimit {
            storage.deleteCharacters(in: NSRange(location: 0, length: lineStarts[firstLive]))
            lineLengths.removeFirst(firstLive)
            recomputeLineStarts()
            entries.removeFirst(firstLive)
            firstLive = 0
        }
        // Back to front, so the offsets of the lines still to be visited stay valid.
        for i in stride(from: kept - 1, through: 0, by: -1) where entries[firstLive + i] != newEntries[i] {
            let index = firstLive + i
            let line = attributedLine(for: newEntries[i], style: style)
            storage.replaceCharacters(in: NSRange(location: lineStarts[index], length: lineLengths[index]), with: line)
            lineLengths[index] = line.length
        }
        if kept < newEntries.count {
            let newline = NSAttributedString(string: "\n", attributes: style.base)
            for entry in newEntries[kept...] {
                let line = attributedLine(for: entry, style: style)
                storage.append(newline)
                storage.append(line)
                lineLengths.append(line.length)
            }
        }
        storage.endEditing()
        entries.replaceSubrange(firstLive..., with: newEntries)
        retiredCount = firstLive
        recomputeLineStarts()
        return true
    }

    private func recomputeLineStarts() {
        lineStarts.removeAll(keepingCapacity: true)
        var offset = 0
        for length in lineLengths {
            lineStarts.append(offset)
            offset += length + 1
        }
    }

    /// Index of the entry whose paragraph (including its newline) contains `character`.
    private func entryIndex(forCharacter character: Int) -> Int? {
        var low = 0, high = lineStarts.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if character < lineStarts[mid] {
                high = mid - 1
            } else if character > lineStarts[mid] + lineLengths[mid] {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    /// One entry must stay one paragraph, otherwise hit testing would split it.
    private static func singleLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        jumpButton.setFrameOrigin(NSPoint(x: bounds.maxX - jumpButton.frame.width - 10, y: 6))
        relayout(restoring: pinnedToBottom ? nil : topVisibleAnchor())
    }

    private func relayout(restoring anchor: (entryID: UUID, offset: CGFloat)?) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let clip = scrollView.contentView
        let width = max(clip.bounds.width, 20)
        let clipHeight = clip.bounds.height

        isAdjustingScroll = true
        defer { isAdjustingScroll = false }

        // Assigning the size invalidates the whole layout even when it is unchanged.
        let containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if container.size != containerSize { container.size = containerSize }
        layoutManager.ensureLayout(for: container)
        let textHeight = entries.isEmpty ? 0 : ceil(layoutManager.usedRect(for: container).height)
        let documentHeight = max(textHeight + verticalPadding * 2, clipHeight)
        let documentFrame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        if textView.frame != documentFrame { textView.frame = documentFrame }
        textView.contentOrigin = NSPoint(x: 0, y: documentHeight - textHeight - verticalPadding)

        let maxOffset = max(0, documentHeight - clipHeight)
        var target = maxOffset
        if !pinnedToBottom {
            if let anchor, let index = entries.firstIndex(where: { $0.id == anchor.entryID }),
               let rect = entryRect(at: index) {
                target = rect.minY - anchor.offset
            } else {
                target = clip.bounds.origin.y
            }
            target = min(max(0, target), maxOffset)
            // Nothing left below the visible part: behave as "at the newest line" again.
            if maxOffset - target < 2 { pinnedToBottom = true }
        }
        if abs(clip.bounds.origin.y - target) > 0.01 {
            clip.setBoundsOrigin(NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(clip)
        }
        jumpButton.isHidden = pinnedToBottom
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        guard !isAdjustingScroll else { return }
        onUserScroll?()
        let clip = scrollView.contentView
        let distance = textView.frame.height - clip.bounds.maxY
        pinnedToBottom = distance < 6
        jumpButton.isHidden = pinnedToBottom
    }

    /// First entry intersecting the top of the visible area, to keep it in place when lines are
    /// appended (or old ones trimmed) while the user is reading further up.
    private func topVisibleAnchor() -> (entryID: UUID, offset: CGFloat)? {
        let visibleTop = scrollView.contentView.bounds.minY
        guard let index = entryIndex(atTextViewPoint: NSPoint(x: 10, y: visibleTop + 2), strict: false),
              let rect = entryRect(at: index) else { return nil }
        return (entries[index].id, rect.minY - visibleTop)
    }

    // MARK: Hit testing

    /// Rect of entry `index` in text-view coordinates.
    private func entryRect(at index: Int) -> NSRect? {
        guard index >= 0, index < lineStarts.count,
              let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        let range = NSRange(location: lineStarts[index], length: lineLengths[index])
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x = 0
        rect.size.width = textView.bounds.width
        return rect.offsetBy(dx: 0, dy: textView.contentOrigin.y)
    }

    /// `strict`: the point must lie on one of the entry's lines (not in the padding above/below the text).
    private func entryIndex(atTextViewPoint point: NSPoint, strict: Bool) -> Int? {
        guard !entries.isEmpty, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, let storage = textView.textStorage,
              layoutManager.numberOfGlyphs > 0 else { return nil }
        let local = NSPoint(x: point.x - textView.contentOrigin.x, y: point.y - textView.contentOrigin.y)
        let used = layoutManager.usedRect(for: container)
        if strict, local.y < 0 || local.y > used.maxY { return nil }
        let glyph = layoutManager.glyphIndex(for: local, in: container)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        if strict {
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            guard local.y >= fragment.minY, local.y <= fragment.maxY else { return nil }
        }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        return entryIndex(forCharacter: character)
    }

    /// Retired lines are scroll-back only: the app no longer knows them, so they get no menu or bubble.
    private func liveEntry(atTextViewPoint point: NSPoint) -> (index: Int, entry: ChatEntry)? {
        guard let index = entryIndex(atTextViewPoint: point, strict: true), index >= retiredCount else { return nil }
        return (index, entries[index])
    }

    private func menu(atTextViewPoint point: NSPoint) -> NSMenu? {
        return menuProvider?(liveEntry(atTextViewPoint: point)?.entry)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(nil)
    }

    /// Entry under a window-coordinate point, for the hover bubble.
    func hover(atWindowPoint windowPoint: NSPoint) -> Hover? {
        let inSelf = convert(windowPoint, from: nil)
        guard bounds.contains(inSelf), jumpButton.isHidden || !jumpButton.frame.contains(inSelf) else { return nil }
        let inText = textView.convert(windowPoint, from: nil)
        guard let hit = liveEntry(atTextViewPoint: inText), let rect = entryRect(at: hit.index) else { return nil }
        let visible = convert(rect, from: textView).intersection(bounds)
        guard !visible.isEmpty else { return nil }
        return Hover(entry: hit.entry, rect: visible)
    }

    // MARK: Test support

    var isPinnedToBottom: Bool { pinnedToBottom }
    var displayedText: String { textView.string }
}
