import AppKit
import RunespeakCore

/// Owns every part of the app and wires them together: state, windows, hotkeys, the capture
/// loop and the translation queue. All work on the game side is reading pixels of its window;
/// nothing here sends keys or clicks anywhere.
@MainActor
final class AppController: NSObject, AppActions, NSApplicationDelegate, NSMenuDelegate {
    static let historyLimit = 500
    static let recentContextLines = 6
    /// Lines already on screen that are sent for translation when their tab is switched on,
    /// or sent again when the translator changes after they failed.
    static let catchUpLines = 30

    private let paths = AppPaths.default
    private lazy var store = SettingsStore(paths: paths)
    let state = AppState()

    private var glossary: GlossaryStore!
    private var usage: UsageTracker!
    private var hub: TranslatorHub!
    private var chatHistory: ChatHistory!
    private var queue: TranslationQueue!
    private var loop: CaptureLoop!

    private let capturer = ScreenChatCapturer()
    private let recognizer = VisionTextRecognizer()
    private let hotkeys = HotkeyCenter()
    private let selector = RegionSelector()

    private var overlay: OverlayController!
    private var mainWindow: MainWindowController!
    private var settingsWindow: SettingsWindowController!
    private var compose: ComposePanelController!
    private var statusItem: NSStatusItem?

