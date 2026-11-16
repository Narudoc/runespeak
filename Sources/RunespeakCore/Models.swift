import Foundation
import CoreGraphics

// Shared value types. Every module depends on this file; do not change it from a module —
// report a needed change instead.

/// sRGB colour, components 0...1.
public struct RGBColor: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    public static let white = RGBColor(r: 1, g: 1, b: 1)
}

/// Which game data set to use. `classic` covers Classic Era, Anniversary and Classic progression
/// realms (the `.classic.tsv` dictionary files); `retail` is the live game (`.retail.tsv`).
public enum GameFlavor: String, Codable, Sendable, CaseIterable {
    case retail
    case classic
}

/// Language of the WoW client UI (decides how channel prefixes look: "[길드]" vs "[Guild]").
public enum ClientLocale: String, Codable, Sendable, CaseIterable {
    case koKR
    case enUS
}

/// Language the user reads. `.korean`: foreign chat → Korean. `.english`: non-English chat → English.
public enum ReaderLanguage: String, Codable, Sendable, CaseIterable {
    case korean
    case english
}

public enum ChatChannel: String, Codable, Sendable, CaseIterable {
    case guild, officer
    case party, raid, raidWarning, instance
    case whisper          // incoming and outgoing whispers
    case say, yell, emote
    case publicChannel    // numbered channels: [1. General], [2. 거래], LookingForGroup ...
    case system           // loot, XP, system notices — never translated
    case unknown
}

/// The tabs shown on the overlay; the user enables/disables translation per group.
public enum ChannelGroup: String, Codable, Sendable, CaseIterable {
    case guild      // guild, officer
    case group      // party, raid, raidWarning, instance
    case whisper
    case general    // say, yell, emote
    case publicChannel

    public var koreanTitle: String {
        switch self {
        case .guild: return "길드"
        case .group: return "파티/공격대"
        case .whisper: return "귓속말"
        case .general: return "일반/외침"
        case .publicChannel: return "공개 채널"
        }
    }
}

public extension ChatChannel {
    /// nil for system/unknown lines, which are never translated.
    var group: ChannelGroup? {
        switch self {
        case .guild, .officer: return .guild
        case .party, .raid, .raidWarning, .instance: return .group
        case .whisper: return .whisper
        case .say, .yell, .emote: return .general
        case .publicChannel: return .publicChannel
        case .system, .unknown: return nil
        }
    }
}

/// One text line as recognised by OCR.
public struct OCRLine: Sendable, Hashable {
    public var text: String
    /// Bounding box in pixels of the captured image, origin TOP-left.
    public var box: CGRect
    /// Dominant colour of the glyphs (not the background).
    public var color: RGBColor
    /// 0...1
    public var confidence: Double
    public init(text: String, box: CGRect, color: RGBColor, confidence: Double) {
        self.text = text; self.box = box; self.color = color; self.confidence = confidence
    }
}

/// All lines recognised in one capture of the chat region, sorted top to bottom.
public struct OCRFrame: Sendable {
    public var lines: [OCRLine]
    /// Pixel size of the captured image.
    public var imageSize: CGSize
    /// The chat window has an opaque background: its rows stand on plain black, and nothing of
    /// the game world shows through. What the recogniser saw (`--replay-image` prints it);
    /// the tracker reads such a frame like any other.
    public var opaqueBackground: Bool
    public init(lines: [OCRLine], imageSize: CGSize, opaqueBackground: Bool = false) {
        self.lines = lines; self.imageSize = imageSize; self.opaqueBackground = opaqueBackground
    }
}

