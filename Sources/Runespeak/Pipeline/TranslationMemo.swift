import Foundation
import RunespeakCore

/// Finished translations of recent lines. The same advert reposted every half minute, or the
/// same macro from five players, is translated (and paid for) once. So is a line the model
/// handed back as it was (`Hit.unchanged`): asked once, it stays in the original every time it
/// comes again.
struct TranslationMemo {
    struct Hit: Equatable {
        var text: String
        var note: String?
        var engine: String?
        /// The answer was the line itself: there is no translation, and no need to ask again.
        var unchanged = false

        static func unchanged(engine: String?) -> Hit { Hit(text: "", note: nil, engine: engine, unchanged: true) }
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
    ///
    /// `zone`: the zone whose places went to the model with this line as hints
    /// (`GlossaryProviding.placeZone(for:)`), nil when none did. With such hints "LF1M for the
    /// dig site" names one place in this zone's channel and another, or none, in the next
    /// zone's: the translation is kept for this zone only. A line without place hints reads
    /// the same everywhere and keeps being reused across zones.
    static func key(for message: ChatMessage, reader: ReaderLanguage, zone: String? = nil) -> String? {
        guard let group = message.channel.group else { return nil }
        let body = TranslationPolicy.looseKey(message.body)
        guard body.count >= minimumKeyLength else { return nil }
        let place = zone.map { "@" + TranslationPolicy.looseKey($0) } ?? ""
        return "\(reader.rawValue)|\(group.rawValue)\(place)|\(body)"
    }

    mutating func lookup(_ message: ChatMessage, reader: ReaderLanguage, zone: String? = nil) -> Hit? {
        guard let key = Self.key(for: message, reader: reader, zone: zone), let hit = hits[key] else { return nil }
        touch(key)
        return hit
    }

    mutating func store(_ hit: Hit, for message: ChatMessage, reader: ReaderLanguage, zone: String? = nil) {
        guard let key = Self.key(for: message, reader: reader, zone: zone) else { return }
        hits[key] = hit
        touch(key)
        if order.count > Self.capacity {
            let dropped = order.removeFirst()
            hits[dropped] = nil
        }
    }

    /// Forgets the translation kept for this line (it turned out not to be one).
    mutating func remove(_ message: ChatMessage, reader: ReaderLanguage, zone: String? = nil) {
        guard let key = Self.key(for: message, reader: reader, zone: zone), hits[key] != nil else { return }
        hits[key] = nil
        order.removeAll { $0 == key }
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
