import AppKit
import RunespeakCore

/// Small floating input panel for the user's own chat: type Korean, Enter translates and copies.
@MainActor
final class ComposePanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// Called when the user leaves without sending (Esc, or Enter on an empty field) so the
    /// owner can bring the game back to the front. Not called after a successful submit:
    /// the panel gives the keyboard back itself (`finish`).
    var onDismiss: (() -> Void)?

    static let placeholder = "보낼 말을 적고 ↩ (닫기: esc)"
    static let copiedMessage = "클립보드에 담았습니다 · 게임 채팅 입력줄을 열고 ⌘V"
    static let hintMessage = "↑↓ 키로 앞서 보낸 말을 불러옵니다 · 결과는 클립보드에만 담기니 게임에는 직접 붙여 넣으세요"

    enum Phase: Equatable {
        case editing
        case translating
        case copied
    }

    private let state: AppState
    private var panel: ComposePanel?
    private var field: NSTextField!
    private var spinner: NSProgressIndicator!
    private var statusLabel: NSTextField!

    private(set) var phase: Phase = .editing
    /// Bumped whenever the panel is closed or reused, so a late translation result or close
    /// timer from an earlier round cannot touch the current one.
    private var generation = 0
    private var shownAt = Date.distantPast
    private var isClosing = false

    private(set) var history: [String] = []
    private var historyIndex: Int?
    private var draftBeforeHistory = ""
    private static let historyLimit = 50
    private static let successDisplayTime: TimeInterval = 1.5

    init(state: AppState) {
        self.state = state
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    /// The panel has the keyboard right now.
    var isKey: Bool { panel?.isKeyWindow ?? false }

    /// How long the panel may take to become key before the app is activated after all.
    private static let keyGrace: TimeInterval = 0.2

    // MARK: - Showing

    /// `rect`: the chat region in global AppKit coordinates; the panel sits on its bottom edge.
    func show(near rect: CGRect?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        if phase != .editing || !panel.isVisible {
            generation += 1
            resetToEditing(keepText: phase == .editing)
        }
        panel.setFrame(frame(near: rect), display: true)

        // The app is NOT activated: a non-activating panel takes the keyboard while the game
        // stays the active app. Activating would pull the history window in front of the game
        // and bring back the Dock and menu bar the game hides, for as long as the user types.
        panel.allowsKey = true
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        focusField()
        shownAt = Date()

        // Should the system not hand the panel the keyboard that way, activating is still
        // better than a panel that cannot be typed into.
        let round = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keyGrace) { [weak self] in
            guard let self, round == self.generation, self.phase == .editing,
                  let panel = self.panel, panel.isVisible, !panel.isKeyWindow else { return }
            runespeakActivateApp()
            panel.makeKeyAndOrderFront(nil)
            self.focusField()
            self.shownAt = Date()
        }
    }

    func close() {
        generation += 1
        guard let panel else { return }
        // Ordering the panel out makes it resign key, which must not close it a second time.
        isClosing = true
        defer { isClosing = false }
        // What was typed but not sent stays as a draft; a finished or in-flight round does not.
        if phase != .editing { field.stringValue = "" }
        phase = .editing
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }

    private func dismissToGame() {
        close()
        onDismiss?()
    }

    func windowDidResignKey(_ notification: Notification) {
        // The user clicked back into the game (or another app) while typing: get out of the
        // way but keep the draft. Ignore the moment right after opening, when key status is
        // still settling.
        guard !isClosing, phase == .editing, isVisible, Date().timeIntervalSince(shownAt) > 0.5 else { return }
        close()
    }

    /// Gives the keyboard back to the active app (the game) while the panel stays on screen.
    private func yieldKey() {
        guard let panel, panel.isVisible, panel.isKeyWindow else { return }
        panel.allowsKey = false
        // A window only stops being key by leaving the screen; back at once, without the keyboard.
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    // MARK: - Submit

    private func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            field.stringValue = ""
            dismissToGame()
            return
        }
        remember(text)
        phase = .translating
        field.stringValue = text
        field.isEnabled = false
        spinner.startAnimation(nil)
        setStatus("번역하는 중…", color: .secondaryLabelColor)
        // The field editor went away with isEnabled = false; keep Esc working via the panel.
        panel?.makeFirstResponder(panel)

        generation += 1
        let round = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result: Result<String, TranslationError>
            if let actions = self.state.actions {
                result = await actions.submitOutgoing(text)
            } else {
                result = .failure(.badResponse("번역기가 아직 준비되지 않았습니다"))
            }
            guard round == self.generation else { return }
            self.finish(result, original: text, round: round)
        }
    }

    private func finish(_ result: Result<String, TranslationError>, original: String, round: Int) {
        spinner.stopAnimation(nil)
        switch result {
        case .success(let translated):
            phase = .copied
            field.stringValue = translated
            setStatus(Self.copiedMessage, color: .systemGreen)
            // "Enter, ⌘V, Enter" is typed into the game: it needs the keyboard now, not when
            // this panel goes away.
            yieldKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.successDisplayTime) { [weak self] in
                guard let self, round == self.generation else { return }
                self.close()
            }
        case .failure(let error):
            phase = .editing
            field.isEnabled = true
            field.stringValue = original
            setStatus(state.errorText(error) + " — Enter로 다시 시도", color: .systemRed)
            // Puts the caret back inside the panel; this does not pull the keyboard away from
            // another app if the user has switched meanwhile.
            focusField()
        }
    }

    // MARK: - History

    private func remember(_ text: String) {
        historyIndex = nil
        draftBeforeHistory = ""
        if history.last != text { history.append(text) }
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    /// direction -1 = older (Up), +1 = newer (Down). Returns the text to show, nil if nothing changes.
    private func recall(direction: Int, current: String) -> String? {
        guard !history.isEmpty else { return nil }
        if direction < 0 {
            guard let index = historyIndex else {
                draftBeforeHistory = current
                historyIndex = history.count - 1
                return history[history.count - 1]
            }
            guard index > 0 else { return nil }
            historyIndex = index - 1
            return history[index - 1]
        }
        guard let index = historyIndex else { return nil }
        if index + 1 < history.count {
            historyIndex = index + 1
            return history[index + 1]
        }
        historyIndex = nil
        return draftBeforeHistory
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // The Korean input method commits the syllable first and then sends the command, so
        // when insertNewline: arrives `textView.string` normally already holds the finished
        // text (and an input method that only commits on Enter never sends the command at all).
        // Should a command arrive while text is still being composed, the key only finishes the
        // composition: nothing half-composed is ever submitted, and Esc does not throw it away.
        if textView.hasMarkedText() {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                 #selector(NSResponder.cancelOperation(_:)):
                textView.unmarkText()
                textView.inputContext?.discardMarkedText()
                return true
            default:
                return false
            }
        }

        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            guard phase == .editing else { return true }
            submit(textView.string)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismissToGame()
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            let direction = selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1
            if let text = recall(direction: direction, current: textView.string) {
                textView.string = text
                textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        // Typing after a failure clears the error line.
        if phase == .editing, statusLabel.textColor == .systemRed {
            setStatus(Self.hintMessage, color: .tertiaryLabelColor)
        }
    }

    // MARK: - Panel construction

    private func resetToEditing(keepText: Bool) {
        phase = .editing
        historyIndex = nil
        field.isEnabled = true
        if !keepText { field.stringValue = "" }
        spinner.stopAnimation(nil)
        setStatus(Self.hintMessage, color: .tertiaryLabelColor)
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }

    private func focusField() {
        guard let panel else { return }
        panel.makeFirstResponder(field)
        // makeFirstResponder selects everything; put the caret at the end of a kept draft.
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    private static let panelHeight: CGFloat = 70

    private func frame(near rect: CGRect?) -> CGRect {
        let height = Self.panelHeight
        guard let rect, rect.width > 0, rect.height > 0 else {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
            let bounds = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let width = min(520, bounds.width - 40)
            return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        }
        let screen = NSScreen.screens.max { a, b in
            a.frame.intersection(rect).area < b.frame.intersection(rect).area
        }
        let bounds = screen?.frame ?? rect
        let width = min(max(rect.width, 380), min(720, bounds.width))
        var origin = CGPoint(x: rect.minX, y: rect.minY)
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - height)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private func makePanel() -> ComposePanel {
        let panel = ComposePanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: Self.panelHeight),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismissToGame() }

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let field = NSTextField()
        field.placeholderString = Self.placeholder
        field.font = .systemFont(ofSize: 16)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel("보낼 말 입력창")

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let status = NSTextField(labelWithString: Self.hintMessage)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        for view in [field, spinner, status] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
            spinner.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            spinner.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            status.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])

        panel.contentView = background
        self.field = field
        self.spinner = spinner
        self.statusLabel = status
        return panel
    }
}

/// Borderless panels refuse key status unless told otherwise.
final class ComposePanel: NSPanel {
    var onCancel: (() -> Void)?
    /// False while the panel only shows a result.
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    // The Edit menu's shortcuts reach a key window through the main menu, which belongs to
    // the active app; this panel is key while the game is the active one.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift] else { return false }
        let action: Selector?
        // Key codes, not characters: with the Korean keyboard ⌘V arrives as "ㅍ".
        switch (event.keyCode, flags.contains(.shift)) {
        case (7, false): action = #selector(NSText.cut(_:))         // X
        case (8, false): action = #selector(NSText.copy(_:))        // C
        case (9, false): action = #selector(NSText.paste(_:))       // V
        case (0, false): action = #selector(NSText.selectAll(_:))   // A
        case (6, false): action = Selector(("undo:"))               // Z
        case (6, true): action = Selector(("redo:"))
        default: action = nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }

    // Esc while the field is disabled (translating / showing the result).
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
