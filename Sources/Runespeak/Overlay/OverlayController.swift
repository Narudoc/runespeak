import AppKit
import Combine
import RunespeakCore

/// Owns the panel that covers the game chat window with the translated chat.
///
/// The panel is on screen only while ALL of these hold: `show()` was called (and not `hide()`
/// since), `settings.overlayEnabled`, `state.overlayVisible`, and a region exists. While the
/// game is not in view (`state.gameInView`) it stays ordered in but invisible and click-through.
@MainActor
final class OverlayController: NSObject {
    /// Above normal and full-screen game windows, but low enough that the compose panel, menus and
    /// the region-selection dimmer (all at .floating or higher, ordered front later) can cover it.
    static let windowLevel: NSWindow.Level = .floating

    private let state: AppState
    private var panel: OverlayPanel
    private var appliedSharing: NSWindow.SharingType
    private let rootView: OverlayRootView
    private var cancellables: Set<AnyCancellable> = []

    private var wantsShown = false
    private var refreshScheduled = false
    /// Frame last pushed from state; state changes that do not alter the target leave the panel alone
    /// (the user may be mid-drag, or the debounced save may not have landed yet).
    private var lastAppliedTarget: CGRect?
    private var isApplyingFrame = false
    private var pendingFrameSave: DispatchWorkItem?

