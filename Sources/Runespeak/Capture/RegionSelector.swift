import AppKit
import RunespeakCore

/// Dims every display and lets the user drag a rectangle over the game's chat window.
@MainActor
final class RegionSelector {

    /// Smallest selection accepted, in points: a chat window narrower or lower than this cannot
    /// hold a readable line, so such a drag is treated as a slip of the hand.
    static let minimumSize = CGSize(width: 120, height: 40)

    static let instruction = "채팅창 전체를 사각형으로 감싸 주세요 (채널 이름이 시작되는 왼쪽 가장자리 포함) · esc로 취소"

    private var windows: [SelectionWindow] = []
    private var completion: ((CaptureRegion?) -> Void)?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var screenObserver: NSObjectProtocol?

    init() {}

    /// Bumped whenever a selection starts or ends; delayed steps of an earlier one check it.
    private var round = 0
    private var game: NSRunningApplication?
    private var fromOwnApp = false

    /// How long the game gets to come forward (and its Space to slide in) before the dimmer
    /// goes up regardless.
    private static let gameWait: TimeInterval = 1.5
    /// How long a selection window may take to become key before the app is activated after all.
    private static let keyGrace: TimeInterval = 0.25

    /// Calls `completion` exactly once: with the region in global AppKit points, or nil when the
    /// user cancelled (Esc, right click). A second call while a selection is open cancels the
    /// first one.
    ///
    /// `game` is brought to the front first: the dimmer is only of use over the chat window,
    /// and a game in native full screen lives on a Space of its own. `fromOwnApp` says the
    /// request came from one of this app's windows, which is where a cancel returns to.
    func select(over game: NSRunningApplication?, fromOwnApp: Bool, completion: @escaping (CaptureRegion?) -> Void) {
        if self.completion != nil { finish(nil) }
        self.completion = completion
        self.game = game
        self.fromOwnApp = fromOwnApp
        round += 1
        let round = self.round

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = fromOwnApp || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        guard let game, !game.isTerminated, !(game.isActive && GameApp.hasWindowOnScreen(game)) else {
            present()
            return
        }
        if game.isHidden { game.unhide() }
        if NSApp.isActive { NSApp.yieldActivation(to: game) }
        game.activate()
        let deadline = Date().addingTimeInterval(Self.gameWait)
        func poll() {
            guard round == self.round, self.completion != nil else { return }
            if (game.isActive && GameApp.hasWindowOnScreen(game)) || Date() >= deadline {
                present()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
    }

    private func present() {
        for screen in NSScreen.screens {
            let window = SelectionWindow(screen: screen)
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self] rect in
                guard let self else { return }
                // View coordinates are window coordinates; the window covers the screen exactly.
                self.finish(rect.map { CaptureRegion(rect: $0.offsetBy(dx: window.frame.minX, dy: window.frame.minY)) })
            }
            view.onDragBegan = { [weak self, weak view] in
                // Only one display carries a selection at a time.
                self?.windows.forEach { w in
                    if let other = w.contentView as? SelectionView, other !== view { other.clearSelection() }
                }
            }
            window.contentView = view
            windows.append(window)
        }
        guard !windows.isEmpty else {
            finish(nil)
            return
        }

        // Esc must work even if the click-to-focus never happened.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.finish(nil)
                return nil
            }
            return event
        }
        // A display that is plugged in or removed mid-selection leaves stale windows behind.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }

        // The app is not activated: the panels are non-activating and take the keyboard (for
        // Esc) while the game stays the active app, on its own Space, with its Dock and menu
        // bar still hidden. Activating could also switch back to the Space of this app's windows.
        makeKey()
        NSCursor.crosshair.set()

        // Should the system not give a panel the keyboard that way, activate after all: the
        // mouse works either way, but Esc would not.
        let round = self.round
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keyGrace) { [weak self] in
            guard let self, round == self.round, self.completion != nil,
                  !self.windows.contains(where: \.isKeyWindow) else { return }
            self.forceActivate()
            self.makeKey()
        }
    }

    private func makeKey() {
        for window in windows { window.orderFrontRegardless() }
        // Key window on the display under the pointer, so Esc and the cursor behave at once.
        let mouse = NSEvent.mouseLocation
        let key = windows.first { $0.frame.contains(mouse) } ?? windows.first
        key?.makeKeyAndOrderFront(nil)
    }

    private func finish(_ region: CaptureRegion?) {
        guard let done = completion else { return }
        completion = nil
        round += 1
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for window in windows {
            (window.contentView as? SelectionView)?.onFinish = nil
            window.orderOut(nil)
        }
        windows.removeAll()
        NSCursor.arrow.set()

        func handOver(to app: NSRunningApplication) {
            if NSApp.isActive { NSApp.yieldActivation(to: app) }
            if !app.isActive { app.activate() }
        }
        if let game, !game.isTerminated, region != nil || !fromOwnApp {
            // A region was chosen: the game is where its effect shows. (After a cancel that
            // did not start in this app, the game is also where the user was or meant to be.)
            handOver(to: previousApp.flatMap { region == nil && !$0.isTerminated ? $0 : nil } ?? game)
        } else if fromOwnApp {
            if game != nil { runespeakActivateApp() }
        } else if let previous = previousApp, !previous.isTerminated {
            // Hand the keyboard back to whatever was in front.
            handOver(to: previous)
        }
        previousApp = nil
        game = nil
        done(region)
    }

    /// Drives the selection view with synthetic mouse events in a window that is never shown.
    /// Returns a description of every expectation that failed (used by `--capture-check`).
    static func selfCheck() -> [String] {
        guard let screen = NSScreen.screens.first else { return [] }
        var problems: [String] = []
        let window = SelectionWindow(screen: screen)
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        if window.frame != screen.frame { problems.append("선택 창이 화면 전체를 덮지 않음: \(window.frame) / \(screen.frame)") }

        var results: [CGRect?] = []
        view.onFinish = { results.append($0) }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        func drag(from a: CGPoint, to b: CGPoint) {
            guard let down = event(.leftMouseDown, a.x, a.y), let move = event(.leftMouseDragged, b.x, b.y),
                  let up = event(.leftMouseUp, b.x, b.y) else { return }
            view.mouseDown(with: down); view.mouseDragged(with: move); view.mouseUp(with: up)
        }

        // Dragged up-left: the rectangle is normalised.
        drag(from: CGPoint(x: 700, y: 300), to: CGPoint(x: 100, y: 60))
        if results.count != 1 || results.first != .some(CGRect(x: 100, y: 60, width: 600, height: 240)) {
            problems.append("드래그 결과가 다름: \(results)")
        }
        // A slip of the hand is not a region.
        results = []
        drag(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 230, y: 215))
        if !results.isEmpty { problems.append("너무 작은 드래그가 받아들여짐: \(results)") }
        // Past the screen edge: clamped to the display.
        drag(from: CGPoint(x: 300, y: 200), to: CGPoint(x: -500, y: -500))
        if results.count != 1 || results.first != .some(CGRect(x: 0, y: 0, width: 300, height: 200)) {
            problems.append("화면 밖 드래그가 화면 안으로 잘리지 않음: \(results)")
        }
        // Right click cancels.
        results = []
        if let right = event(.rightMouseDown, 10, 10) { view.rightMouseDown(with: right) }
        if results.count != 1 || results.first != .some(nil) { problems.append("오른쪽 클릭이 취소로 처리되지 않음") }

        // The dim layer and the punched-out selection really draw.
        if let down = event(.leftMouseDown, 100, 100), let move = event(.leftMouseDragged, 500, 300) {
            view.mouseDown(with: down); view.mouseDragged(with: move)
        }
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // Bitmap rows run top-down; view coordinates bottom-up.
            let k = CGFloat(bitmap.pixelsWide) / max(1, view.bounds.width)   // backing scale
            let inside = bitmap.colorAt(x: Int(300 * k), y: Int((view.bounds.height - 200) * k))?.alphaComponent ?? -1
            let outside = bitmap.colorAt(x: Int(800 * k), y: Int((view.bounds.height - 600) * k))?.alphaComponent ?? -1
            if inside > 0.05 { problems.append("선택한 영역이 어둡게 덮여 있음 (alpha \(inside))") }
            if outside < 0.3 { problems.append("선택 밖이 어두워지지 않음 (alpha \(outside))") }
            if let dump = ProcessInfo.processInfo.environment["RUNESPEAK_SELECTOR_DUMP"],
               let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: dump))
            }
        } else {
            problems.append("선택 화면을 그리지 못함")
        }
        return problems
    }

    /// The cooperative `NSApp.activate()` of macOS 14 can be declined while a full-screen game is
    /// frontmost; the selection is started by an explicit user action and needs the keyboard
    /// for Esc, so the forcing call is used on purpose.
    private func forceActivate() {
        (NSApplication.shared as RegionSelectorForceActivating).regionSelectorForceActivate()
    }
}

