import AppKit
import RunespeakCore

/// The World of Warcraft process, found through public workspace information only (bundle
/// identifier and install path). Nothing here touches the game's memory, files or input.
enum GameApp {
    /// Every installed flavour (_retail_, _classic_, _classic_era_, _anniversary_) ships the same
    /// identifier in its Info.plist; the launcher and Battle.net use different ones.
    static let bundleIDs: Set<String> = ["com.blizzard.worldofwarcraft"]

    static func isGame(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier?.lowercased() else { return false }
        return bundleIDs.contains(id)
    }

    /// The running game. With several clients open, the frontmost one wins, then a visible one.
    static func runningApplication() -> NSRunningApplication? {
        let games = NSWorkspace.shared.runningApplications.filter { isGame($0) && !$0.isTerminated }
        return games.first(where: \.isActive) ?? games.first(where: { !$0.isHidden }) ?? games.first
    }

    /// Whether a game window is on the Space being shown right now (not minimised, not on
    /// another Space, not hidden). Reads window geometry only, which needs no permission.
    /// `true` when the window list itself cannot be read, so that nothing hangs on this check.
    static func hasWindowOnScreen(_ app: NSRunningApplication? = runningApplication()) -> Bool {
        guard let app, !app.isTerminated, !app.isHidden else { return false }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return true }
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            return bounds.width >= 200 && bounds.height >= 150
        }
    }

    /// Flavour from the install folder: ".../World of Warcraft/_retail_/World of Warcraft.app".
    /// Test realms of the modern game count as retail; every other folder (_classic_,
    /// _classic_era_, _anniversary_, ...) uses the classic data set.
    static func flavor(of app: NSRunningApplication) -> GameFlavor? {
        guard let url = app.bundleURL ?? app.executableURL else { return nil }
        return flavor(ofInstallPath: url.path)
    }

    static func flavor(ofInstallPath path: String) -> GameFlavor {
        let retailFolders: Set<String> = ["_retail_", "_ptr_", "_xptr_", "_beta_"]
        let folders = path.split(separator: "/").map { $0.lowercased() }
        return folders.contains(where: retailFolders.contains) ? .retail : .classic
    }
}