    init(state: AppState) {
        self.state = state
        let initial = NSRect(x: 0, y: 0, width: 420, height: 220)
        appliedSharing = Self.sharingType(for: state.settings)
        panel = OverlayPanel(contentRect: initial, sharingType: appliedSharing)
        rootView = OverlayRootView(frame: NSRect(origin: .zero, size: initial.size))
        super.init()

        rootView.autoresizingMask = [.width, .height]
        panel.contentView = rootView
        wireInteractions()

        // objectWillChange fires before the new value is stored, so read the state on the next
        // main-queue turn; this also coalesces bursts (several entries changing in one tick).
        state.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        // Separate from the coalesced refresh so the same notice sent twice is shown twice.
        state.$notice
            .dropFirst()
            .sink { [weak self] notice in
                guard let self, let notice else { return }
                self.rootView.showToast(notice)
            }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        // object: nil — the panel is replaced when the capture-visibility setting changes.
        center.addObserver(self, selector: #selector(panelDidMove(_:)), name: NSWindow.didMoveNotification, object: nil)
        center.addObserver(self, selector: #selector(screensChanged(_:)),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidUnhide(_:)),
                           name: NSApplication.didUnhideNotification, object: nil)
        refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Contract

    func show() {
        wantsShown = true
        refresh()
    }

    func hide() {
        wantsShown = false
        refresh()
    }

    /// Re-reads state.region / settings.overlayFrame and moves the panel there, discarding any
    /// position the user dragged to that has not been saved yet.
    func applyRegion() {
        pendingFrameSave?.cancel()
        pendingFrameSave = nil
        lastAppliedTarget = nil
        refresh()
    }

    // MARK: Introspection (integration + harness)

    var window: NSPanel { panel }
    var isPanelVisible: Bool { panel.isVisible && !isConcealed }
    /// Ordered in, but transparent and click-through because the game is not in view.
    var isConcealed: Bool { panel.ignoresMouseEvents }
    var contentView: OverlayRootView { rootView }

    // MARK: Wiring

    private func wireInteractions() {
        rootView.tabStrip.onToggle = { [weak self] group in
            self?.state.actions?.updateSettings { settings in
                if settings.enabledGroups.contains(group) {
                    settings.enabledGroups.remove(group)
                } else {
                    settings.enabledGroups.insert(group)
                }
            }
        }
        rootView.composeStrip.onClick = { [weak self] in
            self?.state.actions?.showCompose()
        }
        rootView.optionsMenuProvider = { [weak self] in
            guard let self else { return nil }
            return OverlayChatMenu.optionsMenu(state: self.state)
        }
        rootView.chatList.menuProvider = { [weak self] entry in
            guard let self else { return nil }
            self.rootView.hideHover()
            guard let entry else { return OverlayChatMenu.optionsMenu(state: self.state) }
            return OverlayChatMenu.entryMenu(for: entry, state: self.state) { [weak self] message in
                self?.rootView.showToast(message)
            }
        }
        rootView.onUserResize = { [weak self] in self?.scheduleFrameSave() }
    }

    // MARK: State → panel

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        let settings = state.settings

        let sharing = Self.sharingType(for: settings)
        if sharing != appliedSharing { replacePanel(sharing: sharing) }

        rootView.setBackgroundOpacity(settings.overlayOpacity)
        rootView.tabStrip.setEnabledGroups(settings.enabledGroups)
        rootView.composeStrip.hint = "보낼 말 번역 (\(settings.composeHotkey.displayString))"

        applyTargetFrameIfChanged()

        rootView.chatList.update(entries: state.overlayEntries,
                                 fontSize: OverlayChatFormat.clampedFontSize(settings.fontSize))

        // Leaving the game is not a reason to order the panel out: bringing it back would take
        // orderFrontRegardless(), which un-hides a hidden app and, on another Space, lands
        // wherever the user happens to be. Invisible and click-through does the same job.
        conceal(!state.gameInView)

        let shouldShow = wantsShown && settings.overlayEnabled && state.overlayVisible && state.region != nil
        if shouldShow {
            // Ordering a window front un-hides a hidden app with all its windows; the panel is
            // shown when the app comes back instead (`appDidUnhide`).
            if !panel.isVisible, !NSApp.isHidden {
                // Never makeKey / activate: the game must keep keyboard focus.
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible {
            rootView.hideHover()
            panel.orderOut(nil)
        }
    }

    private func conceal(_ concealed: Bool) {
        guard panel.ignoresMouseEvents != concealed else { return }
        if concealed { rootView.hideHover() }
        panel.ignoresMouseEvents = concealed
        panel.alphaValue = concealed ? 0 : 1
    }

    static func sharingType(for settings: AppSettings) -> NSWindow.SharingType {
        settings.showOverlayInCaptures ? .readOnly : .none
    }

    /// Changes whether screenshots/recordings see the panel by building a new panel.
    ///
    /// Measured on macOS 27.2: once a window exists on the window server, `sharingType` can still be
    /// switched from .none to .readOnly, but assigning .none afterwards is silently ignored (the
    /// getter keeps answering .none, so the setter thinks nothing changed; the window server keeps
    /// sharing the window). A value set before the window is first shown is always honoured.
    private func replacePanel(sharing: NSWindow.SharingType) {
        let old = panel
        let wasVisible = old.isVisible
        let fresh = OverlayPanel(contentRect: old.frame, sharingType: sharing)
        appliedSharing = sharing
        isApplyingFrame = true
        old.contentView = nil
        fresh.contentView = rootView
        fresh.setFrame(old.frame, display: false)
        fresh.ignoresMouseEvents = old.ignoresMouseEvents
        fresh.alphaValue = old.alphaValue
        panel = fresh
        if wasVisible { fresh.orderFrontRegardless() }
        old.orderOut(nil)
        old.close()
        isApplyingFrame = false
    }

    private func targetFrame() -> CGRect? {
        guard let region = state.region else { return nil }
        if let saved = state.settings.overlayFrame, Self.isUsable(saved) { return Self.sanitized(saved) }
        return Self.sanitized(region.rect)
    }

    private func applyTargetFrameIfChanged() {
        guard let target = targetFrame(), target != lastAppliedTarget, !rootView.isResizing else { return }
        lastAppliedTarget = target
        guard panel.frame != target else { return }
        isApplyingFrame = true
        panel.setFrame(target, display: true)
        isApplyingFrame = false
    }

    /// A saved frame is ignored when no connected display shows a usable part of it (monitor unplugged).
    static func isUsable(_ frame: CGRect) -> Bool {
        guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
              frame.width >= 1, frame.height >= 1 else { return false }
        let screens = NSScreen.screens
        if screens.isEmpty { return true }
        return screens.contains { screen in
            let visible = screen.frame.intersection(frame)
            return !visible.isNull && visible.width >= 60 && visible.height >= 40
        }
    }

    static func sanitized(_ frame: CGRect) -> CGRect {
        var out = frame.standardized.integral
        out.size.width = max(out.width, OverlayRootView.minimumSize.width)
        out.size.height = max(out.height, OverlayRootView.minimumSize.height)
        return out
    }

    // MARK: Panel → state

    @objc private func panelDidMove(_ note: Notification) {
        // Only moves made by the user (tab strip drag) are persisted.
        guard (note.object as AnyObject?) === panel, !isApplyingFrame, !rootView.isResizing else { return }
        scheduleFrameSave()
    }

    @objc private func appDidUnhide(_ note: Notification) {
        scheduleRefresh()
    }

    @objc private func screensChanged(_ note: Notification) {
        lastAppliedTarget = nil
        scheduleRefresh()
    }

    private func scheduleFrameSave() {
        pendingFrameSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFrameSave = nil
            let frame = self.panel.frame
            guard self.state.region != nil, frame != self.targetFrame() else { return }
            // Record it as applied first, so the echo through state does not snap the panel back.
            self.lastAppliedTarget = Self.sanitized(frame)
            self.state.actions?.updateSettings { $0.overlayFrame = frame }
        }
        pendingFrameSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
