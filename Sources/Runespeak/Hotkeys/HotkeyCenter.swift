import AppKit
import Carbon.HIToolbox
import RunespeakCore

/// Global hotkeys through Carbon RegisterEventHotKey, which needs no Accessibility or Input
/// Monitoring permission. Use from the main thread only.
@MainActor
final class HotkeyCenter {
    /// Bundle identifiers that count as "the game". Defaults to the identifiers found in the
    /// World of Warcraft install folder; integration may point this at `GameApp.bundleIDs`.
    var gameBundleIDs: () -> Set<String> = { HotkeyCenter.installedGameBundleIDs }

    /// Called with the binding id when the system refuses the combination
    /// (normally because another app already holds it).
    var onRegistrationFailed: ((String) -> Void)?

    /// Called on the main queue when Option alone goes down / up.
    var onOptionChanged: ((Bool) -> Void)? {
        didSet { updateOptionPolling() }
    }

    private struct Binding {
        let spec: HotkeySpec
        let gameOnly: Bool
        let handler: @MainActor () -> Void
        let carbonID: UInt32
        var ref: EventHotKeyRef?
        var failureReported = false
    }

    private var bindings: [String: Binding] = [:]
    private var frontmostBundleID: String?
    private var observers: [NSObjectProtocol] = []
    private var optionTimer: Timer?
    private var optionDown = false

    init() {
        HotkeyCenter.installCarbonHandlerIfNeeded()
        HotkeyCenter.instances.append(WeakBox(self))
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.frontmostChanged(to: bundleID) }
        })
        // Release the game-only keys as soon as the game steps back, without waiting for the
        // next app's activation notice.
        observers.append(nc.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, bundleID != nil, bundleID == self.frontmostBundleID else { return }
                self.frontmostChanged(to: nil)
            }
        })
    }

    // MARK: - Registration

    /// Re-registering an id replaces its previous binding. The handler runs on the main thread.
    func register(id: String, spec: HotkeySpec, onlyWhenGameFrontmost: Bool, handler: @escaping @MainActor () -> Void) {
        unregister(id: id)
        HotkeyCenter.nextCarbonID += 1
        let carbonID = HotkeyCenter.nextCarbonID
        bindings[id] = Binding(spec: spec, gameOnly: onlyWhenGameFrontmost, handler: handler, carbonID: carbonID)
        HotkeyCenter.routes[carbonID] = Route(center: WeakBox(self), id: id)
        refresh(id)
    }

    func unregister(id: String) {
        guard let binding = bindings.removeValue(forKey: id) else { return }
        if let ref = binding.ref { UnregisterEventHotKey(ref) }
        HotkeyCenter.routes[binding.carbonID] = nil
    }

    func unregisterAll() {
        for id in Array(bindings.keys) { unregister(id: id) }
    }

    /// Releases everything: hotkeys, the Option timer and the workspace observers.
    func invalidate() {
        unregisterAll()
        onOptionChanged = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
    }

    /// True while the combination is actually held from the system (false for a game-only
    /// binding when the game is not frontmost, and for a binding the system refused).
    func isActive(id: String) -> Bool { bindings[id]?.ref != nil }

    var isGameFrontmost: Bool {
        guard let id = frontmostBundleID else { return false }
        return gameBundleIDs().contains(id)
    }

    /// Korean one-liner for `onRegistrationFailed`.
    static func failureMessage(for spec: HotkeySpec) -> String {
        "단축키 \(spec.displayString)를 등록하지 못했습니다. 다른 앱이 쓰고 있는 조합일 수 있습니다."
    }

    // MARK: - Suspension (hotkey recorder)

    /// While a recorder field is listening, every hotkey is released so that pressing the
    /// current combination reaches the recorder instead of firing.
    static func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        instances.removeAll { $0.value == nil }
        for box in instances { box.value?.refreshAll() }
    }

    private(set) static var isSuspended = false

    // MARK: - Internals

    private func frontmostChanged(to bundleID: String?) {
        frontmostBundleID = bundleID
        refreshAll()
    }

    private func refreshAll() {
        for id in bindings.keys { refresh(id) }
    }

    private func refresh(_ id: String) {
        guard var binding = bindings[id] else { return }
        let wanted = !HotkeyCenter.isSuspended && (!binding.gameOnly || isGameFrontmost)
        if wanted, binding.ref == nil {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: HotkeyCenter.signature, id: binding.carbonID)
            let status = RegisterEventHotKey(binding.spec.keyCode, binding.spec.carbonModifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                binding.ref = ref
                binding.failureReported = false
                bindings[id] = binding
            } else if !binding.failureReported {
                // A game-only binding retries on every activation; report it once.
                binding.failureReported = true
                bindings[id] = binding
                onRegistrationFailed?(id)
            }
        } else if !wanted, let ref = binding.ref {
            UnregisterEventHotKey(ref)
            binding.ref = nil
            bindings[id] = binding
        }
    }

    private func fire(_ id: String) {
        guard let binding = bindings[id], binding.ref != nil else { return }
        binding.handler()
    }

    // MARK: - Option peek

    private func updateOptionPolling() {
        if onOptionChanged == nil {
            optionTimer?.invalidate()
            optionTimer = nil
            optionDown = false
            return
        }
        guard optionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollOption() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        optionTimer = timer
    }

    private func pollOption() {
        // Option together with ⌃/⌘/⇧ is a shortcut being typed (⌃⌥T), not a peek.
        let flags = NSEvent.modifierFlags.intersection([.option, .control, .command, .shift])
        let down = flags == .option
        guard down != optionDown else { return }
        optionDown = down
        onOptionChanged?(down)
    }

    // MARK: - Carbon plumbing (shared by all instances)

    private final class WeakBox {
        weak var value: HotkeyCenter?
        init(_ value: HotkeyCenter) { self.value = value }
    }

    private struct Route {
        let center: WeakBox
        let id: String
    }

    private static let signature: OSType = 0x524E_534B // 'RNSK'
    private static var nextCarbonID: UInt32 = 0
    private static var routes: [UInt32: Route] = [:]
    private static var instances: [WeakBox] = []
    private static var handlerInstalled = false

    private static func installCarbonHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let signature = hotKeyID.signature, carbonID = hotKeyID.id
            // Carbon delivers hotkey events on the main thread's event loop.
            MainActor.assumeIsolated { HotkeyCenter.dispatch(signature: signature, carbonID: carbonID) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private static func dispatch(signature: OSType, carbonID: UInt32) {
        guard signature == HotkeyCenter.signature, let route = routes[carbonID] else { return }
        route.center.value?.fire(route.id)
    }

    /// Bundle identifiers of the game apps installed under /Applications/World of Warcraft/_*_/.
    nonisolated static let installedGameBundleIDs: Set<String> = {
        var ids: Set<String> = ["com.blizzard.worldofwarcraft"]
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/Applications/World of Warcraft", isDirectory: true)
        let flavors = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in flavors where dir.lastPathComponent.hasPrefix("_") && dir.lastPathComponent.hasSuffix("_") {
            let apps = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for app in apps where app.pathExtension == "app" {
                if let id = Bundle(url: app)?.bundleIdentifier { ids.insert(id) }
            }
        }
        return ids
    }()
}
