import Foundation
import RunespeakCore

/// Appends error lines to errors.log. The file is kept under a fixed size by dropping its
/// older half, so a fault that repeats all night cannot fill the disk.
final class ErrorLog: @unchecked Sendable {
    static let shared = ErrorLog()
    static let maxBytes = 256 * 1024

    private let queue = DispatchQueue(label: "runespeak.errorlog")
    private var file: URL?
    private var lastMessage = ""
    private var lastTime = Date.distantPast

    func configure(file: URL) {
        queue.sync { self.file = file }
    }

    func write(_ message: String) {
        queue.async { [self] in
            guard let file else { return }
            // The capture loop can hit the same fault every tick.
            let now = Date()
            if message == lastMessage, now.timeIntervalSince(lastTime) < 60 { return }
            lastMessage = message
            lastTime = now
            let line = "[\(Self.stamp(now))] \(message.replacingOccurrences(of: "\n", with: " "))\n"
            appendLine(line, to: file, limit: Self.maxBytes)
        }
    }

    func flush() { queue.sync {} }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// chat_history.txt: every line read from the screen, plus its translation once there is one.
final class ChatHistory: @unchecked Sendable {
    static let maxBytes = 8 * 1024 * 1024

    private let queue = DispatchQueue(label: "runespeak.chatlog")
    private let file: URL

    init(file: URL) { self.file = file }

    func append(message: ChatMessage) {
        write("[\(ErrorLog.stamp(message.firstSeen))] \(message.rawText)")
    }

    func append(translation: String, of message: ChatMessage) {
        let who = message.sender.map { "\($0): " } ?? ""
        write("[\(ErrorLog.stamp(Date()))]     → \(who)\(translation)")
    }

    func flush() { queue.sync {} }

    private func write(_ text: String) {
        let line = text.replacingOccurrences(of: "\n", with: " ") + "\n"
        queue.async { [file] in appendLine(line, to: file, limit: Self.maxBytes) }
    }
}

/// Appends with O_APPEND; when the file has outgrown `limit`, its newer half is kept (cut at a
/// line break).
func appendLine(_ line: String, to file: URL, limit: Int) {
    let fm = FileManager.default
    if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > limit,
       let data = try? Data(contentsOf: file) {
        var tail = data.suffix(limit / 2)
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: tail.index(after: newline)) }
        try? Data(tail).write(to: file, options: .atomic)
    }
    if !fm.fileExists(atPath: file.path) {
        fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    guard let handle = try? FileHandle(forWritingTo: file) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
}

/// settings.json, chat_area.json, the per-provider key files and model_lists.json.
struct SettingsStore {
    let paths: AppPaths

    func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: paths.settingsFile) else { return AppSettings() }
        do {
            return Self.sanitized(try JSONDecoder().decode(AppSettings.self, from: data))
        } catch {
            ErrorLog.shared.write("settings.json을 읽지 못해 기본 설정으로 시작합니다: \(error)")
            return AppSettings()
        }
    }

    func save(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(settings).write(to: paths.settingsFile, options: .atomic)
        } catch {
            ErrorLog.shared.write("settings.json 저장 실패: \(error)")
        }
    }

    /// Values a hand-edited file could carry that would break the app.
    static func sanitized(_ settings: AppSettings) -> AppSettings {
        var s = settings
        s.captureInterval = s.captureInterval.isFinite ? min(5, max(0.2, s.captureInterval)) : 0.7
        s.fontSize = s.fontSize.isFinite ? min(32, max(9, s.fontSize)) : 14
        s.overlayOpacity = s.overlayOpacity.isFinite ? min(1, max(0.2, s.overlayOpacity)) : 0.95
        if s.outgoingLanguage.trimmingCharacters(in: .whitespaces).isEmpty { s.outgoingLanguage = "English" }
        s.outgoingLanguage = OverlayOutgoingLanguages.canonicalName(s.outgoingLanguage)
        return s
    }

    func loadRegion() -> CaptureRegion? {
        guard let data = try? Data(contentsOf: paths.chatAreaFile),
              let region = try? JSONDecoder().decode(CaptureRegion.self, from: data) else { return nil }
        let r = region.rect
        guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite,
              r.width >= 40, r.height >= 20 else { return nil }
        return region
    }

    func save(region: CaptureRegion) {
        do {
            try JSONEncoder().encode(region).write(to: paths.chatAreaFile, options: .atomic)
        } catch {
            ErrorLog.shared.write("chat_area.json 저장 실패: \(error)")
        }
    }

    func loadAPIKey(for provider: AIProvider) -> String? {
        let file = paths.keyFile(for: provider)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        // An older or hand-made file may be world-readable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// nil removes the file. The file is created owner-only before the key is written into it.
    func saveAPIKey(_ key: String?, for provider: AIProvider) {
        let fm = FileManager.default
        let file = paths.keyFile(for: provider)
        try? fm.removeItem(atPath: file.path)
        guard let key else { return }
        if !fm.createFile(atPath: file.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) {
            ErrorLog.shared.write("\(file.lastPathComponent) 저장 실패")
        }
    }

    // MARK: Model lists fetched with a key

    private var modelListsFile: URL { paths.root.appendingPathComponent("model_lists.json") }

    private struct StoredModel: Codable {
        var id: String
        var name: String
    }

    /// The model lists last fetched from each provider, so the pickers still offer them after
    /// a restart. Prices and roles are not stored: they come from the built-in table.
    func loadModelLists() -> [AIProvider: [ModelInfo]] {
        guard let data = try? Data(contentsOf: modelListsFile),
              let stored = try? JSONDecoder().decode([String: [StoredModel]].self, from: data) else { return [:] }
        var lists: [AIProvider: [ModelInfo]] = [:]
        for (name, models) in stored {
            guard let provider = AIProvider(rawValue: name) else { continue }
            lists[provider] = models.prefix(500).compactMap { model in
                let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { return nil }
                let known = ModelCatalog.info(provider: provider, modelID: id)
                return ModelInfo(provider: provider, id: id, displayName: model.name.isEmpty ? id : model.name,
                                 role: known?.id == id ? known?.role : nil, price: known?.price)
            }
        }
        return lists
    }

    func save(modelLists: [AIProvider: [ModelInfo]]) {
        var stored: [String: [StoredModel]] = [:]
        for (provider, models) in modelLists where !models.isEmpty {
            stored[provider.rawValue] = models.map { StoredModel(id: $0.id, name: $0.displayName) }
        }
        if stored.isEmpty {
            try? FileManager.default.removeItem(at: modelListsFile)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(stored).write(to: modelListsFile, options: .atomic)
        } catch {
            ErrorLog.shared.write("model_lists.json 저장 실패: \(error)")
        }
    }
}

/// Keeps the user's data folder in step with the dictionary files inside the app bundle.
enum BundledDictionary {
    /// Contents/Resources/data of the running app; nil for a bare executable (swift build).
    static var folder: URL? {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("data", isDirectory: true),
              FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return folder
    }

    /// Run at launch, before the glossary is loaded: copies the bundled dictionary files that
    /// are missing or differ. Returns the names of the files written or removed.
    @discardableResult
    static func install(to paths: AppPaths, from bundled: URL? = folder) -> [String] {
        guard let bundled else { return [] }
        let seeded = DictionaryFiles.seed(from: bundled, to: paths)
        for failure in seeded.failures {
            ErrorLog.shared.write("내장 사전 복사 실패: \(failure)")
        }
        return seeded.changed
    }
}
