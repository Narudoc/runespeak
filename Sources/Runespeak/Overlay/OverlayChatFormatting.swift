import AppKit
import RunespeakCore

// Text helpers shared by the overlay panel and the history window.

// Qualified: AppKit also exports a QuickDraw-era `RGBColor`.
extension RunespeakCore.RGBColor {
    /// Named distinctively so it cannot clash with helpers other modules add to RGBColor.
    var overlayNSColor: NSColor {
        NSColor(srgbRed: CGFloat(min(max(r, 0), 1)), green: CGFloat(min(max(g, 0), 1)),
                blue: CGFloat(min(max(b, 0), 1)), alpha: 1)
    }
}

enum OverlayChatFormat {
    /// Channel tag without brackets, or nil when the game shows none for this line.
    static func channelTag(for message: ChatMessage) -> String? { ChatDisplay.channelTag(for: message) }

    /// "[길드] 이름: " — whatever parts exist.
    static func prefix(for message: ChatMessage) -> String { ChatDisplay.prefix(for: message) }

    /// The line as the game showed it.
    static func originalLine(for message: ChatMessage) -> String {
        // Rows without their header row: marked as the end of something ("… the rest").
        if message.isFragment { return prefix(for: message) + ChatDisplay.body(for: message) }
        let raw = message.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? prefix(for: message) + message.body : raw
    }

    /// Translation text if the entry has one.
    static func translation(of entry: ChatEntry) -> String? {
        if case .translated(let text) = entry.state { return text }
        return nil
    }

    static func clampedFontSize(_ size: Double) -> CGFloat {
        CGFloat(min(max(size.isFinite ? size : 14, 9), 32))
    }

    static func formatKRW(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0원" }
        if value < 1 { return "1원 미만" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: "ko_KR")
        return "약 " + (formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))") + "원"
    }
}

/// Languages offered for "보낼 말의 언어", in the overlay menu and in Settings alike. `name` is
/// what gets stored in AppSettings.outgoingLanguage and sent to the translator.
enum OverlayOutgoingLanguages {
    /// A bare "Chinese" in the settings file means the list's "Simplified Chinese".
    static func canonicalName(_ stored: String) -> String {
        let name = stored.trimmingCharacters(in: .whitespaces)
        return name.caseInsensitiveCompare("Chinese") == .orderedSame ? "Simplified Chinese" : name
    }

    static let all: [(name: String, title: String)] = [
        ("English", "영어 (English)"),
        ("Spanish", "스페인어 (Español)"),
        ("Portuguese", "포르투갈어 (Português)"),
        ("Russian", "러시아어 (Русский)"),
        ("German", "독일어 (Deutsch)"),
        ("French", "프랑스어 (Français)"),
        ("Italian", "이탈리아어 (Italiano)"),
        ("Simplified Chinese", "중국어 간체 (简体中文)"),
        ("Traditional Chinese", "중국어 번체 (繁體中文)"),
        ("Japanese", "일본어 (日本語)"),
        ("Korean", "한국어"),
    ]
}
