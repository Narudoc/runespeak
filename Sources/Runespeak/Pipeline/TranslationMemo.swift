import Foundation
import RunespeakCore

/// Finished translations of recent lines. The same advert reposted every half minute, or the
/// same macro from five players, is translated (and paid for) once.
struct TranslationMemo {
    struct Hit: Equatable {
        var text: String
        var note: String?
        var engine: String?
    }

    static let capacity = 300
    /// Shorter lines ("ty", "inv") lean on what was said around them too much to be reused.
    static let minimumKeyLength = 8

    private var hits: [String: Hit] = [:]
    /// Least recently used first.
    private var order: [String] = []

    var count: Int { hits.count }

    /// nil for lines that are never reused. The channel group is part of the key because the
    /// prompt tells the model the channel, and "LFM" reads differently in guild chat.
    static func key(for message: ChatMessage, reader: ReaderLanguage) -> String? {
        guard let group = message.channel.group else { return nil }
        let body = TranslationPolicy.looseKey(message.body)
        guard body.count >= minimumKeyLength else { return nil }
        return "\(reader.rawValue)|\(group.rawValue)|\(body)"
    }

    mutating func lookup(_ message: ChatMessage, reader: ReaderLanguage) -> Hit? {
        guard let key = Self.key(for: message, reader: reader), let hit = hits[key] else { return nil }
        touch(key)
        return hit
    }

    mutating func store(_ hit: Hit, for message: ChatMessage, reader: ReaderLanguage) {
        guard let key = Self.key(for: message, reader: reader) else { return }
        hits[key] = hit
        touch(key)
        if order.count > Self.capacity {
            let dropped = order.removeFirst()
            hits[dropped] = nil
        }
    }

    mutating func removeAll() {
        hits.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: String) {
        if let index = order.lastIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}