/// One logical chat message (wrapped screen lines already merged).
public struct ChatMessage: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var channel: ChatChannel
    /// Channel tag as shown in game, without brackets, e.g. "길드", "2. 거래". nil if none.
    public var channelLabel: String?
    /// Speaker name without brackets/realm decorations where possible. nil for system lines.
    public var sender: String?
    /// Message text only (no channel tag, no sender).
    public var body: String
    /// Full text as read from screen.
    public var rawText: String
    public var color: RGBColor
    public var firstSeen: Date
    /// Wrapped rows of a message whose first row (channel tag and speaker) could not be read:
    /// the end of something somebody said, without its beginning. Shown as it was read, never
    /// sent for translation by itself, and replaced by the whole message once that is read
    /// (`ChatTracker.corrections`).
    public var isFragment: Bool
    public init(id: UUID = UUID(), channel: ChatChannel, channelLabel: String?, sender: String?,
                body: String, rawText: String, color: RGBColor, firstSeen: Date, isFragment: Bool = false) {
        self.id = id; self.channel = channel; self.channelLabel = channelLabel; self.sender = sender
        self.body = body; self.rawText = rawText; self.color = color; self.firstSeen = firstSeen
        self.isFragment = isFragment
    }

    // Tolerant decoding: a message stored before `isFragment` existed is no fragment.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        channel = try c.decode(ChatChannel.self, forKey: .channel)
        channelLabel = try c.decodeIfPresent(String.self, forKey: .channelLabel)
        sender = try c.decodeIfPresent(String.self, forKey: .sender)
        body = try c.decode(String.self, forKey: .body)
        rawText = try c.decode(String.self, forKey: .rawText)
        color = try c.decode(RGBColor.self, forKey: .color)
        firstSeen = try c.decode(Date.self, forKey: .firstSeen)
        isFragment = try c.decodeIfPresent(Bool.self, forKey: .isFragment) ?? false
    }
}

public enum TranslationState: Sendable, Hashable {
    /// Not sent for translation: already in the reader's language, channel disabled, system line...
    case original
    case pending
    case translated(String)
    case failed(String)   // user-facing reason, Korean
}

/// A row in the overlay / history list.
public struct ChatEntry: Identifiable, Sendable, Hashable {
    public var message: ChatMessage
    public var state: TranslationState
    /// Optional explanation from a retranslation ("mara는 마라우돈을 줄여 부르는 말입니다").
    public var note: String?
    /// Name of the model/service that produced the translation ("Haiku", "MyMemory").
    public var engine: String?
    public var id: UUID { message.id }
    public init(message: ChatMessage, state: TranslationState, note: String? = nil, engine: String? = nil) {
        self.message = message; self.state = state; self.note = note; self.engine = engine
    }
    /// Text to show: the translation if there is one, else the original body.
    public var displayBody: String {
        if case .translated(let t) = state { return t }
        return message.body
    }
}

/// Which LLM service translates. Raw values are persisted (settings.json, token_usage.json, key file names).
public enum AIProvider: String, Codable, Sendable, CaseIterable {
    case claude, openai, gemini

    /// Name for pickers.
    public var title: String {
        switch self {
        case .claude: return "Claude (Anthropic)"
        case .openai: return "ChatGPT (OpenAI)"
        case .gemini: return "Gemini (Google)"
        }
    }
    /// Short name for inline messages: "Claude API 키가 없습니다".
    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "ChatGPT"
        case .gemini: return "Gemini"
        }
    }
    /// The company the chat text is sent to and that bills for it.
    public var companyName: String {
        switch self {
        case .claude: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini: return "Google"
        }
    }
    /// Page where the user creates an API key.
    public var keyConsoleURL: URL {
        switch self {
        case .claude: return URL(string: "https://platform.claude.com/settings/keys")!
        case .openai: return URL(string: "https://platform.openai.com/settings/organization/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/api-keys")!
        }
    }
    /// What a key of this provider usually looks like, for the paste field's placeholder.
    public var keyFormatHint: String {
        switch self {
        case .claude: return "sk-ant-… 로 시작"
        case .openai: return "sk-… 로 시작"
        case .gemini: return "보통 AIza… 로 시작"
        }
    }
    /// False when `key` clearly does not look like this provider's key (wrong box, truncated paste).
    /// Only a hint for a "확인해 주세요" notice; formats change, so never block saving on it.
    public func looksLikeKey(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count >= 20, !k.contains(where: \.isWhitespace) else { return false }
        switch self {
        case .claude: return k.hasPrefix("sk-ant-")
        case .openai: return k.hasPrefix("sk-") && !k.hasPrefix("sk-ant-")
        case .gemini: return !k.hasPrefix("sk-")
        }
    }
}

