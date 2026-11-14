import Foundation

/// OpenAI Responses API.
///
/// Facts from the OpenAI docs, read 2026-11-13:
/// - request / response / usage: https://developers.openai.com/api/reference/resources/responses/methods/create
/// - structured output (`text.format`): https://developers.openai.com/api/docs/guides/structured-outputs
/// - reasoning effort per model: https://developers.openai.com/api/docs/guides/reasoning and the model pages
/// - prompt caching: https://developers.openai.com/api/docs/guides/prompt-caching
/// - errors: https://developers.openai.com/api/docs/guides/error-codes
/// - model list: https://developers.openai.com/api/reference/resources/models/methods/list
struct OpenAIBackend: ProviderBackend {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!

    var provider: AIProvider { .openai }

    /// "gpt-6.1-sol" → 6.1; nil for ids that are not "gpt-<number>…".
    static func gptVersion(_ modelID: String) -> Double? {
        let id = modelID.lowercased()
        guard id.hasPrefix("gpt-") else { return nil }
        return Double(id.dropFirst(4).prefix { $0.isNumber || $0 == "." })
    }

    func features(modelID: String, careful: Bool) -> Set<RequestFeature> {
        let id = modelID.lowercased()
        let version = Self.gptVersion(id)
        var set: Set<RequestFeature> = [.structuredOutput]
        // GPT-4.x models are not reasoning models and reject `reasoning`.
        if version.map({ $0 >= 5 }) ?? true { set.insert(.effort) }
        // `reasoning.effort: "none"` exists on the small tiers (Luna, Terra; mini/nano before
        // them); Sol and Astra start at "low".
        if !careful, set.contains(.effort), ["luna", "terra", "mini", "nano"].contains(where: id.contains) {
            set.insert(.thinkingOff)
        }
        // `prompt_cache_options` is "supported for gpt-5.6 and later"; older models cache implicitly.
        if let version, version >= 5.6 { set.insert(.explicitCache) }
        return set
    }

    static func requestBody(modelID: String, system: String, user: String, careful: Bool, features: Set<RequestFeature>) -> JSONValue {
        let explicitCache = features.contains(.explicitCache)
        var effort: JSONValue?
        if features.contains(.effort) {
            effort = .string(careful ? "medium" : features.contains(.thinkingOff) ? "none" : "low")
        }
        return .obj([
            "model": .string(modelID),
            // The system prompt goes in a developer message, not in `instructions`: only a
            // content block can carry a cache breakpoint. With the breakpoint right after it
            // the frozen prompt is written to the cache once and read by every later request;
            // the default (implicit) mode would also write each request's chat payload, at
            // 1.25 × the input price, although no later request can reuse it.
            "input": .array([
                .obj([
                    "role": .string("developer"),
                    "content": .array([
                        .obj([
                            "type": .string("input_text"),
                            "text": .string(system),
                            "prompt_cache_breakpoint": explicitCache ? .obj(["mode": .string("explicit")]) : nil,
                        ]),
                    ]),
                ]),
                .obj([
                    "role": .string("user"),
                    "content": .array([.obj(["type": .string("input_text"), "text": .string(user)])]),
                ]),
            ]),
            "prompt_cache_options": explicitCache ? .obj(["mode": .string("explicit")]) : nil,
            "reasoning": effort.map { .obj(["effort": $0]) },
            "text": features.contains(.structuredOutput)
                ? .obj(["format": .obj([
                    "type": .string("json_schema"),
                    "name": .string("chat_translation"),
                    "strict": .bool(true),
                    "schema": TranslationPrompt.outputSchema,
                ])])
                : nil,
            // Includes reasoning tokens.
            "max_output_tokens": .int(ProviderBackends.maxOutputTokens),
            // Responses are stored for 30 days by default; chat text has no reason to be.
            "store": .bool(false),
        ])
    }

    func request(apiKey: String, modelID: String, system: String, user: String, careful: Bool, features: Set<RequestFeature>) -> URLRequest {
        ProviderBackends.jsonRequest(
            Self.endpoint,
            headers: ["authorization": "Bearer " + apiKey],
            body: Self.requestBody(modelID: modelID, system: system, user: user, careful: careful, features: features))
    }

