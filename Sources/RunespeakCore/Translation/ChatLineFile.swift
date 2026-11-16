import Foundation

/// The file format of the two check tools (`--translate-check`, `--dictionary-check`): one chat
/// message per line.
///
///     the body alone                                   a line of a numbered channel
///     channel<TAB>sender<TAB>body                      channel spelled like `ChatChannel`
///     channel[label]<TAB>sender<TAB>body               with the channel's label as the game shows it
///
/// `publicChannel[1. General - Tanaris]<TAB>Aldren<TAB>LF1M ZF` is a line said in the general
/// channel of Tanaris: the label is what tells the dictionary which zone's places may be meant.
/// A numbered-channel line without a label gets `defaultPublicLabel`, as it always did. Empty
/// lines and lines starting with "#" are skipped. The sender may be left empty.
public enum ChatLineFile {
    /// The label of a numbered-channel line that names none.
    public static let defaultPublicLabel = "1. 공개 - 스톰윈드"

    public static func message(from line: String, now: Date = Date()) -> ChatMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
        var channel = ChatChannel.publicChannel
        var label: String?
        var sender: String?
        var body = trimmed
        let fields = line.components(separatedBy: "\t")
        if fields.count >= 3, let named = channelField(fields[0]) {
            channel = named.channel
            label = named.label
            let name = fields[1].trimmingCharacters(in: .whitespaces)
            sender = name.isEmpty ? nil : name
            body = fields[2...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        if body.isEmpty { return nil }
        if label == nil, channel == .publicChannel { label = defaultPublicLabel }
        return ChatMessage(channel: channel, channelLabel: label, sender: sender, body: body, rawText: body,
                           color: .white, firstSeen: now)
    }

    /// "guild", "publicChannel[1. 공개 - 타나리스]": the kind, and the label when one is given in
    /// square brackets behind it. nil when the field is no channel (the line is then all body).
    static func channelField(_ field: String) -> (channel: ChatChannel, label: String?)? {
        let text = field.trimmingCharacters(in: .whitespaces)
        guard let open = text.firstIndex(of: "["), text.hasSuffix("]") else {
            return ChatChannel(rawValue: text).map { ($0, nil) }
        }
        guard let channel = ChatChannel(rawValue: text[..<open].trimmingCharacters(in: .whitespaces)) else { return nil }
        let label = text[text.index(after: open)..<text.index(before: text.endIndex)].trimmingCharacters(in: .whitespaces)
        return (channel, label.isEmpty ? nil : label)
    }
}