/// Short names for the three Claude tiers, a convenience over the Claude model ids. Settings and
/// requests carry model id strings.
public enum ModelChoice: String, Codable, Sendable, CaseIterable {
    case haiku, sonnet, opus

    public var modelID: String {
        switch self {
        case .haiku: return "claude-haiku-5-5"
        case .sonnet: return "claude-sonnet-5-5"
        case .opus: return "claude-opus-5-5"
        }
    }
    public var title: String {
        switch self {
        case .haiku: return "Haiku (빠르고 저렴)"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus (가장 정확)"
        }
    }
    /// The tier a Claude model id belongs to ("claude-haiku-4-5-20251001" → .haiku); nil for other ids.
    public init?(modelID: String) {
        let id = modelID.lowercased()
        if id.contains("haiku") { self = .haiku }
        else if id.contains("sonnet") { self = .sonnet }
        else if id.contains("opus") { self = .opus }
        else { return nil }
    }
}

/// A global hotkey: Carbon virtual key code + modifier flags.
public struct HotkeySpec: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool
    public init(keyCode: UInt32, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode; self.command = command; self.option = option; self.control = control; self.shift = shift
    }
    /// Control-Option-T  (kVK_ANSI_T = 17)
    public static let defaultToggle = HotkeySpec(keyCode: 17, option: true, control: true)
    /// Shift-Return      (kVK_Return = 36)
    public static let defaultCompose = HotkeySpec(keyCode: 36, shift: true)
}

/// Where the game chat window is on screen.
public struct CaptureRegion: Codable, Hashable, Sendable {
    /// Global AppKit screen coordinates in POINTS, origin BOTTOM-left of the primary display
    /// (the same space as NSWindow.frame / NSScreen.frame).
    public var rect: CGRect
    public init(rect: CGRect) { self.rect = rect }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var flavor: GameFlavor = .classic
    /// When true the app picks `flavor` from the running game's install folder (_retail_ vs others).
    public var autoDetectFlavor: Bool = true
    public var clientLocale: ClientLocale = .koKR
    public var readerLanguage: ReaderLanguage = .korean
    /// Language my own chat is translated into, as an English language name ("English", "Spanish"...).
    public var outgoingLanguage: String = "English"
    /// The service that translates when its API key is present.
    public var provider: AIProvider = .claude
    /// Model id for live translation per provider, keyed by `AIProvider.rawValue`. A provider
    /// without an entry uses its built-in default — read through `modelID(for:)`.
    public var translationModels: [String: String] = [:]
    /// Model id for "다시 번역" per provider — read through `retranslateModelID(for:)`.
    public var retranslationModels: [String: String] = [:]
    public var enabledGroups: Set<ChannelGroup> = [.guild, .group, .whisper]
    public var fontSize: Double = 14
    public var overlayEnabled: Bool = true
    public var overlayOpacity: Double = 0.95
    /// Overlay frame if the user moved/resized it (same coordinate space as CaptureRegion.rect). nil = cover the region.
    public var overlayFrame: CGRect? = nil
    /// When false the overlay is excluded from screenshots/recordings.
    public var showOverlayInCaptures: Bool = false
    public var toggleHotkey: HotkeySpec = .defaultToggle
    public var composeHotkey: HotkeySpec = .defaultCompose
    /// Seconds between captures.
    public var captureInterval: Double = 0.7
    public var saveChatLog: Bool = true

    public init() {}