    private let glossaryQueue = DispatchQueue(label: "runespeak.glossary", qos: .utility)
    private var generation = 0
    /// After the tracker starts over it reports everything on screen again; lines already in
    /// the history are dropped until this time.
    private var dedupUntil = Date.distantPast
    /// The user's cover switch (hotkey / menu). The panel also hides while peeking with Option.
    private var coverOn = true
    private var optionDown = false
    private var peekTimer: Timer?
    private var housekeeping: Timer?
    private var noticeGeneration = 0
    private var selectingRegion = false
    private var retranslating: Set<UUID> = []
    /// What the user sent lately: (translated text as pasted, what they typed).
    private var sentLately: [(key: String, original: String)] = []
    private var instanceLock: Int32 = -1
    private var lastQueueError: (TranslationError, Date)?
    private var memo = TranslationMemo()
    private var gameViewObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var gameViewHide: DispatchWorkItem?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try paths.ensureDirectories()
        } catch {
            fatalAlert("데이터 폴더를 만들 수 없습니다.\n\(paths.root.path)\n\(error.localizedDescription)")
            return
        }
        ErrorLog.shared.configure(file: paths.errorsFile)
        guard acquireInstanceLock() else {
            // Another copy is running: bring it forward and leave.
            let me = ProcessInfo.processInfo.processIdentifier
            if let id = Bundle.main.bundleIdentifier {
                NSRunningApplication.runningApplications(withBundleIdentifier: id)
                    .first { $0.processIdentifier != me }?.activate()
            }
            NSApp.terminate(nil)
            return
        }
        NSSetUncaughtExceptionHandler { exception in
            ErrorLog.shared.write("처리되지 않은 예외: \(exception.name.rawValue) \(exception.reason ?? "")")
            ErrorLog.shared.flush()
        }

        state.settings = store.loadSettings()
        state.region = store.loadRegion()
        state.activeFlavor = state.settings.autoDetectFlavor
            ? (capturer.detectRunningFlavor() ?? state.settings.flavor) : state.settings.flavor

        BundledDictionary.install(to: paths)
        glossary = GlossaryStore(paths: paths, flavor: state.activeFlavor)
        state.glossaryCount = glossary.entryCount
        state.abbreviationCount = glossary.abbreviationCount
        // A bare executable (swift build) has no bundled dictionary to copy: say so in the log
        // instead of quietly translating without game names.
        for warning in glossary.loadWarnings { ErrorLog.shared.write(warning) }
        usage = UsageTracker(file: paths.tokenUsageFile)
        chatHistory = ChatHistory(file: paths.chatHistoryFile)
        hub = TranslatorHub(store: store, glossary: glossary, usage: usage)
        state.keyedProviders = hub.keyedProviders
        // A list fetched with a key that has since been removed is of no use.
        state.liveModels = store.loadModelLists().filter { hub.hasKey($0.key) }
        refreshUsage()

        queue = TranslationQueue(
            translator: { [unowned self] in self.hub.translator(for: self.state.settings) },
            context: { [unowned self] batch in self.requestContext(model: self.state.settings.modelID(), excluding: batch) },
            deliver: { [unowned self] outcomes in self.apply(outcomes) })
        queue.onError = { [unowned self] error in self.reportQueueError(error) }
        queue.describe = { [unowned self] error in self.state.errorText(error) }

        state.actions = self
        buildMainMenu()
        buildStatusItem()

        overlay = OverlayController(state: state)
        mainWindow = MainWindowController(state: state)
        settingsWindow = SettingsWindowController(state: state)
        compose = ComposePanelController(state: state)
        compose.onDismiss = { [unowned self] in self.capturer.activateGame() }

        hotkeys.gameBundleIDs = { GameApp.bundleIDs }
        hotkeys.onRegistrationFailed = { [unowned self] id in
            let spec = id == "toggle" ? self.state.settings.toggleHotkey : self.state.settings.composeHotkey
            self.notify(HotkeyCenter.failureMessage(for: spec))
        }
        hotkeys.onOptionChanged = { [unowned self] down in self.optionChanged(down) }
        registerHotkeys()

        loop = CaptureLoop(
            capturer: capturer, recognizer: recognizer,
            config: { [unowned self] in
                CaptureLoop.Config(region: self.selectingRegion ? nil : self.state.region,
                                   interval: self.state.settings.captureInterval,
                                   locale: self.state.settings.clientLocale,
                                   generation: self.generation)
            },
            onStatus: { [unowned self] status in self.setStatus(status) },
            onMessages: { [unowned self] messages, corrections, generation in
                self.receive(messages, replacing: corrections, generation: generation)
            },
            onError: { ErrorLog.shared.write($0) })

        state.gameInView = gameIsInView()
        observeGameView()
        overlay.show()
        mainWindow.show()

        let permitted = capturer.hasPermission()
        if !permitted {
            state.status = .needsScreenRecordingPermission
            capturer.requestPermission()
        } else if state.region == nil {
            state.status = .needsRegion
            // Dimming the screen is only useful with the chat window to drag over in view: a
            // game on another Space (native full screen) or minimised waits for the button.
            if GameApp.hasWindowOnScreen() { beginRegionSelection(fromOwnApp: true) }
        }
        loop.start()

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.houseKeep() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        housekeeping = timer
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mainWindow != nil { mainWindow.show() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        housekeeping?.invalidate()
        gameViewObservers.forEach { $0.0.removeObserver($0.1) }
        peekTimer?.invalidate()
        loop?.stop()
        hotkeys.invalidate()
        queue?.cancelAll()
        if overlay != nil { store.save(state.settings) }
        chatHistory?.flush()
        ErrorLog.shared.flush()
        if instanceLock >= 0 { close(instanceLock) }
    }

    /// An exclusive lock on a file in the data folder; it goes away with the process, so a
    /// crash never leaves the app locked out.
    private func acquireInstanceLock() -> Bool {
        let fd = open(paths.root.appendingPathComponent(".instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        instanceLock = fd
        return true
    }

    private func fatalAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Runespeak을 시작할 수 없습니다"
        alert.informativeText = text
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Menus

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Runespeak에 관하여", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("설정…", #selector(menuSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Runespeak 가리기", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Runespeak 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Without an Edit menu ⌘C / ⌘V / ⌘A do nothing in the key field and the compose panel.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "윈도우")
        window.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(item("기록 창 열기", #selector(menuMainWindow), key: "0"))
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Runespeak") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "번역"
        }
        item.button?.toolTip = "Runespeak"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(self.item("기록 창 열기", #selector(menuMainWindow)))
        let cover = self.item("겹쳐 보기 끄기", #selector(menuToggleOverlay))
        cover.tag = 1
        menu.addItem(cover)
        menu.addItem(self.item("채팅창 위치 잡기", #selector(menuRegion)))
        menu.addItem(self.item("보낼 말 번역", #selector(menuCompose)))
        menu.addItem(.separator())
        menu.addItem(self.item("설정…", #selector(menuSettings)))
        menu.addItem(.separator())
        menu.addItem(self.item("종료", #selector(menuQuit)))
        item.menu = menu
        statusItem = item
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let covering = state.settings.overlayEnabled && coverOn
        menu.item(withTag: 1)?.title = covering ? "겹쳐 보기 끄기" : "겹쳐 보기 켜기"
    }

    @objc private func menuMainWindow() { showMainWindow() }
    @objc private func menuToggleOverlay() { toggleOverlay() }
    @objc private func menuRegion() { beginRegionSelection() }
    @objc private func menuCompose() { showCompose() }
    @objc private func menuSettings() { showSettings() }
    @objc private func menuQuit() { quit() }

    // MARK: - Hotkeys and the cover

    private func registerHotkeys() {
        let settings = state.settings
        hotkeys.register(id: "toggle", spec: settings.toggleHotkey, onlyWhenGameFrontmost: false) { [unowned self] in
            self.toggleOverlay()
        }
        // Shift-Return belongs to every other app; it is grabbed only while the game is in front.
        hotkeys.register(id: "compose", spec: settings.composeHotkey, onlyWhenGameFrontmost: true) { [unowned self] in
            self.showCompose()
        }
    }

    private func optionChanged(_ down: Bool) {
        optionDown = down
        peekTimer?.invalidate()
        peekTimer = nil
        if down {
            // The pointer may move on and off the chat while Option stays down.
            let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyCoverVisibility() }
            }
            RunLoop.main.add(timer, forMode: .common)
            peekTimer = timer
        }
        applyCoverVisibility()
    }

    private func applyCoverVisibility() {
        let peeking = optionDown && coverOn && state.region != nil
            && overlay.window.frame.contains(NSEvent.mouseLocation)
        let visible = coverOn && !peeking
        if state.overlayVisible != visible { state.overlayVisible = visible }
    }

    // MARK: - Pipeline (main-actor side)

    private func setStatus(_ status: PipelineStatus) {
        guard state.status != status else { return }
        state.status = status
        // Minimising the game changes no frontmost app; the capture status is what notices.
        evaluateGameView()
    }

    // MARK: - Is the game what the user is looking at?

    private func observeGameView() {
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceEvents = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                               NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                               NSWorkspace.didLaunchApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification]
        let ownEvents = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
        for (center, names) in [(workspace, workspaceEvents), (NotificationCenter.default, ownEvents)] {
            for name in names {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.evaluateGameView()
                        // Once more when the switch has settled: the window list and the
                        // "active" flags can trail the notification.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.evaluateGameView() }
                    }
                }
                gameViewObservers.append((center, token))
            }
        }
    }

    /// The game is in front (or this app is, with the game's window on the same Space behind
    /// its settings or compose panel) and has a window on screen.
    private func gameIsInView() -> Bool {
        guard let game = GameApp.runningApplication(), !game.isHidden else { return false }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == game.processIdentifier
        guard front || NSApp.isActive else { return false }
        // A capture that works proves the window is there, however the window list describes it.
        return GameApp.hasWindowOnScreen(game) || (front && state.status == .running)
    }

    private func evaluateGameView() {
        if gameIsInView() {
            gameViewHide?.cancel()
            gameViewHide = nil
            if !state.gameInView { state.gameInView = true }
        } else if state.gameInView, gameViewHide == nil {
            // Not at once: focus passes through other apps for a moment when a panel of this
            // app opens or closes, and the cover should not blink.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.gameViewHide = nil
                if !self.gameIsInView() { self.state.gameInView = false }
            }
            gameViewHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    /// `corrections`: for a message that says again, whole, what earlier ones said while part
    /// of the chat row could not be read, the ids of those earlier lines. It takes their place
    /// in the list; a translation still on its way for one of them finds no line and is dropped.
    private func receive(_ messages: [ChatMessage], replacing corrections: [UUID: [UUID]], generation: Int) {
        guard generation == self.generation else { return }
        let settings = state.settings
        var entries = state.entries
        let deduplicating = Date() < dedupUntil
        var toTranslate: [ChatMessage] = []

        for message in messages {
            if deduplicating, entries.suffix(80).contains(where: { TranslationPolicy.sameMessage($0.message, message) }) {
                continue
            }
            var entry = ChatEntry(message: message, state: .original)
            if settings.saveChatLog { chatHistory.append(message: message) }
            if TranslationPolicy.shouldTranslate(message, settings: settings), beginTranslation(of: &entry) {
                toTranslate.append(message)
            }
            entries.place(entry, replacing: corrections[message.id] ?? [])
        }
        if entries.count > Self.historyLimit { entries.removeFirst(entries.count - Self.historyLimit) }
        state.entries = entries
        toTranslate.forEach(queue.enqueue)
    }

    /// Decides how `entry` gets its translation. True when it has to go to the queue; false
    /// when the answer was at hand (the user's own line coming back, a line translated before).
    private func beginTranslation(of entry: inout ChatEntry) -> Bool {
        let message = entry.message
        if let mine = ownOriginal(for: message) {
            // My own pasted translation coming back through the chat: show what I typed.
            entry.state = .translated(mine)
            entry.engine = "보낸 말"
            return false
        }
        if let hit = memo.lookup(message, reader: state.settings.readerLanguage) {
            entry.state = .translated(hit.text)
            entry.note = hit.note
            entry.engine = hit.engine
            if state.settings.saveChatLog { chatHistory.append(translation: hit.text, of: message) }
            return false
        }
        entry.state = .pending
        entry.note = nil
        entry.engine = nil
        return true
    }

    /// Lines of `groups` that arrived while their tab was off: translated now, newest first
    /// up to a limit, so that switching a tab on shows something at once.
    private func translateExisting(in groups: Set<ChannelGroup>) {
        var entries = state.entries
        let chosen = TranslationPolicy.catchUp(entries, groups: groups, reader: state.settings.readerLanguage,
                                               limit: Self.catchUpLines)
        guard !chosen.isEmpty else { return }
        var toTranslate: [ChatMessage] = []
        for index in chosen where beginTranslation(of: &entries[index]) {
            toTranslate.append(entries[index].message)
        }
        state.entries = entries
        toTranslate.forEach(queue.enqueue)
    }

    /// Failed lines get another go once what made them fail may be gone (new key, other
    /// provider or model).
    private func retryFailed() {
        var entries = state.entries
        var again: [ChatMessage] = []
        for index in entries.indices.suffix(80).reversed() where again.count < Self.catchUpLines {
            guard case .failed = entries[index].state, entries[index].message.channel.group != nil,
                  !retranslating.contains(entries[index].id) else { continue }
            entries[index].state = .pending
            again.append(entries[index].message)
        }
        guard !again.isEmpty else { return }
        state.entries = entries
        again.reversed().forEach(queue.retry)
    }

    private func ownOriginal(for message: ChatMessage) -> String? {
        let key = TranslationPolicy.looseKey(message.body)
        guard key.count >= 4 else { return nil }
        return sentLately.last { $0.key == key }?.original
    }

    private func requestContext(model: String, excluding batch: [ChatMessage]) -> TranslationRequestContext {
        let skip = Set(batch.map(\.id))
        // A line that failed tells the model nothing, and one a provider refused would get
        // the next requests refused with it.
        let recent = state.entries.lazy
            .filter { entry in
                if case .failed = entry.state { return false }
                return entry.message.channel.group != nil && !skip.contains(entry.id)
            }
            .suffix(Self.recentContextLines)
            .map(\.message)
        return TranslationRequestContext(reader: state.settings.readerLanguage, flavor: state.activeFlavor,
                                         model: model, recent: Array(recent))
    }

    private func apply(_ outcomes: [TranslationQueue.Outcome]) {
        var entries = state.entries
        var changed = false
        for outcome in outcomes {
            // Newest lines are the likeliest targets.
            guard let index = entries.lastIndex(where: { $0.id == outcome.id }) else { continue }
            // A line retranslated by hand meanwhile keeps the better answer.
            guard entries[index].state == .pending, !retranslating.contains(outcome.id) else { continue }
            entries[index].state = outcome.state
            entries[index].note = outcome.note
            entries[index].engine = outcome.engine
            changed = true
            if case .translated(let text) = outcome.state {
                memo.store(.init(text: text, note: outcome.note, engine: outcome.engine),
                           for: entries[index].message, reader: state.settings.readerLanguage)
                if state.settings.saveChatLog { chatHistory.append(translation: text, of: entries[index].message) }
            }
        }
        if changed { state.entries = entries }
        refreshUsage()
    }

    private func reportQueueError(_ error: TranslationError) {
        ErrorLog.shared.write("번역 요청 실패: \(error)")
        // One notice per kind of failure per half minute is plenty.
        if let (last, time) = lastQueueError, last == error, Date().timeIntervalSince(time) < 30 { return }
        lastQueueError = (error, Date())
        notify(state.errorText(error))
    }

    private func refreshUsage() {
        let today = usage.todayKRW, total = usage.totalKRW
        if state.usageTodayKRW != today { state.usageTodayKRW = today }
        if state.usageTotalKRW != total { state.usageTotalKRW = total }
        let todayIncomplete = usage.todayHasUnknownCost, totalIncomplete = usage.totalHasUnknownCost
        if state.usageTodayIncomplete != todayIncomplete { state.usageTodayIncomplete = todayIncomplete }
        if state.usageTotalIncomplete != totalIncomplete { state.usageTotalIncomplete = totalIncomplete }
    }

    /// Call after the provider, a key or a model changed. Lines still waiting go to the new
    /// translator; requests already sent finish on the one they were sent with.
    private func translatorChanged() {
        guard queue != nil else { return }
        queue.clearErrors()
        lastQueueError = nil
        // Another model may well translate the same line better.
        memo.removeAll()
        retryFailed()
    }

    /// Starts the tracker over (new region, other client language).
    private func restartTracking() {
        generation += 1
        dedupUntil = Date().addingTimeInterval(8)
    }

    private func houseKeep() {
        refreshUsage()
        evaluateGameView()
        guard state.settings.autoDetectFlavor, let running = capturer.detectRunningFlavor() else { return }
        if running != state.settings.flavor {
            // Remembered so the next launch without the game starts with the right data set.
            updateSettings { $0.flavor = running }
        }
        useFlavor(running)
    }

    private func useFlavor(_ flavor: GameFlavor) {
        guard flavor != state.activeFlavor else { return }
        state.activeFlavor = flavor
        reloadGlossary()
    }

    /// Reading the name tables takes a few hundred milliseconds: off the main thread.
    private func reloadGlossary() {
        let flavor = state.activeFlavor
        let glossary = self.glossary!
        glossaryQueue.async { [weak self] in
            glossary.reload(flavor: flavor)
            let count = glossary.entryCount
            let abbreviations = glossary.abbreviationCount
            for warning in glossary.loadWarnings { ErrorLog.shared.write(warning) }
            DispatchQueue.main.async {
                self?.state.glossaryCount = count
                self?.state.abbreviationCount = abbreviations
            }
        }
    }

    private func notify(_ text: String) {
        noticeGeneration += 1
        let generation = noticeGeneration
        state.notice = text
        // Cleared so a window opened later does not replay an old notice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.noticeGeneration == generation else { return }
            self.state.notice = nil
        }
    }

    // MARK: - AppActions

    func beginRegionSelection() {
        beginRegionSelection(fromOwnApp: NSApp.isActive)
    }

    private func beginRegionSelection(fromOwnApp: Bool) {
        guard !selectingRegion else { return }
        selectingRegion = true
        compose.close()
        // The cover would hide the very chat window the user has to drag over.
        overlay.hide()
        // So would this app's own windows, should they end up in front of the game.
        let parked = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
        parked.forEach { $0.orderOut(nil) }
        let game = GameApp.runningApplication()
        selector.select(over: game, fromOwnApp: fromOwnApp) { [weak self] region in
            guard let self else { return }
            self.selectingRegion = false
            // Back in front where the user returns to this app; otherwise behind the game.
            let returnsHere = fromOwnApp && (region == nil || game == nil)
            for window in parked {
                if returnsHere { window.makeKeyAndOrderFront(nil) } else { window.orderBack(nil) }
            }
            if let region {
                self.store.save(region: region)
                self.state.region = region
                // A fresh region means "cover this"; an old dragged-away frame no longer applies.
                if self.state.settings.overlayFrame != nil { self.updateSettings { $0.overlayFrame = nil } }
                self.overlay.applyRegion()
                self.restartTracking()
            }
            self.overlay.show()
        }
    }

    func toggleOverlay() {
        if !state.settings.overlayEnabled {
            // The switch in Settings is off: the hotkey turns covering back on as a whole.
            coverOn = true
            updateSettings { $0.overlayEnabled = true }
        } else {
            coverOn.toggle()
        }
        applyCoverVisibility()
    }

    func showMainWindow() { mainWindow.show() }

    func showSettings() { settingsWindow.show() }

    func showCompose() {
        guard !selectingRegion else { return }
        let near: CGRect? = state.region == nil ? nil
            : (overlay.isPanelVisible ? overlay.window.frame : state.region?.rect)
        compose.show(near: near)
    }

    func submitOutgoing(_ text: String) async -> Result<String, TranslationError> {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return .failure(.badResponse("보낼 말이 없습니다")) }
        let parsed = glossary.parseOutgoing(typed)
        let body = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let final: String
        if body.isEmpty {
            // "/roll 100", "/dance": nothing to translate, hand it back as typed.
            final = parsed.command ?? typed
        } else {
            let translated: String
            do {
                let settings = state.settings
                let context = requestContext(model: settings.modelID(), excluding: [])
                translated = try await hub.translator(for: settings).translateOutgoing(body, to: state.settings.outgoingLanguage, context: context)
            } catch let error as TranslationError {
                ErrorLog.shared.write("보낼 말 번역 실패: \(error)")
                return .failure(error)
            } catch is CancellationError {
                return .failure(.badResponse("취소되었습니다"))
            } catch {
                ErrorLog.shared.write("보낼 말 번역 실패: \(error)")
                return .failure(.badResponse(error.localizedDescription))
            }
            // The chat box counts the slash command against its 255 bytes as well.
            let clean = LLMTranslator.fitChatBox(translated.trimmingCharacters(in: .whitespacesAndNewlines), after: parsed.command)
            guard !clean.isEmpty else { return .failure(.badResponse("번역 결과가 비어 있습니다")) }
            final = parsed.command.map { "\($0) \(clean)" } ?? clean
            sentLately.append((TranslationPolicy.looseKey(clean), body))
            if sentLately.count > 30 { sentLately.removeFirst(sentLately.count - 30) }
        }

        // Only the clipboard is touched; pasting into the game is the user's own keystroke.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(final, forType: .string)
        refreshUsage()
        notify("번역문이 복사되었습니다")
        // Only when the user is still at the panel in this app: the answer can take seconds,
        // and someone who went on to another app meanwhile must not be pulled into the game.
        // (A panel that is key without the app being active hands the keyboard back itself.)
        if NSApp.isActive, compose.isKey { capturer.activateGame() }
        return .success(final)
    }

    func retranslate(entryID: UUID) {
        guard let entry = state.entries.first(where: { $0.id == entryID }) else { return }
        let settings = state.settings
        guard let provider = hub.activeProvider(for: settings) else {
            notify("다시 번역은 AI API 키가 있어야 합니다 (설정 → AI 연결)")
            return
        }
        // A line still waiting has an answer on the way; taking it out of the queue's hands
        // here could leave it waiting for good.
        guard entry.state != .pending else {
            notify("아직 번역하는 중인 줄입니다")
            return
        }
        guard entry.message.channel.group != nil, retranslating.insert(entryID).inserted else { return }
        let before = entry
        var previous: String?
        if case .translated(let text) = entry.state { previous = text }
        update(entryID) { $0.state = .pending }

        let translator = hub.translator(for: settings)
        let context = requestContext(model: settings.retranslateModelID(), excluding: [entry.message])
        let engine = translator.engineName(for: context)
        let glossary = self.glossary!
        Task { @MainActor [weak self] in
            let result: Result<TranslationOutput, Error>
            do {
                result = .success(try await translator.retranslate(entry.message, previous: previous, context: context))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.retranslating.remove(entryID)
            switch result {
            case .success(let output) where !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                self.update(entryID) {
                    $0.state = .translated(output.text)
                    $0.note = output.note
                    $0.engine = engine
                }
                self.memo.store(.init(text: output.text, note: output.note, engine: engine),
                                for: entry.message, reader: self.state.settings.readerLanguage)
                if self.state.settings.saveChatLog { self.chatHistory.append(translation: output.text, of: entry.message) }
                let example = CorrectionExample(source: entry.message.body, translation: output.text, note: output.note)
                self.glossaryQueue.async { glossary.addCorrection(example) }
            case .success:
                self.update(entryID) { $0 = before }
                self.notify("다시 번역하지 못했습니다: 빈 응답")
            case .failure(let error):
                self.update(entryID) { $0 = before }
                let reason = (error as? TranslationError)?.userMessage(for: provider) ?? error.localizedDescription
                ErrorLog.shared.write("다시 번역 실패: \(error)")
                self.notify("다시 번역하지 못했습니다: \(reason)")
            }
            self.refreshUsage()
        }
    }

    func retryTranslation(entryID: UUID) {
        guard let entry = state.entries.first(where: { $0.id == entryID }), case .failed = entry.state,
              entry.message.channel.group != nil, !retranslating.contains(entryID) else { return }
        update(entryID) { $0.state = .pending }
        queue.retry(entry.message)
    }

    private func update(_ id: UUID, _ change: (inout ChatEntry) -> Void) {
        guard let index = state.entries.lastIndex(where: { $0.id == id }) else { return }
        change(&state.entries[index])
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        let old = state.settings
        var new = old
        mutate(&new)
        new = SettingsStore.sanitized(new)
        guard new != old else { return }
        state.settings = new
        store.save(new)

        if new.toggleHotkey != old.toggleHotkey || new.composeHotkey != old.composeHotkey {
            registerHotkeys()
        }
        if new.clientLocale != old.clientLocale { restartTracking() }
        if new.provider != old.provider || new.modelID() != old.modelID()
            || new.retranslateModelID() != old.retranslateModelID() {
            translatorChanged()
        }
        if new.overlayEnabled, !old.overlayEnabled {
            coverOn = true
            applyCoverVisibility()
        }
        let switchedOn = new.enabledGroups.subtracting(old.enabledGroups)
        if !switchedOn.isEmpty, queue != nil { translateExisting(in: switchedOn) }
        if new.flavor != old.flavor || new.autoDetectFlavor != old.autoDetectFlavor {
            let detected = new.autoDetectFlavor ? capturer.detectRunningFlavor() : nil
            useFlavor(detected ?? new.flavor)
        }
    }

    func saveAPIKey(_ key: String, for provider: AIProvider) {
        let before = hub.key(for: provider)
        hub.setKey(key, for: provider)
        guard hub.key(for: provider) != before else { return }
        state.keyedProviders = hub.keyedProviders
        // Another key may belong to another account with other models.
        if state.liveModels[provider] != nil {
            state.liveModels[provider] = nil
            store.save(modelLists: state.liveModels)
        }
        if provider == state.settings.provider { translatorChanged() }
    }

    func refreshModels(for provider: AIProvider) async -> Result<[ModelInfo], TranslationError> {
        guard let key = hub.key(for: provider) else { return .failure(.missingAPIKey) }
        let result: Result<[ModelInfo], TranslationError>
        do {
            result = .success(try await ModelCatalog.listModels(provider: provider, apiKey: key))
        } catch let error as TranslationError {
            result = .failure(error)
        } catch is CancellationError {
            result = .failure(.network("취소되었습니다"))
        } catch {
            result = .failure(.network(error.localizedDescription))
        }
        // The key was replaced or removed while the request was out: the answer is about the old one.
        guard hub.key(for: provider) == key else { return .failure(.network("키가 바뀌었습니다. 다시 눌러 주세요")) }
        switch result {
        case .success(let models):
            state.liveModels[provider] = models
            store.save(modelLists: state.liveModels)
            // A key that works clears the pause a key error had set.
            if provider == state.settings.provider { translatorChanged() }
        case .failure(let error):
            ErrorLog.shared.write("\(provider.rawValue) 모델 목록 요청 실패: \(error)")
        }
        return result
    }

    func openDataFolder() {
        try? paths.ensureDirectories()
        let mine = paths.myTermsFile
        if !FileManager.default.fileExists(atPath: mine.path) {
            let template = """
            # my_terms.tsv — Runespeak이 번역할 때 그대로 따를 내 이름표
            #
            # 한 줄에 이름 하나씩, 칸은 탭(Tab) 키로 나눕니다.
            #   첫째 칸  한국어 이름
            #   둘째 칸  영어 이름
            #   셋째 칸  다르게 부르는 말. 여럿이면 쉼표로 잇고, 없으면 비워 둡니다.
            #            별칭 뒤에 괄호를 달아 어떤 때 그 뜻인지 적어 둘 수 있습니다.
            # 보기)  오그리마 ⇥ Orgrimmar ⇥ OG, 오그, Org (the Horde capital)
            #
            # - 영문 대문자 두 자뿐인 별칭(OG)은 채팅에도 대문자로 적혀 있어야 그 이름으로 칩니다.
            #   세 자부터는 대문자든 소문자든 같습니다.
            # - 앱에 든 사전과 겹치는 이름은 이 파일 쪽을 씁니다.
            # - #으로 시작하는 줄은 건너뜁니다.
            # - 고친 내용은 Runespeak을 다시 실행해야 적용됩니다.
            korean\tenglish\taliases

            """
            try? template.write(to: mine, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(paths.root)
    }

    func clearHistory() {
        queue.cancelAll()
        retranslating.removeAll()
        state.entries = []
    }

    func relaunch() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            notify("앱(.app)으로 실행했을 때만 다시 실행할 수 있습니다. 직접 껐다 켜 주세요")
            return
        }
        // A second copy cannot start while this one holds the instance lock, so a helper waits
        // for this process to end first.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                            bundle.path]
        do {
            try helper.run()
        } catch {
            notify("다시 실행하지 못했습니다. 직접 껐다 켜 주세요")
            return
        }
        NSApp.terminate(nil)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