private protocol RegionSelectorForceActivating {
    func regionSelectorForceActivate()
}

extension NSApplication: RegionSelectorForceActivating {
    @available(macOS, deprecated: 14.0)
    fileprivate func regionSelectorForceActivate() {
        activate(ignoringOtherApps: true)
    }
}

// MARK: - Window

private final class SelectionWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // contentRect is in global coordinates; pin it in case AppKit constrained it.
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above a full-screen game and its Space, on whichever Space is showing.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // A borderless window at the shielding level must not be pushed below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - View

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    var onDragBegan: (() -> Void)?

    private var anchor: CGPoint?
    private var selection: CGRect?
    private var tooSmallHint = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    func clearSelection() {
        anchor = nil
        selection = nil
        needsDisplay = true
    }

    // MARK: Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
        // Esc goes to the display the pointer is on.
        window?.makeKey()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        onDragBegan?()
        tooSmallHint = false
        anchor = clamp(convert(event.locationInWindow, from: nil))
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let p = clamp(convert(event.locationInWindow, from: nil))
        selection = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                           width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { anchor = nil }
        guard anchor != nil, let rect = selection?.integral else { return }
        if rect.width >= RegionSelector.minimumSize.width, rect.height >= RegionSelector.minimumSize.height {
            onFinish?(rect)
        } else {
            // Too small to be a chat window: stay open and say why.
            selection = nil
            tooSmallHint = rect.width > 3 || rect.height > 3
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }
    override func otherMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onFinish?(nil) }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
        ctx.fill(bounds)

        if let rect = selection, rect.width > 0, rect.height > 0 {
            // The chosen area shows the game undimmed.
            ctx.clear(rect)
            let ok = rect.width >= RegionSelector.minimumSize.width && rect.height >= RegionSelector.minimumSize.height
            let outline = ok ? NSColor.systemGreen : NSColor.systemOrange
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(4)
            ctx.stroke(rect.insetBy(dx: -1, dy: -1))
            ctx.setStrokeColor(outline.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(rect.insetBy(dx: -1, dy: -1))

            let label = "\(Int(rect.width)) × \(Int(rect.height))"
            drawBadge(label, centeredAt: CGPoint(x: rect.midX, y: labelY(for: rect)), fontSize: 13, emphasised: false)
        }

        let text = tooSmallHint ? "사각형이 너무 작아 읽을 수 없습니다 · 채팅창을 통째로 감싸 다시 그려 주세요 · esc로 취소" : RegionSelector.instruction
        drawBadge(text, centeredAt: CGPoint(x: bounds.midX, y: bounds.maxY - 90), fontSize: 20, emphasised: true)
    }

    /// Below the rectangle when there is room, else above it.
    private func labelY(for rect: CGRect) -> CGFloat {
        rect.minY - 22 >= bounds.minY + 4 ? rect.minY - 16 : min(rect.maxY + 16, bounds.maxY - 12)
    }

    private func drawBadge(_ text: String, centeredAt center: CGPoint, fontSize: CGFloat, emphasised: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: emphasised ? .semibold : .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let padding = CGSize(width: emphasised ? 18 : 8, height: emphasised ? 10 : 4)
        var box = CGRect(x: center.x - size.width / 2 - padding.width, y: center.y - size.height / 2 - padding.height,
                         width: size.width + padding.width * 2, height: size.height + padding.height * 2)
        // Keep the badge on this display.
        box.origin.x = min(max(box.minX, bounds.minX + 8), max(bounds.minX + 8, bounds.maxX - box.width - 8))
        let path = NSBezierPath(roundedRect: box, xRadius: emphasised ? 10 : 5, yRadius: emphasised ? 10 : 5)
        NSColor.black.withAlphaComponent(0.78).setFill()
        path.fill()
        string.draw(at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height))
    }
}
