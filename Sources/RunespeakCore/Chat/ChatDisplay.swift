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

    /// "[길드] 이름: " — whatever parts exist.
    public static func prefix(for message: ChatMessage) -> String {
        (channelTag(for: message).map { "[\($0)] " } ?? "") + senderPrefix(for: message)
    }
}
