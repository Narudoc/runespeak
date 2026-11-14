import Foundation

/// USD list price per million tokens.
public struct ModelPrice: Sendable, Equatable, Hashable {
    public var input: Double
    public var output: Double
    /// Input served from the provider's prompt cache.
    public var cacheRead: Double
    /// Input written to the prompt cache. Equal to `input` where the provider does not charge
    /// extra for writes.
    public var cacheWrite: Double
    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
}

public enum ModelRole: String, Sendable, Hashable {
    /// Default for live chat: fastest and cheapest.
    case fast
    /// Default for "다시 번역": more careful, slower, dearer.
    case careful
}

public struct ModelInfo: Sendable, Equatable, Hashable, Identifiable {
    public var provider: AIProvider
    /// What goes in the request, e.g. "gpt-6-luna".
    public var id: String
    public var displayName: String
    /// Set on the two built-in defaults of each provider.
    public var role: ModelRole?
    /// nil when the model is not in the built-in price table.
    public var price: ModelPrice?
    public init(provider: AIProvider, id: String, displayName: String, role: ModelRole? = nil, price: ModelPrice? = nil) {
        self.provider = provider; self.id = id; self.displayName = displayName; self.role = role; self.price = price
    }
    /// Picker text: "GPT-6 Luna (빠르고 저렴)".
    public var title: String {
        switch role {
        case .fast: return displayName + " (빠르고 저렴)"
        case .careful: return displayName + " (가장 정확)"
        case nil: return displayName
        }
    }
}

/// The built-in model list and price table, plus the live model list of a key.
///
/// Model ids and prices go stale. Each block names the page and the day it was read; when a
/// provider renames or reprices, update the block and its date. A model that is missing here
/// still works (any id can be sent) — only its cost estimate is unknown.
public enum ModelCatalog {

    /// Won per US dollar. An estimate; the real charge is in USD on the provider's invoice.
    public static let krwPerUSD: Double = 1_400

    private static func entry(_ provider: AIProvider, _ id: String, _ name: String, _ role: ModelRole? = nil,
                              _ input: Double, _ output: Double, read: Double, write: Double? = nil) -> ModelInfo {
        ModelInfo(provider: provider, id: id, displayName: name, role: role,
                  price: ModelPrice(input: input, output: output, cacheRead: read, cacheWrite: write ?? input))
    }

    // Claude — ids and prices from the Anthropic model table (claude-api reference, cached
    // 2026-11-03; https://platform.claude.com/docs/en/about-claude/models/overview and
    // https://platform.claude.com/docs/en/about-claude/pricing), read 2026-11-13.
    // Haiku 5.5 prices are for prompts up to 100K tokens; chat requests are a few thousand.
    // cacheWrite is the 5-minute write (1.25 × input), the only TTL this app uses.
    private static let claude: [ModelInfo] = [
        entry(.claude, "claude-haiku-5-5", "Claude Haiku 5.5", .fast, 0.10, 0.50, read: 0.01, write: 0.125),
        entry(.claude, "claude-sonnet-5-5", "Claude Sonnet 5.5", nil, 2.00, 10.00, read: 0.10, write: 2.50),
        entry(.claude, "claude-opus-5-5", "Claude Opus 5.5", .careful, 4.00, 20.00, read: 0.20, write: 5.00),
    ]

    // OpenAI — ids from https://developers.openai.com/api/docs/models ("use GPT-6 Astra … GPT-6.1 Sol
    // to balance intelligence and cost … GPT-6 Luna for cost-sensitive, high-volume workloads"),
    // prices from https://developers.openai.com/api/docs/pricing (Standard, short context: prompts
    // up to 272K tokens), both read 2026-11-13. cacheWrite is the default 30-minute write (1.25 × input).
    private static let openai: [ModelInfo] = [
        entry(.openai, "gpt-6-luna", "GPT-6 Luna", .fast, 0.10, 0.50, read: 0.01, write: 0.125),
        entry(.openai, "gpt-6.1-terra", "GPT-6.1 Terra", nil, 1.00, 5.00, read: 0.05, write: 1.25),
        entry(.openai, "gpt-6.1-sol", "GPT-6.1 Sol", .careful, 2.00, 10.00, read: 0.10, write: 2.50),
        entry(.openai, "gpt-6-astra", "GPT-6 Astra", nil, 10.00, 50.00, read: 1.00, write: 12.50),
    ]

    // Gemini — ids from https://aistudio.google.com/docs/models (the ai.google.dev/gemini-api/docs pages redirect there), prices from
    // https://aistudio.google.com/docs/pricing (Standard paid tier, text input; output
    // includes thinking tokens), both read 2026-11-13. Implicit caching has no write charge.
    // Scheduled changes on that page are in `scheduled` below.
    private static let gemini: [ModelInfo] = [
        entry(.gemini, "gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite", .fast, 0.30, 2.50, read: 0.03),
        entry(.gemini, "gemini-3.8-flash", "Gemini 3.8 Flash", nil, 0.75, 3.75, read: 0.075),
        entry(.gemini, "gemini-4-hydrogen", "Gemini 4 Hydrogen", .careful, 1.50, 7.50, read: 0.075),
        entry(.gemini, "gemini-4-carbon", "Gemini 4 Carbon", nil, 2.00, 10.00, read: 0.10),
    ]

    /// Price changes the providers have announced: from `from` on, `price` replaces the table's.
    /// Once a date has passed, move the price into the table and drop the line.
    private static let scheduled: [(provider: AIProvider, id: String, from: Date, price: ModelPrice)] = [
        (.gemini, "gemini-4-carbon", utcDay(2026, 12, 1), ModelPrice(input: 4.00, output: 20.00, cacheRead: 0.20, cacheWrite: 4.00)),
        (.gemini, "gemini-3.8-flash", utcDay(2027, 1, 1), ModelPrice(input: 1.50, output: 7.50, cacheRead: 0.15, cacheWrite: 1.50)),
    ]

