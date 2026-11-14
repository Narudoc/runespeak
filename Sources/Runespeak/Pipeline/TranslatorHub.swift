import Foundation
import RunespeakCore

/// Holds one API key per provider and hands out the translator that goes with the settings:
/// the selected provider's when it has a key, otherwise the free fallback.
@MainActor
final class TranslatorHub {
    private let store: SettingsStore
    private let glossary: GlossaryProviding
    private let usage: UsageTracking?
    private let session: URLSession

    private var keys: [AIProvider: String] = [:]
    /// Kept per provider while its key stays the same: a translator remembers which optional
    /// request features each model rejected, and that should survive switching back and forth.
    private var translators: [AIProvider: Translating] = [:]
    private lazy var fallback: Translating = MyMemoryTranslator(session: session)

    init(store: SettingsStore, glossary: GlossaryProviding, usage: UsageTracking?, session: URLSession = .shared) {
        self.store = store
        self.glossary = glossary
        self.usage = usage
        self.session = session
        for provider in AIProvider.allCases {
            keys[provider] = store.loadAPIKey(for: provider)
        }
    }

    var keyedProviders: Set<AIProvider> { Set(keys.keys) }

    func hasKey(_ provider: AIProvider) -> Bool { keys[provider] != nil }

    /// Only for requests to the provider itself (key check, model list); never shown or logged.
    func key(for provider: AIProvider) -> String? { keys[provider] }

    /// An empty key removes the stored one and its file.
    func setKey(_ key: String, for provider: AIProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let new: String? = trimmed.isEmpty ? nil : trimmed
        store.saveAPIKey(new, for: provider)
        guard keys[provider] != new else { return }
        keys[provider] = new
        translators[provider] = nil
    }

    /// The provider that translates under `settings`; nil while the free fallback is in use.
    func activeProvider(for settings: AppSettings) -> AIProvider? {
        hasKey(settings.provider) ? settings.provider : nil
    }

    func translator(for settings: AppSettings) -> Translating {
        guard let provider = activeProvider(for: settings), let key = keys[provider] else { return fallback }
        if let made = translators[provider] { return made }
        let made = TranslatorFactory.make(provider: provider, apiKey: key, glossary: glossary, usage: usage, session: session)
        translators[provider] = made
        return made
    }
}
