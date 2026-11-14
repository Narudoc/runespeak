import AppKit
import SwiftUI
import RunespeakCore

/// A button that records a key combination: click, press the combo. Esc cancels.
struct HotkeyRecorder: NSViewRepresentable {
    let spec: HotkeySpec
    /// Return a Korean reason to refuse the combination (e.g. already used by the other hotkey).
    var validate: (HotkeySpec) -> String? = { _ in nil }
    let onChange: (HotkeySpec) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderButton {
        let button = HotkeyRecorderButton()
        button.spec = spec
        button.validate = validate
        button.onChange = onChange
        return button
    }

    func updateNSView(_ button: HotkeyRecorderButton, context: Context) {
        button.validate = validate
        button.onChange = onChange
        if button.spec != spec { button.spec = spec }
    }
}

final class HotkeyRecorderButton: NSButton {
    var spec = HotkeySpec.defaultToggle { didSet { refreshTitle() } }
    var validate: (HotkeySpec) -> String? = { _ in nil }
    var onChange: (HotkeySpec) -> Void = { _ in }

    private(set) var isRecording = false
    private var message: String?
    private var messageToken = 0

    static let prompt = "키 조합을 누르세요 (Esc 취소)"

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        font = .systemFont(ofSize: NSFont.systemFontSize)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        // Wide enough for the prompt so the form does not jump when recording starts.
        var size = super.intrinsicContentSize
        size.width = max(size.width, 210)
        return size
    }

    @objc private func clicked() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard !isRecording else { return }
        window?.makeFirstResponder(self)
        isRecording = true
        message = nil
        HotkeyCenter.setSuspended(true)
        refreshTitle()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        HotkeyCenter.setSuspended(false)
        refreshTitle()
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        handle(event)
    }

    // ⌘-combinations arrive as key equivalents before keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        let held = HotkeySpec.modifierSymbols(event.modifierFlags)
        title = held.isEmpty ? Self.prompt : held + " …"
    }

    /// Internal so the behaviour can be driven without real key presses.
    func handle(_ event: NSEvent) {
        guard let candidate = HotkeySpec(event: event) else { return }
        record(candidate)
    }

    func record(_ candidate: HotkeySpec) {
        guard isRecording else { return }
        let bareEscape = candidate.keyCode == 53 && candidate.modifierFlags.isEmpty
        if bareEscape {
            stopRecording()
            return
        }
        if let reason = candidate.rejectionReason ?? validate(candidate) {
            flash(reason)
            return
        }
        stopRecording()
        if candidate != spec {
            spec = candidate
            onChange(candidate)
        }
    }

    private func flash(_ text: String) {
        message = text
        messageToken += 1
        let token = messageToken
        refreshTitle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, token == self.messageToken else { return }
            self.message = nil
            self.refreshTitle()
        }
    }

    private func refreshTitle() {
        if isRecording {
            title = message ?? Self.prompt
        } else {
            title = spec.displayString
        }
        setAccessibilityLabel(isRecording ? "단축키 입력 대기 중" : "단축키 \(spec.displayString), 눌러서 변경")
    }
}