    private static func utcDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantFuture
    }

    /// The short list offered before (or without) fetching the key's own model list, cheapest
    /// first, with the prices in force on `date`.
    public static func builtIn(_ provider: AIProvider, at date: Date = Date()) -> [ModelInfo] {
        let table: [ModelInfo]
        switch provider {
        case .claude: table = claude
        case .openai: table = openai
        case .gemini: table = gemini
        }
        return table.map { model in
            var model = model
            for change in scheduled where change.provider == provider && change.id == model.id && date >= change.from {
                model.price = change.price
            }
            return model
        }
    }

    public static func defaultModelID(for provider: AIProvider, role: ModelRole) -> String {
        builtIn(provider).first { $0.role == role }!.id
    }

    /// The built-in entry for `modelID`, also for a dated snapshot of it
    /// ("claude-haiku-5-5-20260915", "gpt-6-luna-2026-08-01", "gemini-3.5-flash-lite-001").
    public static func info(provider: AIProvider, modelID: String, at date: Date = Date()) -> ModelInfo? {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let known = builtIn(provider, at: date)
        if let exact = known.first(where: { $0.id == id }) { return exact }
        // Longest id first so that a snapshot of "gpt-6.1-sol-pro" could never match "gpt-6.1-sol".
        return known.sorted { $0.id.count > $1.id.count }.first { model in
            guard id.hasPrefix(model.id + "-") else { return false }
            let rest = id.dropFirst(model.id.count + 1)
            return rest == "latest" || rest.first?.isNumber == true
        }
    }

    public static func price(provider: AIProvider, modelID: String, at date: Date = Date()) -> ModelPrice? {
        info(provider: provider, modelID: modelID, at: date)?.price
    }

    /// Name to show for a model id; the id itself when it is not a built-in model.
    public static func displayName(provider: AIProvider, modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = builtIn(provider).first(where: { $0.id == trimmed.lowercased() }) { return known.displayName }
        return trimmed
    }

    /// Cost of one response on `date` in USD; nil when the model has no known price.
    public static func usd(provider: AIProvider, modelID: String, inputTokens: Int, outputTokens: Int,
                           cacheReadTokens: Int, cacheWriteTokens: Int, at date: Date = Date()) -> Double? {
        guard let price = price(provider: provider, modelID: modelID, at: date) else { return nil }
        return usd(price, inputTokens: inputTokens, outputTokens: outputTokens,
                   cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens)
    }

    static func usd(_ price: ModelPrice, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) -> Double {
        let total = Double(max(0, inputTokens)) * price.input
            + Double(max(0, outputTokens)) * price.output
            + Double(max(0, cacheReadTokens)) * price.cacheRead
            + Double(max(0, cacheWriteTokens)) * price.cacheWrite
        return total / 1_000_000
    }

    // MARK: - Live model list

    /// The text models this key can use, fetched from the provider: built-in models first (in
    /// built-in order, with role and price), then the rest newest-looking first. Embedding,
    /// image, audio, realtime, moderation and other non-chat models are dropped.
    public static func listModels(provider: AIProvider, apiKey: String, session: URLSession = .shared) async throws -> [ModelInfo] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranslationError.missingAPIKey }
        let backend = ProviderBackends.backend(for: provider)

        var ids: [String: String] = [:]   // id → display name
        var page: String?
        // Bounded: a provider that keeps returning a next-page token must not loop forever.
        for _ in 0..<20 {
            var request = backend.modelsRequest(apiKey: key, pageToken: page)
            request.timeoutInterval = 20
            let (data, response) = try await HTTPSupport.send(request, session: session, maxRetries: 1, maxRetryDelay: 3,
                                                             sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
            guard response.statusCode == 200 else {
                throw backend.failure(status: response.statusCode, data: data).translationError(backend: backend, modelID: nil)
            }
            let parsed = try backend.parseModels(data)
            for model in parsed.models where ids[model.id] == nil { ids[model.id] = model.name }
            guard let next = parsed.nextPage, !next.isEmpty, next != page else { break }
            page = next
        }

        let known = builtIn(provider)
        var result = known.filter { ids[$0.id] != nil }
        let others = ids.keys.filter { id in !known.contains { $0.id == id } }
            .sorted { $0.compare($1, options: [.numeric, .caseInsensitive]) == .orderedDescending }
        for id in others {
            let name = ids[id].flatMap { $0.isEmpty ? nil : $0 } ?? id
            result.append(ModelInfo(provider: provider, id: id, displayName: name, role: nil,
                                    price: price(provider: provider, modelID: id)))
        }
        return result
    }

    /// "연결 확인": one authenticated request that costs nothing (the model list).
    public static func validateKey(provider: AIProvider, apiKey: String, session: URLSession = .shared) async -> Result<Void, TranslationError> {
        do {
            _ = try await listModels(provider: provider, apiKey: apiKey, session: session)
            return .success(())
        } catch let error as TranslationError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(.network("취소되었습니다"))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}

/// Claude prices by tier; the general table is `ModelCatalog`.
public enum ClaudePricing {
    public typealias Rate = ModelPrice

    public static let krwPerUSD = ModelCatalog.krwPerUSD

    public static func rate(for model: ModelChoice) -> Rate {
        ModelCatalog.price(provider: .claude, modelID: model.modelID)!
    }

    public static func usd(model: ModelChoice, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) -> Double {
        ModelCatalog.usd(rate(for: model), inputTokens: inputTokens, outputTokens: outputTokens,
                         cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens)
    }
}
