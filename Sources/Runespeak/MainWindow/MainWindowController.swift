import AppKit
import SwiftUI
import RunespeakCore

/// The ordinary window (meant for a second monitor) with status, buttons and the full chat history.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let state: AppState
    private var windowStorage: NSWindow?

    init(state: AppState) {
        self.state = state
        super.init()
    }

    /// Brings the window to the front, creating it on first use.
    func show() {
        let window = windowStorage ?? makeWindow()
        windowStorage = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        // The app normally sits in the background behind the game, so it has to be activated for
        // the window to come forward.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// nil until `show()` was called once.
    var window: NSWindow? { windowStorage }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Runespeak 채팅 번역"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 320)
        // Chat colours are picked by the game for a dark backdrop; keep them legible.
        window.appearance = NSAppearance(named: .darkAqua)
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: MainWindowRootView(state: state))
        window.setContentSize(NSSize(width: 760, height: 560))
        window.center()
        window.setFrameAutosaveName("RunespeakMainWindow")
        return window
    }
}
