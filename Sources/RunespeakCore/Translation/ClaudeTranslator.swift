import Foundation

/// The Claude translator: `LLMTranslator` over the Claude Messages API.
public final class ClaudeTranslator: LLMTranslator, @unchecked Sendable {
    public convenience init(apiKey: String, glossary: GlossaryProviding, usage: UsageTracking?, session: URLSession = .shared) {
        self.init(apiKey: apiKey, glossary: glossary, usage: usage, session: session, tuning: Tuning())
    }

    init(apiKey: String, glossary: GlossaryProviding, usage: UsageTracking?, session: URLSession, tuning: Tuning) {
        super.init(backend: ClaudeBackend(), apiKey: apiKey, glossary: glossary, usage: usage, session: session, tuning: tuning)
    }
}

/// Claude Messages API (raw HTTPS; there is no Swift SDK).
/// Facts from the Anthropic API reference (claude-api reference, cached 2026-11-03), read 2026-11-13.
struct ClaudeBackend: ProviderBackend {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let modelsEndpoint = "https://api.anthropic.com/v1/models"
    static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    var provider: AIProvider { .claude }

    /// How a model family turns thinking off for live chat.
    private enum Family {
        /// `thinking: {type: "disabled"}`; rejects `fallbacks`.
        case haiku
        /// Rejects "disabled"; `{type: "between_tools"}` is its thinking-off form.
        case sonnet
        /// Opus 5.5, Fable: thinking cannot be turned off — low effort is the fast setting.
        case other

        init(_ modelID: String) {
            let id = modelID.lowercased()
            if id.contains("haiku") { self = .haiku } else if id.contains("sonnet") { self = .sonnet } else { self = .other }
        }
    }

    func features(modelID: String, careful: Bool) -> Set<RequestFeature> {
        var set: Set<RequestFeature> = [.structuredOutput, .effort]
        let family = Family(modelID)
        // Haiku 5.5 rejects `fallbacks` outright; the others get the refusal fallback by default.
        if family != .haiku { set.insert(.fallbacks) }
        if !careful && family != .other { set.insert(.thinkingOff) }
        return set
    }

    static func requestBody(modelID: String, system: String = TranslationPrompt.system, user: String,
                            careful: Bool, features: Set<RequestFeature>) -> JSONValue {
        var thinking: JSONValue?
        if features.contains(.thinkingOff) {
            switch Family(modelID) {
            case .haiku: thinking = .obj(["type": .string("disabled")])
            case .sonnet: thinking = .obj(["type": .string("between_tools")])
            case .other: thinking = nil
            }
        }
        let effort: JSONValue? = features.contains(.effort) ? .string(careful ? "medium" : "low") : nil
        let format: JSONValue? = features.contains(.structuredOutput)
            ? .obj(["type": .string("json_schema"), "schema": TranslationPrompt.outputSchema])
            : nil
        return .obj([
            "model": .string(modelID),
            "max_tokens": .int(ProviderBackends.maxOutputTokens),
            "system": .array([
                .obj([
                    "type": .string("text"),
                    "text": .string(system),
                    "cache_control": .obj(["type": .string("ephemeral")]),
                ]),
            ]),
            "messages": .array([
                .obj(["role": .string("user"), "content": .string(user)]),
            ]),
            "thinking": thinking,
            "output_config": effort == nil && format == nil ? nil : .obj(["effort": effort, "format": format]),
            "fallbacks": features.contains(.fallbacks) ? .string("default") : nil,
        ])
    }

    func request(apiKey: String, modelID: String, system: String, user: String, careful: Bool, features: Set<RequestFeature>) -> URLRequest {
        var request = ProviderBackends.jsonRequest(
            Self.endpoint,
            headers: ["x-api-key": apiKey, "anthropic-version": Self.apiVersion],
            body: Self.requestBody(modelID: modelID, system: system, user: user, careful: careful, features: features))
        if features.contains(.fallbacks) {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }

    func parseResponse(_ data: Data) throws -> BackendResponse {
        let root = try ProviderBackends.object(data)
        var response = BackendResponse()
        if let u = root["usage"] as? [String: Any] {
            // Anthropic reports the three input kinds separately already.
            response.usage = BackendUsage(input: ProviderBackends.int(u["input_tokens"]),
                                          output: ProviderBackends.int(u["output_tokens"]),
                                          cacheRead: ProviderBackends.int(u["cache_read_input_tokens"]),
                                          cacheWrite: ProviderBackends.int(u["cache_creation_input_tokens"]))
        }
        let stopReason = root["stop_reason"] as? String
        let blocks = root["content"] as? [[String: Any]] ?? []
        response.text = blocks.filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        response.refused = stopReason == "refusal"
        response.truncated = stopReason == "max_tokens"
        return response
    }

    func rejectedFeature(_ failure: APIFailure, among active: Set<RequestFeature>) -> RequestFeature? {
        let text = failure.message.lowercased()
        if active.contains(.fallbacks), text.contains("fallback") || text.contains("anthropic-beta") {
            return .fallbacks
        }
        if active.contains(.thinkingOff), text.contains("thinking") {
            return .thinkingOff
        }
        if active.contains(.structuredOutput),
           text.contains("output_config.format") || text.contains("json_schema") || text.contains("structured output") || text.contains("schema") {
            return .structuredOutput
        }
        // Models before the 4.6 generation do not take `output_config.effort`.
        if active.contains(.effort), text.contains("effort") {
            return .effort
        }
        return nil
    }

    func kind(of failure: APIFailure) -> FailureKind? {
        // A drained prepaid balance arrives as a 400 invalid_request_error, not as a 402.
        let message = failure.message.lowercased()
        if failure.type == "billing_error" || message.contains("credit balance") {
            return .noCredit
        }
        // Spend limits: the one the user set in the Console arrives as a 400
        // invalid_request_error, the organisation's tier cap as a 429 rate_limit_error without
        // retry-after. Neither lifts before the month is over, so neither is worth retrying.
        // (Another 429 detail, "ramp_limit_exceeded", is an ordinary short-lived rate limit.)
        if failure.detailCode == "enforced_spend_limit_reached" || message.contains("api usage limits") {
            return .noCredit
        }
        switch failure.type {
        case "authentication_error": return .invalidKey
        case "rate_limit_error", "overloaded_error": return .rateLimited
        default: return failure.status == 529 ? .rateLimited : nil
        }
    }

    func modelsRequest(apiKey: String, pageToken: String?) -> URLRequest {
        var components = URLComponents(string: Self.modelsEndpoint)!
        components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
        if let pageToken { components.queryItems?.append(URLQueryItem(name: "after_id", value: pageToken)) }
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }

    func parseModels(_ data: Data) throws -> (models: [(id: String, name: String)], nextPage: String?) {
        let root = try ProviderBackends.object(data)
        let list = root["data"] as? [[String: Any]] ?? []
        let models = list.compactMap { item -> (id: String, name: String)? in
            guard let id = item["id"] as? String, id.hasPrefix("claude-") else { return nil }
            return (id, item["display_name"] as? String ?? id)
        }
        let more = (root["has_more"] as? Bool) == true
        return (models, more ? root["last_id"] as? String : nil)
    }

    func engineName(modelID: String) -> String {
        // The current tiers go by their short names: "Haiku", "Sonnet", "Opus".
        if let known = ModelCatalog.builtIn(.claude).first(where: { $0.id == modelID }), let tier = ModelChoice(modelID: known.id) {
            return tier.rawValue.capitalized
        }
        return ModelCatalog.displayName(provider: .claude, modelID: modelID)
    }
}