    func parseResponse(_ data: Data) throws -> BackendResponse {
        let root = try ProviderBackends.object(data)
        var response = BackendResponse()
        if let u = root["usage"] as? [String: Any] {
            // `input_tokens` is the total; cached and cache-write tokens are parts of it.
            let details = u["input_tokens_details"] as? [String: Any] ?? [:]
            let read = ProviderBackends.int(details["cached_tokens"])
            let write = ProviderBackends.int(details["cache_write_tokens"])
            response.usage = BackendUsage(input: max(0, ProviderBackends.int(u["input_tokens"]) - read - write),
                                          output: ProviderBackends.int(u["output_tokens"]),   // reasoning tokens included
                                          cacheRead: read, cacheWrite: write)
        }
        for item in root["output"] as? [[String: Any]] ?? [] where (item["type"] as? String) == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
                switch part["type"] as? String {
                case "output_text": response.text += part["text"] as? String ?? ""
                case "refusal": response.refused = true
                default: break
                }
            }
        }
        let status = root["status"] as? String
        if status == "incomplete" {
            let reason = (root["incomplete_details"] as? [String: Any])?["reason"] as? String
            if reason == "content_filter" { response.refused = true } else { response.truncated = true }
        }
        if status == "failed", response.text.isEmpty {
            let message = (root["error"] as? [String: Any])?["message"] as? String ?? ""
            throw TranslationError.badResponse("모델이 응답을 만들지 못했습니다" + (message.isEmpty ? "" : ": " + String(message.prefix(120))))
        }
        return response
    }

    func rejectedFeature(_ failure: APIFailure, among active: Set<RequestFeature>) -> RequestFeature? {
        let text = (failure.param + " " + failure.message).lowercased()
        if active.contains(.explicitCache), text.contains("prompt_cache") {
            return .explicitCache
        }
        if text.contains("reasoning") || text.contains("effort") {
            // First give up "none" (fall back to "low"), then the setting altogether.
            if active.contains(.thinkingOff) { return .thinkingOff }
            if active.contains(.effort) { return .effort }
        }
        if active.contains(.structuredOutput),
           text.contains("text.format") || text.contains("json_schema") || text.contains("schema") || text.contains("structured output") {
            return .structuredOutput
        }
        return nil
    }

    func kind(of failure: APIFailure) -> FailureKind? {
        switch failure.code {
        case "invalid_api_key":
            return .invalidKey
        // "For billing-related errors, inspect error.code … The broader error.type can still be insufficient_quota."
        case "insufficient_quota", "credit_balance_exhausted", "billing_hard_limit_reached",
             "organization_spend_limit_exceeded", "project_spend_limit_exceeded", "organization_usage_limit_exceeded":
            return .noCredit
        case "model_not_found":
            return .modelNotFound
        case "rate_limit_exceeded", "slow_down", "server_is_overloaded":
            return .rateLimited
        default:
            break
        }
        if failure.type == "insufficient_quota" { return .noCredit }
        return nil
    }

    func modelsRequest(apiKey: String, pageToken: String?) -> URLRequest {
        var request = URLRequest(url: Self.modelsEndpoint)
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "authorization")
        return request
    }

    /// Words in an OpenAI model id that mark something other than a text-in, text-out chat model
    /// (or one that needs special access).
    static let nonChatWords = ["audio", "realtime", "live", "image", "transcribe", "tts", "whisper", "embedding",
                               "moderation", "search", "instruct", "codex", "computer-use", "oss", "cyber", "rosalind",
                               "dall-e", "sora", "deep-research"]

    func parseModels(_ data: Data) throws -> (models: [(id: String, name: String)], nextPage: String?) {
        let root = try ProviderBackends.object(data)
        let list = root["data"] as? [[String: Any]] ?? []
        let models = list.compactMap { item -> (id: String, name: String)? in
            guard let id = item["id"] as? String else { return nil }
            let lower = id.lowercased()
            let family = lower.hasPrefix("gpt-") || lower.hasPrefix("chat") || lower.range(of: #"^o\d"#, options: .regularExpression) != nil
            // Fine-tunes ("ft:gpt-…") do not start with a family prefix and are left out on purpose.
            guard family, ProviderBackends.isChatModel(lower, excluding: Self.nonChatWords) else { return nil }
            return (id, id)
        }
        return (models, nil)   // the list is not paginated
    }
}
