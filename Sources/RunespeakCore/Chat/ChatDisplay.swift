import Foundation

/// How a chat line's header is written wherever the app shows or logs it: the channel tag in
/// brackets, then the speaker's whole name once, without brackets, then a colon.
public enum ChatDisplay {
    /// Channel tag without brackets, or nil when the game shows none for this line.
    public static func channelTag(for message: ChatMessage) -> String? {
        if let label = message.channelLabel?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
            return label
        }
        // Whispers carry no bracketed tag in game; without one a translated whisper would be
        // indistinguishable from /say.
        return message.channel == .whisper ? "귓속말" : nil
    }

    /// "이름: ", or "" for a line without a speaker (or one that names its speaker itself). A
    /// name of several words stays one name.
    public static func senderPrefix(for message: ChatMessage) -> String {
        guard let sender = message.sender?.trimmingCharacters(in: .whitespaces), !sender.isEmpty else { return "" }
        // An emote is a sentence about its speaker ("Name dances."): the name is in the text.
        if message.channel == .emote, message.body.hasPrefix(sender) { return "" }
        return "\(sender): "
    }

    /// The text of the message as it is shown in the original. Rows that went out without their
    /// header row (`ChatMessage.isFragment`) are marked as the end of something: "… the rest".
    public static func body(for message: ChatMessage) -> String {
        message.isFragment ? "… " + message.body : message.body
    }

    /// "[길드] 이름: " — whatever parts exist.
    public static func prefix(for message: ChatMessage) -> String {
        (channelTag(for: message).map { "[\($0)] " } ?? "") + senderPrefix(for: message)
    }

    // MARK: - chat_history.txt

    /// Longest model name written into a history line; a model id typed by hand can be any length.
    public static let engineTagLimit = 40

    /// The name of the model or service behind a translation as a history line carries it:
    /// "[Sonnet]", and "[Sonnet·재사용]" when the translation was not requested for this line
    /// but taken from an earlier, identical one. Always one bracketed group on one line, so a
    /// line can be taken apart again: brackets and line breaks inside a name are replaced, a
    /// long name is cut, and a translation of unknown origin gets "[?]".
    public static func engineTag(_ engine: String?, reused: Bool = false) -> String {
        var name = ""
        var gap = false
        for scalar in (engine ?? "").unicodeScalars {
            if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format {
                gap = true
                continue
            }
            if gap, !name.isEmpty { name.append(" ") }
            gap = false
            switch scalar {
            case "[": name.append("(")
            case "]": name.append(")")
            default: name.unicodeScalars.append(scalar)
            }
        }
        if name.isEmpty { name = "?" }
        if name.count > engineTagLimit { name = String(name.prefix(engineTagLimit - 1)) + "…" }
        return "[" + name + (reused ? "·재사용" : "") + "]"
    }

    /// A translation as chat_history.txt records it under its chat line, without the time
    /// stamp: "    → [Sonnet] 이름: 번역문". The model is named so that a translation read in
    /// the log later can be put down to the model that wrote it.
    public static func historyLine(translation: String, of message: ChatMessage, engine: String?, reused: Bool = false) -> String {
        "    → " + engineTag(engine, reused: reused) + " " + senderPrefix(for: message) + translation
    }

    /// The history line for a request that came back with the line unchanged: no translation
    /// is recorded, only that the model was asked, which one it was, and for which line. The
    /// line is named because the record is written when the answer arrives, by which time
    /// other chat stands between it and its line. `reused`: the model was not asked again;
    /// an earlier, identical line had come back unchanged.
    public static func historyLine(unchangedAnswerFor message: ChatMessage, engine: String?, reused: Bool = false) -> String {
        let said = message.body.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "    = " + engineTag(engine, reused: reused) + " " + senderPrefix(for: message) + said + "  (원문과 같은 답 — 번역 없음)"
    }
}
