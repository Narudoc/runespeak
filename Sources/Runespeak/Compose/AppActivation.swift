import AppKit

// The cooperative `NSApp.activate()` of macOS 14 may be declined while a full-screen game is
// frontmost; the panels of this app are opened by an explicit user action (a hotkey, a menu
// item) and must reliably get the keyboard, so the older forcing call is used on purpose.
private protocol RunespeakForceActivating {
    func runespeakForceActivate()
}

extension NSApplication: RunespeakForceActivating {
    @available(macOS, deprecated: 14.0)
    fileprivate func runespeakForceActivate() {
        activate(ignoringOtherApps: true)
    }
}

@MainActor
func runespeakActivateApp() {
    (NSApplication.shared as RunespeakForceActivating).runespeakForceActivate()
}
