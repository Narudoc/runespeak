import AppKit
import RunespeakCore

// MARK: - Panel

/// Borderless panel that floats over the game and never takes keyboard focus from it.
final class OverlayPanel: NSPanel {
    /// `sharingType` has to be decided here, before the window exists on the window server:
    /// see `OverlayController.replacePanel`.
    init(contentRect: NSRect, sharingType: NSWindow.SharingType) {
        // .nonactivatingPanel must be part of the initial style mask; adding it later does not
        // reliably stop clicks from activating the app.
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        self.sharingType = sharingType
        isFloatingPanel = true
        level = OverlayController.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        // "가리기" (⌘H) is for the history window; the cover belongs to the game and stays.
        canHide = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        // The panel is always dark; without this a legacy ("always show") scroller draws a white track.
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        isRestorable = false
        title = "Runespeak 겹침 창"
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // The chat frame may sit under the menu bar line or partly off-screen; never let AppKit nudge us.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - Tab strip

private final class OverlayTabChip: NSView {
    let group: ChannelGroup
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    var onToggle: (() -> Void)?

    static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)

    init(group: ChannelGroup) {
        self.group = group
        super.init(frame: .zero)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(group.koreanTitle)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var naturalWidth: CGFloat {
        ceil((group.koreanTitle as NSString).size(withAttributes: [.font: Self.font]).width) + 16
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 2.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let gold = NSColor(calibratedRed: 1, green: 0.82, blue: 0.3, alpha: 1)
        if isOn {
            gold.withAlphaComponent(0.2).setFill()
            path.fill()
            gold.withAlphaComponent(0.65).setStroke()
        } else {
            NSColor.white.withAlphaComponent(0.14).setStroke()
        }
        path.lineWidth = 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: isOn ? gold : NSColor.white.withAlphaComponent(0.42),
            .paragraphStyle: paragraph,
        ]
        let title = group.koreanTitle as NSString
        let height = title.size(withAttributes: attributes).height
        title.draw(in: NSRect(x: 3, y: (bounds.height - height) / 2, width: bounds.width - 6, height: height),
                   withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        // A press that turns into a drag moves the panel; a plain click toggles the tab.
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { onToggle?() }
                return
            }
            let dx = next.locationInWindow.x - start.x, dy = next.locationInWindow.y - start.y
            if dx * dx + dy * dy > 16 {
                window.performDrag(with: event)
                return
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { superview?.menu(for: event) }

    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { onToggle?(); return true }
}

/// Top bar: one toggle per channel group; dragging it moves the panel.
final class OverlayTabStripView: NSView {
    var onToggle: ((ChannelGroup) -> Void)?
    private let chips: [OverlayTabChip]

    override init(frame frameRect: NSRect) {
        chips = ChannelGroup.allCases.map(OverlayTabChip.init(group:))
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.55).cgColor
        for chip in chips {
            chip.onToggle = { [weak self, group = chip.group] in self?.onToggle?(group) }
            addSubview(chip)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setEnabledGroups(_ groups: Set<ChannelGroup>) {
        for chip in chips { chip.isOn = groups.contains(chip.group) }
    }

    func isOn(_ group: ChannelGroup) -> Bool { chips.first { $0.group == group }?.isOn ?? false }

    /// Chip frame in this view's coordinates (test harness).
    func chipFrame(_ group: ChannelGroup) -> NSRect { chips.first { $0.group == group }?.frame ?? .zero }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let gap: CGFloat = 4, inset: CGFloat = 6
        let natural = chips.map(\.naturalWidth)
        let available = max(0, bounds.width - inset * 2 - gap * CGFloat(chips.count - 1))
        let total = natural.reduce(0, +)
        // Narrow chat frames: shrink every chip by the same ratio (titles truncate).
        let scale = total > available && total > 0 ? available / total : 1
        var x = inset
        for (chip, width) in zip(chips, natural) {
            let w = floor(width * scale)
            chip.frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
            x += w + gap
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    // Asked explicitly rather than relying on the right click bubbling up the responder chain.
    override func menu(for event: NSEvent) -> NSMenu? { superview?.menu(for: event) }
}

// MARK: - Compose strip

/// Looks like the game's chat edit box; clicking opens the compose panel.
final class OverlayComposeStripView: NSView {
    var onClick: (() -> Void)?
    var hint = "" { didSet { if hint != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityLabel() -> String? { hint }
    override func menu(for event: NSEvent) -> NSMenu? { superview?.menu(for: event) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        // Leave room on the right for the resize grip.
        let field = NSRect(x: 5, y: 3, width: max(0, bounds.width - 24), height: bounds.height - 6)
        let path = NSBezierPath(roundedRect: field, xRadius: 4, yRadius: 4)
        NSColor(calibratedWhite: isPressed ? 0.3 : 0.0, alpha: 0.6).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        path.lineWidth = 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            .paragraphStyle: paragraph,
        ]
        let text = hint as NSString
        let height = text.size(withAttributes: attributes).height
        text.draw(in: NSRect(x: field.minX + 7, y: field.midY - height / 2, width: max(0, field.width - 14), height: height),
                  withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Bubbles

/// Rounded dark label used for the hover bubble and the toast. Never intercepts the mouse.
private final class OverlayBubbleView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let padding = NSSize(width: 8, height: 5)

    init(borderColor: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.96).cgColor
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = borderColor.cgColor
        label.isSelectable = false
        label.drawsBackground = false
        label.maximumNumberOfLines = 8
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Sets the text and resizes to fit within `maxWidth`.
    func setText(_ text: NSAttributedString, maxWidth: CGFloat) {
        label.attributedStringValue = text
        let textWidth = max(40, maxWidth - padding.width * 2)
        label.preferredMaxLayoutWidth = textWidth
        let fitting = label.sizeThatFits(NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
        let size = NSSize(width: min(ceil(fitting.width), textWidth), height: ceil(fitting.height))
        label.frame = NSRect(origin: NSPoint(x: padding.width, y: padding.height), size: size)
        setFrameSize(NSSize(width: size.width + padding.width * 2, height: size.height + padding.height * 2))
    }

    var text: String { label.stringValue }
}

private final class OverlayGripView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.45).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for offset in stride(from: CGFloat(3), through: 11, by: 4) {
            path.move(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + offset))
            path.line(to: NSPoint(x: bounds.maxX - offset, y: bounds.minY + 2))
        }
        path.stroke()
    }
}

// MARK: - Root view

/// Content view of the overlay panel: tab strip, chat log, compose strip, plus edge resizing,
/// the hover bubble and the toast.
@MainActor
final class OverlayRootView: NSView {
    struct ResizeEdges: OptionSet {
        let rawValue: Int
        static let left = ResizeEdges(rawValue: 1)
        static let right = ResizeEdges(rawValue: 2)
        static let top = ResizeEdges(rawValue: 4)
        static let bottom = ResizeEdges(rawValue: 8)
    }

    static let minimumSize = NSSize(width: 220, height: 110)
    static let tabStripHeight: CGFloat = 24
    static let composeStripHeight: CGFloat = 26

    let tabStrip = OverlayTabStripView()
    let chatList = OverlayChatListView()
    let composeStrip = OverlayComposeStripView()

    /// Right-click on anything that is not a chat line.
    var optionsMenuProvider: (() -> NSMenu?)?
    /// The user finished or is in the middle of resizing with the mouse.
    var onUserResize: (() -> Void)?

    private let hoverBubble = OverlayBubbleView(borderColor: NSColor.white.withAlphaComponent(0.25))
    private let toast = OverlayBubbleView(borderColor: NSColor(calibratedRed: 1, green: 0.82, blue: 0.3, alpha: 0.7))
    private let grip = OverlayGripView()
    private var hoverEntryID: UUID?
    private var hoverTimer: Timer?
    private var toastTimer: Timer?
    private var trackingArea: NSTrackingArea?
    private(set) var isResizing = false
    /// Screen position of the pointer during an edge drag. The live pointer (not the event's
    /// window-relative location) is used because the window itself moves under left/bottom drags.
    var mouseLocationProvider: () -> NSPoint = { NSEvent.mouseLocation }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        setBackgroundOpacity(0.95)
        chatList.onUserScroll = { [weak self] in self?.hideHover() }
        addSubview(chatList)
        addSubview(tabStrip)
        addSubview(composeStrip)
        addSubview(grip)
        addSubview(hoverBubble)
        addSubview(toast)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setBackgroundOpacity(_ opacity: Double) {
        let clamped = CGFloat(min(max(opacity.isFinite ? opacity : 0.95, 0.15), 1))
        layer?.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: clamped).cgColor
    }

    override func layout() {
        super.layout()
        let b = bounds
        tabStrip.frame = NSRect(x: 0, y: b.maxY - Self.tabStripHeight, width: b.width, height: Self.tabStripHeight)
        composeStrip.frame = NSRect(x: 0, y: 0, width: b.width, height: Self.composeStripHeight)
        chatList.frame = NSRect(x: 0, y: Self.composeStripHeight, width: b.width,
                                height: max(0, b.height - Self.tabStripHeight - Self.composeStripHeight))
        grip.frame = NSRect(x: b.maxX - 16, y: 0, width: 16, height: 16)
        positionToast()
        hideHover()
    }

    // MARK: Menus

    override func menu(for event: NSEvent) -> NSMenu? {
        hideHover()
        return optionsMenuProvider?()
    }

    // MARK: Resizing

    func resizeEdges(at point: NSPoint) -> ResizeEdges {
        guard bounds.contains(point) else { return [] }
        let edge: CGFloat = 5, corner: CGFloat = 14
        var edges: ResizeEdges = []
        if point.x < edge { edges.insert(.left) }
        if point.x > bounds.maxX - edge { edges.insert(.right) }
        if point.y < edge { edges.insert(.bottom) }
        if point.y > bounds.maxY - edge { edges.insert(.top) }
        // Generous corners, so a diagonal grab does not need pixel precision.
        if !edges.isEmpty {
            if point.x < corner { edges.insert(.left) }
            if point.x > bounds.maxX - corner { edges.insert(.right) }
            if point.y < corner { edges.insert(.bottom) }
            if point.y > bounds.maxY - corner { edges.insert(.top) }
        }
        if point.x > bounds.maxX - 16, point.y < 16 { edges.formUnion([.right, .bottom]) }
        return edges
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        // Only steal the edges for a left press; right clicks there should still reach the menus.
        if !resizeEdges(at: local).isEmpty, NSApp.currentEvent?.type != .rightMouseDown { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let edges = resizeEdges(at: convert(event.locationInWindow, from: nil))
        guard !edges.isEmpty, let window else { return }
        hideHover()
        isResizing = true
        defer {
            isResizing = false
            onUserResize?()
        }
        let startMouse = mouseLocationProvider()
        let startFrame = window.frame
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp { break }
            let mouse = mouseLocationProvider()
            let frame = Self.resizedFrame(from: startFrame, edges: edges,
                                          dx: mouse.x - startMouse.x, dy: mouse.y - startMouse.y)
            if frame != window.frame { window.setFrame(frame, display: true) }
        }
    }

    /// Pure geometry of an edge drag; the edge opposite to the dragged one stays put.
    static func resizedFrame(from start: NSRect, edges: ResizeEdges, dx: CGFloat, dy: CGFloat) -> NSRect {
        var frame = start
        let minSize = minimumSize
        if edges.contains(.right) {
            frame.size.width = max(minSize.width, start.width + dx)
        } else if edges.contains(.left) {
            let width = max(minSize.width, start.width - dx)
            frame.origin.x = start.maxX - width
            frame.size.width = width
        }
        if edges.contains(.top) {
            frame.size.height = max(minSize.height, start.height + dy)
        } else if edges.contains(.bottom) {
            let height = max(minSize.height, start.height - dy)
            frame.origin.y = start.maxY - height
            frame.size.height = height
        }
        return frame.integral
    }

    private func cursor(for edges: ResizeEdges) -> NSCursor {
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        if horizontal && vertical {
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition
                switch (edges.contains(.left), edges.contains(.top)) {
                case (true, true): position = .topLeft
                case (true, false): position = .bottomLeft
                case (false, true): position = .topRight
                case (false, false): position = .bottomRight
                }
                return NSCursor.frameResize(position: position, directions: .all)
            }
            return .crosshair
        }
        return horizontal ? .resizeLeftRight : .resizeUpDown
    }

    // MARK: Tracking (cursor + hover)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // .activeAlways: the app is never active while the user is in the game.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let edges = resizeEdges(at: point)
        if !edges.isEmpty {
            cursor(for: edges).set()
            hideHover()
            return
        }
        NSCursor.arrow.set()
        updateHover(windowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        hideHover()
    }

    // MARK: Hover bubble

    private func updateHover(windowPoint: NSPoint) {
        guard let hover = chatList.hover(atWindowPoint: windowPoint), Self.hoverText(for: hover.entry) != nil else {
            hideHover()
            return
        }
        guard hover.entry.id != hoverEntryID else { return }
        hideHover()
        hoverEntryID = hover.entry.id
        // Short delay so sweeping the pointer across the chat does not flash bubbles.
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showHoverNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func showHoverNow() {
        guard let window, let id = hoverEntryID else { return }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        guard let hover = chatList.hover(atWindowPoint: windowPoint), hover.entry.id == id,
              let text = Self.hoverText(for: hover.entry) else {
            hideHover()
            return
        }
        showHover(text: text, near: convert(hover.rect, from: chatList))
    }

    /// Shows the bubble for the entry under `windowPoint` immediately (also used by the test harness).
    @discardableResult
    func showHoverImmediately(atWindowPoint windowPoint: NSPoint) -> Bool {
        guard let hover = chatList.hover(atWindowPoint: windowPoint), let text = Self.hoverText(for: hover.entry) else {
            hideHover()
            return false
        }
        hoverEntryID = hover.entry.id
        showHover(text: text, near: convert(hover.rect, from: chatList))
        return true
    }

    private func showHover(text: NSAttributedString, near rect: NSRect) {
        let maxWidth = min(bounds.width - 12, 460)
        hoverBubble.setText(text, maxWidth: maxWidth)
        let size = hoverBubble.frame.size
        var origin = NSPoint(x: min(max(6, rect.minX + 6), max(6, bounds.maxX - size.width - 6)), y: rect.maxY + 2)
        // Prefer above the line; fall back to below when it would leave the panel.
        if origin.y + size.height > bounds.maxY - 2 { origin.y = rect.minY - size.height - 2 }
        origin.y = min(max(2, origin.y), max(2, bounds.maxY - size.height - 2))
        hoverBubble.setFrameOrigin(origin)
        hoverBubble.isHidden = false
    }

    func hideHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverEntryID = nil
        hoverBubble.isHidden = true
    }

    var hoverBubbleText: String? { hoverBubble.isHidden ? nil : hoverBubble.text }

    static func hoverText(for entry: ChatEntry) -> NSAttributedString? {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]
        let out = NSMutableAttributedString()
        switch entry.state {
        case .original:
            // Only what a retranslation said about a line it left as it was.
            guard let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
            out.append(NSAttributedString(string: note, attributes: bodyAttributes))
        case .pending:
            out.append(NSAttributedString(string: "번역하는 중…", attributes: titleAttributes))
        case .failed(let reason):
            out.append(NSAttributedString(string: "번역 실패  ", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor(calibratedRed: 1, green: 0.78, blue: 0.2, alpha: 1),
            ]))
            out.append(NSAttributedString(string: reason, attributes: bodyAttributes))
            out.append(NSAttributedString(string: "\n오른쪽 클릭 → 다시 시도", attributes: titleAttributes))
        case .translated:
            let engine = entry.engine.map { " · \($0)" } ?? ""
            out.append(NSAttributedString(string: "원문\(engine)\n", attributes: titleAttributes))
            out.append(NSAttributedString(string: entry.message.body, attributes: bodyAttributes))
            if let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                out.append(NSAttributedString(string: "\n\(note)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor(calibratedRed: 0.75, green: 0.88, blue: 1, alpha: 0.95),
                ]))
            }
        }
        return out
    }

    // MARK: Toast

    func showToast(_ message: String, duration: TimeInterval = 2.6) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        toast.setText(NSAttributedString(string: trimmed, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]), maxWidth: max(80, bounds.width - 24))
        positionToast()
        toast.alphaValue = 1
        toast.isHidden = false
        toastTimer?.invalidate()
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOutToast() }
        }
        RunLoop.main.add(timer, forMode: .common)
        toastTimer = timer
    }

    private func fadeOutToast() {
        toastTimer = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            toast.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.toastTimer == nil else { return }
                self.toast.isHidden = true
            }
        })
    }

    private func positionToast() {
        let size = toast.frame.size
        toast.setFrameOrigin(NSPoint(x: max(4, (bounds.width - size.width) / 2),
                                     y: bounds.maxY - Self.tabStripHeight - size.height - 6))
    }

    var toastText: String? { toast.isHidden ? nil : toast.text }
}
