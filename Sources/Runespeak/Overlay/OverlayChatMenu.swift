import AppKit
import RunespeakCore

/// Menu item that runs a closure; lets menus be built without a responder-chain target,
/// which matters because the overlay panel never becomes key.
final class OverlayClosureMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        self.target = self
        self.state = checked ? .on : .off
        self.isEnabled = enabled
    }

    @objc private func fire() { handler?() }
}

/// Context menus shared by the overlay and the history window.
@MainActor
enum OverlayChatMenu {
    static let fontPresets: [(title: String, size: Double)] = [
        ("작게", 12), ("보통", 14), ("크게", 17), ("아주 크게", 20),
    ]

    /// Right-click on a chat line. `notify` shows a short confirmation in the calling window.
    static func entryMenu(for entry: ChatEntry, state: AppState, notify: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let id = entry.id
        let translation = OverlayChatFormat.translation(of: entry)
        let isSystem = entry.message.channel.group == nil

        if case .failed = entry.state, !isSystem {
            // The ordinary translator once more: works without a key, costs what a line costs.
            menu.addItem(OverlayClosureMenuItem("다시 시도") { [weak state] in
                state?.actions?.retryTranslation(entryID: id)
            })
        }
        let retranslateTitle = state.hasAPIKey ? "다시 번역" : "다시 번역 (AI API 키 필요)"
        // Not while the line is still waiting for its first answer, and not for rows that
        // were read without the beginning of their message.
        menu.addItem(OverlayClosureMenuItem(retranslateTitle, enabled: state.hasAPIKey && TranslationPolicy.canRetranslate(entry)) { [weak state] in
            state?.actions?.retranslate(entryID: id)
        })
        menu.addItem(.separator())
        let message = entry.message
        menu.addItem(OverlayClosureMenuItem("원문 복사") {
            copy(message.body.isEmpty ? OverlayChatFormat.originalLine(for: message) : message.body)
            notify("원문이 복사되었습니다")
        })
        menu.addItem(OverlayClosureMenuItem("번역 복사", enabled: translation != nil) {
            guard let translation else { return }
            copy(translation)
            notify("번역문이 복사되었습니다")
        })
        return menu
    }

    /// Right-click on the empty part of the overlay.
    static func optionsMenu(state: AppState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let settings = state.settings

        // 글자 크기
        let fontItem = NSMenuItem(title: "글자 크기", action: nil, keyEquivalent: "")
        let fontMenu = NSMenu()
        fontMenu.autoenablesItems = false
        for preset in fontPresets {
            fontMenu.addItem(OverlayClosureMenuItem(preset.title, checked: abs(settings.fontSize - preset.size) < 0.01) { [weak state] in
                state?.actions?.updateSettings { $0.fontSize = preset.size }
            })
        }
        fontMenu.addItem(.separator())
        let current = Double(OverlayChatFormat.clampedFontSize(settings.fontSize))
        fontMenu.addItem(OverlayClosureMenuItem("더 크게 (+)", enabled: current < 32) { [weak state] in
            state?.actions?.updateSettings { $0.fontSize = min(32, (Double(OverlayChatFormat.clampedFontSize($0.fontSize)) + 1).rounded()) }
        })
        fontMenu.addItem(OverlayClosureMenuItem("더 작게 (−)", enabled: current > 9) { [weak state] in
            state?.actions?.updateSettings { $0.fontSize = max(9, (Double(OverlayChatFormat.clampedFontSize($0.fontSize)) - 1).rounded()) }
        })
        fontItem.submenu = fontMenu
        menu.addItem(fontItem)

        // 번역 모델 — of the selected provider
        let provider = settings.provider
        let modelItem = NSMenuItem(title: "번역 모델", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        modelMenu.autoenablesItems = false
        let currentModel = settings.modelID(for: provider)
        for model in state.models(for: provider) {
            modelMenu.addItem(OverlayClosureMenuItem(AIConnectionSection.pickerTitle(model), checked: model.id == currentModel) { [weak state] in
                state?.actions?.updateSettings { $0.setModelID(model.id, for: provider) }
            })
        }
        if !state.hasAPIKey {
            modelMenu.addItem(.separator())
            modelMenu.addItem(OverlayClosureMenuItem("\(provider.shortName) API 키가 없어 무료 번역을 쓰는 중", enabled: false) {})
        }
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        // AI 제공자 — only those with a key can be switched to from here
        let providerItem = NSMenuItem(title: "AI 제공자", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu()
        providerMenu.autoenablesItems = false
        for candidate in AIProvider.allCases {
            let keyed = state.hasKey(candidate)
            let title = keyed ? candidate.title : "\(candidate.title) — 키 없음"
            providerMenu.addItem(OverlayClosureMenuItem(title, checked: candidate == provider,
                                                        enabled: keyed || candidate == provider) { [weak state] in
                state?.actions?.updateSettings { $0.provider = candidate }
            })
        }
        if state.keyedProviders.count < AIProvider.allCases.count {
            providerMenu.addItem(.separator())
            providerMenu.addItem(OverlayClosureMenuItem("API 키 넣기 (설정)…") { [weak state] in
                state?.actions?.showSettings()
            })
        }
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)

        // 보낼 말의 언어
        let languageItem = NSMenuItem(title: "보낼 말의 언어", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        languageMenu.autoenablesItems = false
        var languages = OverlayOutgoingLanguages.all
        let currentLanguage = settings.outgoingLanguage.trimmingCharacters(in: .whitespaces)
        if !currentLanguage.isEmpty,
           !languages.contains(where: { $0.name.caseInsensitiveCompare(currentLanguage) == .orderedSame }) {
            // A language picked elsewhere (settings window) that is not in our list stays visible.
            languages.append((currentLanguage, currentLanguage))
        }
        for language in languages {
            let checked = language.name.caseInsensitiveCompare(currentLanguage) == .orderedSame
            languageMenu.addItem(OverlayClosureMenuItem(language.title, checked: checked) { [weak state] in
                state?.actions?.updateSettings { $0.outgoingLanguage = language.name }
            })
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(.separator())
        menu.addItem(OverlayClosureMenuItem("채팅창 위치 다시 잡기") { [weak state] in
            state?.actions?.beginRegionSelection()
        })
        if settings.overlayFrame != nil {
            menu.addItem(OverlayClosureMenuItem("겹친 번역을 채팅창 자리로 되돌리기") { [weak state] in
                state?.actions?.updateSettings { $0.overlayFrame = nil }
            })
        }
        menu.addItem(OverlayClosureMenuItem("겹쳐 보기 끄기 (\(settings.toggleHotkey.displayString))") { [weak state] in
            state?.actions?.toggleOverlay()
        })
        menu.addItem(.separator())
        menu.addItem(OverlayClosureMenuItem("번역 기록 창 열기") { [weak state] in
            state?.actions?.showMainWindow()
        })
        menu.addItem(OverlayClosureMenuItem("설정…") { [weak state] in
            state?.actions?.showSettings()
        })
        return menu
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
