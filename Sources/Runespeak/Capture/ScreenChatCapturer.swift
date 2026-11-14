import AppKit
import CoreGraphics
import ScreenCaptureKit
import RunespeakCore

/// Captures the chat region with ScreenCaptureKit.
///
/// The picture is taken from the game's own window, so nothing that sits on top of it — this
/// app's overlay panel in particular — is in it, and the game may even be covered by other
/// windows. If the game runs but its window cannot be matched, the display is captured with this
/// app's windows excluded instead.
final class ScreenChatCapturer: ChatCapturing, @unchecked Sendable {

    init() {}

    // MARK: - Permission

    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestPermission() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        // The system shows its prompt once per app; after that only System Settings can grant
        // it (the main window has the button for that).
        _ = CGRequestScreenCaptureAccess()
    }

    // MARK: - Game process

    func detectRunningFlavor() -> GameFlavor? {
        GameApp.runningApplication().flatMap(GameApp.flavor(of:))
    }

    func isGameFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication.map(GameApp.isGame) ?? false
    }

    func activateGame() {
        guard let game = GameApp.runningApplication() else { return }
        let activate = {
            // macOS 14+ activation is cooperative: the active app has to hand focus over.
            if NSApp != nil, NSApp.isActive { NSApp.yieldActivation(to: game) }
            game.activate()
        }
        if Thread.isMainThread { activate() } else { DispatchQueue.main.async(execute: activate) }
    }

    // MARK: - Capture

    func capture(region: CaptureRegion) async -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else { return .noPermission }
        guard let game = GameApp.runningApplication(), !game.isHidden else {
            invalidate()
            lock.withLock { lastFailure = nil }
            return .gameNotVisible
        }
        return await capture(region: region, ownerPID: game.processIdentifier)
    }

    /// Captures `region` from the main window of process `ownerPID`. Split from the protocol
    /// method so the capture path can be exercised against a window other than the game's.
    func capture(region: CaptureRegion, ownerPID: pid_t, forceDisplayCapture: Bool = false) async -> CaptureResult {
        let wanted = Self.cgRect(fromAppKit: region.rect)
        guard wanted.width >= 8, wanted.height >= 8 else { return .gameNotVisible }

        // One retry: a cached window or filter that went stale fails the first attempt.
        for attempt in 0..<2 {
            let target: Target
            do {
                let found = forceDisplayCapture
                    ? try await lookup(pid: ownerPID, region: wanted, windowAllowed: false)
                    : try await self.target(for: ownerPID, region: wanted)
                guard let found else {
                    // While the lookup is throttled after a failure, the failure still stands.
                    if let standing = lock.withLock({ lastFailure }) { return .failed(standing) }
                    return .gameNotVisible
                }
                target = found
            } catch {
                return failed(error)
            }
            switch await shoot(target, region: wanted) {
            case .success(let image):
                lock.withLock { lastFailure = nil }
                return .image(image)
            case .failure(CaptureError.regionOffContent):
                invalidate(retryNow: true)
                if attempt == 1 { return .gameNotVisible }
            case .failure(let error):
                if Self.isPermissionError(error) {
                    invalidate()
                    return .noPermission
                }
                // The fresh lookup right away is for the first failure only: an error that
                // stays is retried at the pace of the lookup throttle.
                if attempt == 0, lock.withLock({ lastFailure }) == nil {
                    invalidate(retryNow: true)
                } else {
                    return failed(error)
                }
            }
        }
        return .gameNotVisible
    }

    private func failed(_ error: Error) -> CaptureResult {
        let text = Self.describe(error)
        lock.withLock {
            cached = nil
            lastLookup = Date()
            lastFailure = text
        }
        return .failed(text)
    }

    /// Domain and code: enough to look the error up, and free of anything personal.
    static func describe(_ error: Error) -> String {
        if let own = error as? CaptureError { return own == .emptyImage ? "빈 화면" : "영역 밖" }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    // MARK: - Geometry

    /// AppKit global points (origin bottom-left of the primary display, y up) → Quartz global
    /// points (origin top-left of the primary display, y down), the space of SCWindow.frame,
    /// SCDisplay.frame and CGWindowList bounds.
    static func cgRect(fromAppKit rect: CGRect) -> CGRect {
        // The primary display is the one whose Quartz origin is (0,0), whatever screen has focus.
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The part of `region` to capture from content occupying `frame`, or nil when too little
    /// of the region lies on it. A region the user drew a little over the window edge still
    /// works: the part outside is padded black so the picture keeps the region's size.
    static func visiblePart(of region: CGRect, in frame: CGRect) -> CGRect? {
        let part = region.intersection(frame)
        guard !part.isNull, part.width >= 8, part.height >= 8 else { return nil }
        let share = (part.width * part.height) / (region.width * region.height)
        return share >= 0.6 ? part : nil
    }

    // MARK: - Target lookup

    private struct Target {
        var filter: SCContentFilter
        /// Frame of the captured content (window or display) in Quartz global points.
        var frame: CGRect
        var scale: CGFloat
        /// Set for window targets; used to notice moves and closes cheaply.
        var windowID: CGWindowID?
        var pid: pid_t
    }

    private let lock = NSLock()
    private var cached: Target?
    private var lastLookup = Date.distantPast
    /// Description of the capture error that has not been followed by a good capture yet.
    private var lastFailure: String?

    /// `retryNow` also lifts the lookup throttle, for a failure that a fresh lookup may cure.
    private func invalidate(retryNow: Bool = false) {
        lock.withLock {
            cached = nil
            if retryNow { lastLookup = .distantPast }
        }
    }

    /// The cached capture target if it is still right, else a fresh lookup.
    private func target(for pid: pid_t, region: CGRect) async throws -> Target? {
        let (current, last) = lock.withLock { (cached, lastLookup) }
        if let current, current.pid == pid {
            if let id = current.windowID {
                // One window's bounds from the window server: far cheaper than enumerating
                // shareable content, and it needs no screen-recording permission.
                if let live = Self.liveBounds(of: id), live == current.frame {
                    return Self.visiblePart(of: region, in: live) == nil ? nil : current
                }
            } else if Date().timeIntervalSince(last) < 5 {
                // Display fallback: look for the game window again every few seconds.
                return current
            }
        } else if Date().timeIntervalSince(last) < 2 {
            // The game shows no usable window (minimised, other Space): do not enumerate
            // shareable content on every capture tick while waiting for it.
            return nil
        }

        let fresh = try await lookup(pid: pid, region: region)
        lock.withLock {
            cached = fresh
            lastLookup = Date()
            // "Not there" replaces "failed": the status goes back to waiting for the game.
            if fresh == nil { lastFailure = nil }
        }
        return fresh
    }

    /// Bounds of an on-screen window in Quartz global points; nil when it is gone, minimised or
    /// on another Space.
    private static func liveBounds(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = list.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
        return bounds
    }

    private func lookup(pid: pid_t, region: CGRect, windowAllowed: Bool = true) async throws -> Target? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // The game's main window: on screen, normal layer, and the one holding most of the region.
        let windows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0
                && $0.frame.width >= 200 && $0.frame.height >= 150
        }
        func overlap(_ w: SCWindow) -> CGFloat {
            let i = w.frame.intersection(region)
            return i.isNull ? 0 : i.width * i.height
        }
        if windowAllowed, let window = windows.max(by: { overlap($0) < overlap($1) }) {
            guard Self.visiblePart(of: region, in: window.frame) != nil else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return Target(filter: filter, frame: window.frame, scale: CGFloat(filter.pointPixelScale),
                          windowID: window.windowID, pid: pid)
        }

        // The game is running and not hidden, yet none of its windows qualified (an unusual
        // window layer, a helper process owning the surface). If it is the frontmost app its
        // picture is on the display: capture that without our own windows.
        guard !windowAllowed || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let display = content.displays.max(by: { a, b in
                  let ia = a.frame.intersection(region), ib = b.frame.intersection(region)
                  return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
              }),
              Self.visiblePart(of: region, in: display.frame) != nil else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ours = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
        return Target(filter: filter, frame: display.frame, scale: CGFloat(filter.pointPixelScale),
                      windowID: nil, pid: pid)
    }

    // MARK: - Screenshot

    private func shoot(_ target: Target, region: CGRect) async -> Result<CGImage, Error> {
        guard let part = Self.visiblePart(of: region, in: target.frame) else {
            return .failure(CaptureError.regionOffContent)
        }
        let scale = max(1, target.scale)
        let config = SCStreamConfiguration()
        // Region relative to the content's top-left corner, in points.
        config.sourceRect = CGRect(x: part.minX - target.frame.minX, y: part.minY - target.frame.minY,
                                   width: part.width, height: part.height)
        // Native pixels: OCR accuracy lives on them.
        config.width = max(1, Int((part.width * scale).rounded()))
        config.height = max(1, Int((part.height * scale).rounded()))
        config.captureResolution = .best
        config.scalesToFit = false
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.colorSpaceName = CGColorSpace.sRGB

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: target.filter, configuration: config)
            guard image.width >= 8, image.height >= 8 else { return .failure(CaptureError.emptyImage) }
            if part == region { return .success(image) }
            return Self.pad(image, part: part, region: region, scale: scale).map(Result.success)
                ?? .failure(CaptureError.emptyImage)
        } catch {
            return .failure(error)
        }
    }

    /// Places `image` (the pixels of `part`) on a black canvas the size of `region`.
    static func pad(_ image: CGImage, part: CGRect, region: CGRect, scale: CGFloat) -> CGImage? {
        let width = Int((region.width * scale).rounded()), height = Int((region.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .none
        // Quartz rects are y-down, the bitmap context y-up.
        let x = (part.minX - region.minX) * scale
        let y = (region.maxY - part.maxY) * scale
        ctx.draw(image, in: CGRect(x: x.rounded(), y: y.rounded(), width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }

    enum CaptureError: Error, Equatable {
        case regionOffContent
        case emptyImage
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue
    }
}