    // Tolerant decoding: missing keys fall back to defaults so a file that lacks some keeps working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        flavor = try c.decodeIfPresent(GameFlavor.self, forKey: .flavor) ?? d.flavor
        autoDetectFlavor = try c.decodeIfPresent(Bool.self, forKey: .autoDetectFlavor) ?? d.autoDetectFlavor
        clientLocale = try c.decodeIfPresent(ClientLocale.self, forKey: .clientLocale) ?? d.clientLocale
        readerLanguage = try c.decodeIfPresent(ReaderLanguage.self, forKey: .readerLanguage) ?? d.readerLanguage
        outgoingLanguage = try c.decodeIfPresent(String.self, forKey: .outgoingLanguage) ?? d.outgoingLanguage
        // try? throughout: a value written by a newer version (an unknown provider) or damaged
        // by hand must not make the whole settings file unreadable.
        provider = (try? c.decodeIfPresent(AIProvider.self, forKey: .provider)) ?? d.provider
        translationModels = Self.cleaned((try? c.decodeIfPresent([String: String].self, forKey: .translationModels)) ?? [:])
        retranslationModels = Self.cleaned((try? c.decodeIfPresent([String: String].self, forKey: .retranslationModels)) ?? [:])
        enabledGroups = try c.decodeIfPresent(Set<ChannelGroup>.self, forKey: .enabledGroups) ?? d.enabledGroups
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        overlayEnabled = try c.decodeIfPresent(Bool.self, forKey: .overlayEnabled) ?? d.overlayEnabled
        overlayOpacity = try c.decodeIfPresent(Double.self, forKey: .overlayOpacity) ?? d.overlayOpacity
        overlayFrame = try c.decodeIfPresent(CGRect.self, forKey: .overlayFrame)
        showOverlayInCaptures = try c.decodeIfPresent(Bool.self, forKey: .showOverlayInCaptures) ?? d.showOverlayInCaptures
        toggleHotkey = try c.decodeIfPresent(HotkeySpec.self, forKey: .toggleHotkey) ?? d.toggleHotkey
        composeHotkey = try c.decodeIfPresent(HotkeySpec.self, forKey: .composeHotkey) ?? d.composeHotkey
        captureInterval = try c.decodeIfPresent(Double.self, forKey: .captureInterval) ?? d.captureInterval
        saveChatLog = try c.decodeIfPresent(Bool.self, forKey: .saveChatLog) ?? d.saveChatLog
    }

    private static func cleaned(_ models: [String: String]) -> [String: String] {
        models.compactMapValues { id in
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: Models per provider

    /// Live-translation model id for `provider` (default: the selected provider).
    public func modelID(for provider: AIProvider? = nil) -> String {
        let p = provider ?? self.provider
        return translationModels[p.rawValue] ?? ModelCatalog.defaultModelID(for: p, role: .fast)
    }
    /// Retranslation model id for `provider` (default: the selected provider).
    public func retranslateModelID(for provider: AIProvider? = nil) -> String {
        let p = provider ?? self.provider
        return retranslationModels[p.rawValue] ?? ModelCatalog.defaultModelID(for: p, role: .careful)
    }
    /// An empty id goes back to the built-in default.
    public mutating func setModelID(_ id: String, for provider: AIProvider) {
        translationModels[provider.rawValue] = Self.cleaned(["": id])[""]
    }
    public mutating func setRetranslateModelID(_ id: String, for provider: AIProvider) {
        retranslationModels[provider.rawValue] = Self.cleaned(["": id])[""]
    }

    // Claude-only views of the two settings above, by tier name.
    public var model: ModelChoice {
        get { ModelChoice(modelID: modelID(for: .claude)) ?? .haiku }
        set { setModelID(newValue.modelID, for: .claude) }
    }
    public var retranslateModel: ModelChoice {
        get { ModelChoice(modelID: retranslateModelID(for: .claude)) ?? .opus }
        set { setRetranslateModelID(newValue.modelID, for: .claude) }
    }
}
