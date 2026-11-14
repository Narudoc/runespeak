import AppKit
import SwiftUI
import RunespeakCore

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let state: AppState
    private var window: NSWindow?

    init(state: AppState) {
        self.state = state
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        runespeakActivateApp()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(state: state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Runespeak 설정"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 720))
        window.contentMinSize = NSSize(width: 480, height: 420)
        window.center()
        window.setFrameAutosaveName("RunespeakSettingsWindow")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // A recorder left listening would keep every hotkey released.
        window?.makeFirstResponder(nil)
    }
}
