import Foundation

/// Per-day spend estimate persisted to token_usage.json. Deleting the file restarts the count at zero.
public final class UsageTracker: UsageTracking, @unchecked Sendable {

    struct ModelTotals: Codable, Equatable {
        var requests = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0
    }

    struct Day: Codable, Equatable {
        /// Cost at the prices in force when each response was recorded.
        var usd: Double = 0
        /// Keyed "provider:model-id". An entry under any other key is kept as it is.
        var models: [String: ModelTotals] = [:]
        /// Responses whose model had no known price: their tokens are in `models`, their cost
        /// is not in `usd`.
        var unpricedRequests = 0

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usd = try c.decodeIfPresent(Double.self, forKey: .usd) ?? 0
            models = try c.decodeIfPresent([String: ModelTotals].self, forKey: .models) ?? [:]
            unpricedRequests = try c.decodeIfPresent(Int.self, forKey: .unpricedRequests) ?? 0
        }
    }

    struct Store: Codable, Equatable {
        var version = 1
        /// Keyed by local calendar day, "yyyy-MM-dd".
        var days: [String: Day] = [:]
    }

    private let file: URL
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let lock = NSLock()
    private var store: Store

    public convenience init(file: URL) {
        self.init(file: file, now: { Date() }, calendar: .current)
    }

    init(file: URL, now: @escaping @Sendable () -> Date, calendar: Calendar = .current) {
        self.file = file
        self.now = now
        self.calendar = calendar
        self.store = Self.load(file)
    }

    public func record(provider: AIProvider, modelID: String, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) {
        let cost = ModelCatalog.usd(provider: provider, modelID: modelID, inputTokens: inputTokens, outputTokens: outputTokens,
                                    cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens, at: now())
        let key = provider.rawValue + ":" + modelID
        lock.lock()
        defer { lock.unlock() }
        var day = store.days[todayKey()] ?? Day()
        if let cost { day.usd += cost } else { day.unpricedRequests += 1 }
        var totals = day.models[key] ?? ModelTotals()
        totals.requests += 1
        totals.inputTokens += max(0, inputTokens)
        totals.outputTokens += max(0, outputTokens)
        totals.cacheReadTokens += max(0, cacheReadTokens)
        totals.cacheWriteTokens += max(0, cacheWriteTokens)
        day.models[key] = totals
        store.days[todayKey()] = day
        save()
    }

    public var todayKRW: Double {
        lock.lock()
        defer { lock.unlock() }
        return (store.days[todayKey()]?.usd ?? 0) * ModelCatalog.krwPerUSD
    }

    public var totalKRW: Double {
        lock.lock()
        defer { lock.unlock() }
        return store.days.values.reduce(0) { $0 + $1.usd } * ModelCatalog.krwPerUSD
    }

    public var todayHasUnknownCost: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (store.days[todayKey()]?.unpricedRequests ?? 0) > 0
    }

    public var totalHasUnknownCost: Bool {
        lock.lock()
        defer { lock.unlock() }
        return store.days.values.contains { $0.unpricedRequests > 0 }
    }

    // MARK: - Persistence (call with the lock held)

    private func todayKey() -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store) else { return }
        // The estimate must never break translation: a full disk or a read-only folder just means
        // the numbers live in memory until the next successful write.
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func load(_ file: URL) -> Store {
        guard let data = try? Data(contentsOf: file) else { return Store() }
        if let store = try? JSONDecoder().decode(Store.self, from: data) { return store }
        // Unreadable (hand-edited, half-written by a crash): keep it aside instead of overwriting it.
        let backup = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".broken")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: file, to: backup)
        return Store()
    }
}
