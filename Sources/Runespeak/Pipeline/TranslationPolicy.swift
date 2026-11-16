import Foundation
import RunespeakCore

/// Decides what happens to a chat line when it first appears.
enum TranslationPolicy {
    /// A line is sent for translation only when its channel group is switched on (with every
    /// tab off, all chat stays in the original), it is not already in the reader's language,
    /// and it is a whole message: rows that went out without their header row
    /// (`ChatMessage.isFragment`) wait for the message that replaces them.
    static func shouldTranslate(_ message: ChatMessage, settings: AppSettings) -> Bool {
        guard let group = message.channel.group, settings.enabledGroups.contains(group) else { return false }
        return LanguageGate.needsTranslation(message, reader: settings.readerLanguage)
    }

    /// The lines to translate when the tabs `groups` are switched on: those that were left in
    /// the original only because their tab was off, the newest `limit` of them. Indices into
    /// `entries`, oldest first. `except`: lines that are in the original because the translator
    /// was asked and answered with the line itself; they are not asked about again.
    static func catchUp(_ entries: [ChatEntry], groups: Set<ChannelGroup>, reader: ReaderLanguage, limit: Int,
                        except answered: Set<UUID> = []) -> [Int] {
        var chosen: [Int] = []
        for index in entries.indices.reversed() where chosen.count < limit {
            let entry = entries[index]
            guard entry.state == .original, !answered.contains(entry.id),
                  let group = entry.message.channel.group, groups.contains(group),
                  LanguageGate.needsTranslation(entry.message, reader: reader) else { continue }
            chosen.append(index)
        }
        return chosen.reversed()
    }

    /// Whether a line already shown may go along with later requests as the chat that came
    /// before. A line that failed tells the model nothing, and one a provider refused would
    /// get the next requests refused with it. Rows that went out without their header row and
    /// what OCR made of text it could not read are not something a player said: as context
    /// they only give the model words to pick up that the line being translated does not hold.
    static func belongsInContext(_ entry: ChatEntry) -> Bool {
        if case .failed = entry.state { return false }
        let message = entry.message
        return message.channel.group != nil && !message.isFragment && !LanguageGate.isUnreadable(message.body)
    }

    /// Whether a careful retranslation can be asked for by hand: for a line of chat (not a
    /// notice of the game) that is whole and not still waiting for its first answer. Rows
    /// that went out without their header row are the end of a sentence: translated alone,
    /// and stored as an example for later lines, they would teach the model something nobody
    /// said.
    static func canRetranslate(_ entry: ChatEntry) -> Bool {
        entry.message.channel.group != nil && !entry.message.isFragment && entry.state != .pending
    }

    /// Whether a careful retranslation is stored as a corrections example for later lines.
    /// Not when it was made with the places of a zone (`zone`, see `TranslationMemo.key`): a
    /// correction is found again by its text alone and the prompt trusts it over anything
    /// else, so the place of this zone would be written for the same words said in the next
    /// zone's channel. The line itself keeps its retranslation, and so does the memo, for
    /// this zone.
    static func keepsCorrection(madeWithPlacesOf zone: String?) -> Bool {
        zone == nil
    }

    /// The explanation that stays on a line whose careful retranslation came back as the line
    /// itself: the line is shown in the original, and what the model said about it (a name,
    /// an orcish phrase, nothing to translate) is what the user asked for.
    static func noteForUnchangedRetranslation(_ note: String?) -> String? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Letters and digits only, lower-cased: what survives OCR jitter in spacing and punctuation.
    static func looseKey(_ text: String) -> String {
        TranslationEcho.looseKey(text)
    }

    static func sameMessage(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
        a.channel == b.channel && a.sender == b.sender && looseKey(a.body) == looseKey(b.body)
    }
}
