import Foundation
import RunespeakCore

/// Decides what happens to a chat line when it first appears.
enum TranslationPolicy {
    /// A line is sent for translation only when its channel group is switched on (with every
    /// tab off, all chat stays in the original) and it is not already in the reader's language.
    static func shouldTranslate(_ message: ChatMessage, settings: AppSettings) -> Bool {
        guard let group = message.channel.group, settings.enabledGroups.contains(group) else { return false }
        return LanguageGate.needsTranslation(message.body, reader: settings.readerLanguage)
    }

    /// The lines to translate when the tabs `groups` are switched on: those that were left in
    /// the original only because their tab was off, the newest `limit` of them. Indices into
    /// `entries`, oldest first.
    static func catchUp(_ entries: [ChatEntry], groups: Set<ChannelGroup>, reader: ReaderLanguage, limit: Int) -> [Int] {
        var chosen: [Int] = []
        for index in entries.indices.reversed() where chosen.count < limit {
            let entry = entries[index]
            guard entry.state == .original, let group = entry.message.channel.group, groups.contains(group),
                  LanguageGate.needsTranslation(entry.message.body, reader: reader) else { continue }
            chosen.append(index)
        }
        return chosen.reversed()
    }

    /// Letters and digits only, lower-cased: what survives OCR jitter in spacing and punctuation.
    static func looseKey(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func sameMessage(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
        a.channel == b.channel && a.sender == b.sender && looseKey(a.body) == looseKey(b.body)
    }
}
