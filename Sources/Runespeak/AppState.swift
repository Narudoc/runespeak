import AppKit
import Combine
import RunespeakCore

// Shared UI state + the action surface the UI calls. UI modules read `AppState` and call
// `AppActions`; `AppController` owns both.

enum PipelineStatus: Equatable {
    case starting
    case running
    case needsScreenRecordingPermission
    case needsRegion
    /// Game not running / minimised / chat region not visible.
    case pausedGameNotVisible
    case error(String)

    var koreanText: String {
        switch self {
        case .starting: return "시작하는 중…"
        case .running: return "채팅을 읽고 있습니다"
        // The switch in System Settings can look on while this build is still refused: macOS ties the
        // permission to the build's signature, and an ad-hoc signed update is a different build to it.
        case .needsScreenRecordingPermission: return "지금 설치된 Runespeak에는 화면 기록이 허용되어 있지 않습니다 · [시스템 설정 열기]에서 Runespeak을 켠 뒤 [다시 실행]을 눌러 주세요. 스위치가 이미 켜져 있다면(앱을 새 버전으로 바꾼 뒤) 껐다가 다시 켜거나, 목록에서 [−]로 지우고 새로 허용해 주세요"
        case .needsRegion: return "읽을 채팅창 위치가 아직 없습니다 · 게임을 띄운 상태로 [채팅창 위치 잡기]를 누르면 게임 화면에서 바로 고를 수 있습니다"
        case .pausedGameNotVisible: return "대기 중 · 화면에서 게임 채팅창을 찾을 수 없습니다"
        case .error(let m): return "오류: \(m)"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    /// History, oldest first. Capped by the controller (keeps the newest ~500).
    @Published var entries: [ChatEntry] = []
    @Published var status: PipelineStatus = .starting
    @Published var settings = AppSettings()
    @Published var region: CaptureRegion?
    /// Providers with a stored API key. The keys themselves never reach the UI.
    @Published var keyedProviders: Set<AIProvider> = []
    /// Model lists fetched with each provider's key ("모델 목록 새로 고침"); empty until fetched.
    @Published var liveModels: [AIProvider: [ModelInfo]] = [:]
    /// Number of dictionary names loaded; 0 means the app bundle came without its dictionary.
    @Published var glossaryCount = 0
    @Published var abbreviationCount = 0
    @Published var usageTodayKRW: Double = 0
    @Published var usageTotalKRW: Double = 0
    /// The amounts above leave out models whose price is not in the built-in table.
    @Published var usageTodayIncomplete = false
    @Published var usageTotalIncomplete = false
    /// False while the user toggled the cover off (Control-Option-T) or is holding Option to peek.
    @Published var overlayVisible = true
    /// False while the game is not what the user is looking at (another app in front, the game
    /// minimised, hidden, on another Space or not running): the cover has nothing to cover.
    @Published var gameInView = true
    /// Flavor actually in use (after auto-detection).
    @Published var activeFlavor: GameFlavor = .classic
    /// One-line transient notice shown in the main window and the overlay ("번역문이 복사되었습니다").
    @Published var notice: String?

    weak var actions: AppActions?

    func hasKey(_ provider: AIProvider) -> Bool { keyedProviders.contains(provider) }

    /// The selected provider has a key; without one the free translator is in use.
    var hasAPIKey: Bool { hasKey(settings.provider) }

    /// The provider translating right now; nil while the free translator is in use.
    var activeProvider: AIProvider? { hasAPIKey ? settings.provider : nil }

    /// Models to offer for `provider`: the built-in list, then what its key's own list adds,
    /// then the ids in use that are in neither (typed by hand).
    func models(for provider: AIProvider) -> [ModelInfo] {
        var models = ModelCatalog.builtIn(provider)
        var seen = Set(models.map(\.id))
        for model in liveModels[provider] ?? [] where seen.insert(model.id).inserted {
            models.append(model)
        }
        for id in [settings.modelID(for: provider), settings.retranslateModelID(for: provider)] where seen.insert(id).inserted {
            models.append(ModelInfo(provider: provider, id: id, displayName: id,
                                    price: ModelCatalog.price(provider: provider, modelID: id)))
        }
        return models
    }

    /// Display name of a model id, also for one known only from the fetched list.
    func modelName(_ id: String, provider: AIProvider) -> String {
        if ModelCatalog.info(provider: provider, modelID: id)?.id == id {
            return ModelCatalog.displayName(provider: provider, modelID: id)
        }
        return liveModels[provider]?.first { $0.id == id }?.displayName ?? id
    }

    /// Name of what translates live chat right now, for status lines.
    var activeEngineTitle: String {
        guard let provider = activeProvider else { return "MyMemory (무료)" }
        return modelName(settings.modelID(for: provider), provider: provider)
    }

    func errorText(_ error: TranslationError) -> String {
        error.userMessage(for: activeProvider)
    }

    /// "약 1,200원" plus a marker when some usage could not be priced.
    static func costText(_ krw: Double, incomplete: Bool) -> String {
        OverlayChatFormat.formatKRW(krw) + (incomplete ? " + 일부 모델 단가 미상" : "")
    }

    /// Entries the overlay shows: only channels whose group is enabled (all, when no group is enabled).
    var overlayEntries: [ChatEntry] {
        let groups = settings.enabledGroups
        if groups.isEmpty { return entries }
        return entries.filter { e in e.message.channel.group.map(groups.contains) ?? false }
    }
}

/// Everything the UI can ask the app to do. Implemented by AppController. All calls on the main actor.
@MainActor
protocol AppActions: AnyObject {
    /// Dims the screen and lets the user drag over the game chat window.
    func beginRegionSelection()
    func toggleOverlay()
    func showMainWindow()
    func showSettings()
    /// Opens the input panel for the user's own chat (Shift-Return in game).
    func showCompose()
    /// Translates the user's text, copies the result to the clipboard, returns to the game.
    /// Returns the copied text.
    func submitOutgoing(_ text: String) async -> Result<String, TranslationError>
    func retranslate(entryID: UUID)
    /// Sends a failed line through the ordinary translator once more (no bigger model, nothing
    /// written to corrections.tsv).
    func retryTranslation(entryID: UUID)
    /// Persists and applies new settings (hotkeys, model, groups, font size ...).
    func updateSettings(_ mutate: (inout AppSettings) -> Void)
    /// Stores `provider`'s key; an empty string removes it.
    func saveAPIKey(_ key: String, for provider: AIProvider)
    /// Fetches the models `provider`'s stored key can use and keeps them in `AppState.liveModels`.
    /// Doubles as the connection check: it is one authenticated request that costs nothing.
    func refreshModels(for provider: AIProvider) async -> Result<[ModelInfo], TranslationError>
    func openDataFolder()
    func clearHistory()
    /// Quits and starts the app again (a screen-recording grant only takes effect that way).
    func relaunch()
    func quit()
}

// MARK: - Capture / OCR contracts (implemented in Capture/)
//
//   final class ScreenChatCapturer: ChatCapturing     init()
//   final class VisionTextRecognizer: TextRecognizing init()
//   final class RegionSelector                         // dim-and-drag UI
//       @MainActor func select(completion: @escaping (CaptureRegion?) -> Void)   // nil = cancelled (Esc / right click)

enum CaptureResult {
    case image(CGImage)
    /// WoW is not running, minimised, or the region is not on any display.
    case gameNotVisible
    case noPermission
    /// The game is there but the system would not deliver its picture. Carries a short
    /// technical description (error domain and code) for the log and the status line.
    case failed(String)
}

protocol ChatCapturing: AnyObject {
    func hasPermission() -> Bool
    /// Triggers the system prompt / opens System Settings.
    func requestPermission()
    /// Captures the pixels of `region` WITHOUT this app's own windows in the picture
    /// (the overlay sits on top of the game chat and must not be read back).
    func capture(region: CaptureRegion) async -> CaptureResult
    /// Install folder flavour of the running game, if it can be told from the process path.
    func detectRunningFlavor() -> GameFlavor?
    /// True when World of Warcraft is the frontmost application.
    func isGameFrontmost() -> Bool
    /// Brings the game back to the front (after the compose panel closes).
    func activateGame()
}

protocol TextRecognizing: AnyObject {
    /// Recognises the chat text in `image`. Lines sorted top to bottom, colour sampled per line.
    func recognize(_ image: CGImage, clientLocale: ClientLocale) async throws -> OCRFrame
}

// MARK: - Hotkeys contract (implemented in Hotkeys/)
//
//   @MainActor final class HotkeyCenter      init()
//       /// `onlyWhenGameFrontmost`: the key is grabbed only while World of Warcraft is the frontmost
//       /// app (Shift-Return must reach every other app untouched), so the center registers and
//       /// unregisters the Carbon hotkey as the frontmost app changes.
//       func register(id: String, spec: HotkeySpec, onlyWhenGameFrontmost: Bool, handler: @escaping @MainActor () -> Void)
//       func unregister(id: String)
//       func unregisterAll()
//       func invalidate()                               // hotkeys, Option polling and observers
//       var gameBundleIDs: () -> Set<String>            // AppController points it at GameApp.bundleIDs
//       var onRegistrationFailed: ((String) -> Void)?   // binding id; the combination is taken
//       /// Calls back on the main queue when Option goes down / up (peek at the original chat).
//       /// Works WITHOUT Accessibility / Input Monitoring permission (polls NSEvent.modifierFlags).
//       var onOptionChanged: ((Bool) -> Void)?
//   enum GameApp { static let bundleIDs: Set<String> }   // defined in Capture/: "com.blizzard.worldofwarcraft"

// MARK: - Window contracts (Overlay/, MainWindow/, Settings/, Compose/)
//
//   final class OverlayController        init(state: AppState)
//       func show(); func hide(); func applyRegion()   // re-reads state.region / settings.overlayFrame
//   final class MainWindowController     init(state: AppState);  func show()
//   final class SettingsWindowController init(state: AppState);  func show()
//   final class ComposePanelController   init(state: AppState);  func show(near rect: CGRect?); func close()
