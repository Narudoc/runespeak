import Foundation

/// Google Gemini API, Interactions endpoint (the docs call `generateContent` legacy).
///
/// Facts from the Gemini API docs, read 2026-11-13 (ai.google.dev/gemini-api/docs redirects to aistudio.google.com/docs):
/// - request (`system_instruction`, `input`, `generation_config`, `store`): https://aistudio.google.com/docs/text-generation
/// - response and usage fields: https://aistudio.google.com/api-reference/interactions-api/create-interaction
/// - structured output (`response_format`): https://aistudio.google.com/docs/structured-output
/// - thinking levels per model: https://aistudio.google.com/docs/thinking
/// - implicit caching: https://aistudio.google.com/docs/caching
/// - errors: https://aistudio.google.com/docs/api-errors
/// - model list: https://aistudio.google.com/api-reference/models/list-models
struct GeminiBackend: ProviderBackend {
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    static let modelsEndpoint = "https://generativelanguage.googleapis.com/v1beta/models"
    /// The `Api-Revision` the documented request and response shapes belong to.
    static let apiRevision = "2026-05-20"

    var provider: AIProvider { .gemini }

    func features(modelID: String, careful: Bool) -> Set<RequestFeature> {
        let id = modelID.lowercased()
        var set: Set<RequestFeature> = [.structuredOutput, .effort]
        // `thinking_level: "minimal"` (near-off) exists on the Flash-Lite models, 3.6 Flash and
        // 3 Flash; Gemini 4 and 3.8 Flash start at "low".
        if !careful, id.contains("flash-lite") || id.hasPrefix("gemini-3.6-flash") || id.hasPrefix("gemini-3-flash") {
            set.insert(.thinkingOff)
        }
        return set
    }

    static func requestBody(modelID: String, system: String, user: String, careful: Bool, features: Set<RequestFeature>) -> JSONValue {
        var level: JSONValue?
        if features.contains(.effort) {
            level = .string(careful ? "medium" : features.contains(.thinkingOff) ? "minimal" : "low")
        }
        // No explicit cache control exists on this endpoint: caching is implicit and keyed on
        // the prefix, so the frozen system instruction comes first.
        return .obj([
            "model": .string(modelID),
            "system_instruction": .string(system),
            "input": .string(user),
            "response_format": features.contains(.structuredOutput)
                ? .obj([
                    "type": .string("text"),
                    "mime_type": .string("application/json"),
                    "schema": TranslationPrompt.outputSchema,
                ])
                : nil,
            "generation_config": .obj([
                "thinking_level": level,
                "max_output_tokens": .int(ProviderBackends.maxOutputTokens),
            ]),
            // Interactions are stored server-side unless this is set; chat text has no reason to be.
            "store": .bool(false),
        ])
    }

    func request(apiKey: String, modelID: String, system: String, user: String, careful: Bool, features: Set<RequestFeature>) -> URLRequest {
        // The key travels in a header, never in the URL: URLs end up in logs and proxies.
        ProviderBackends.jsonRequest(
            Self.endpoint,
            headers: ["x-goog-api-key": apiKey, "api-revision": Self.apiRevision],
            body: Self.requestBody(modelID: modelID, system: system, user: user, careful: careful, features: features))
    }

    /// `error.code` values that mean policy or safety blocked the answer.
    static let blockedCodes: Set<String> = ["safety", "recitation", "language", "prohibited_content", "spii", "blocklist", "content_blocked"]

    func parseResponse(_ data: Data) throws -> BackendResponse {
        let root = try ProviderBackends.object(data)
        var response = BackendResponse()
        if let u = root["usage"] as? [String: Any] {
            // Cached tokens are part of `total_input_tokens`; thought tokens are billed as
            // output but counted apart from `total_output_tokens`.
            let read = ProviderBackends.int(u["total_cached_tokens"])
            response.usage = BackendUsage(input: max(0, ProviderBackends.int(u["total_input_tokens"]) - read),
                                          output: ProviderBackends.int(u["total_output_tokens"]) + ProviderBackends.int(u["total_thought_tokens"]),
                                          cacheRead: read, cacheWrite: 0)
        }
        for step in root["steps"] as? [[String: Any]] ?? [] where (step["type"] as? String) == "model_output" {
            for part in step["content"] as? [[String: Any]] ?? [] where (part["type"] as? String) == "text" {
                response.text += part["text"] as? String ?? ""
            }
        }
        let status = root["status"] as? String
        let error = root["error"] as? [String: Any]
        let code = error?["code"] as? String ?? ""
        if Self.blockedCodes.contains(code) {
            response.refused = true
        } else if status == "incomplete" {
            response.truncated = true
        } else if status == "failed" || status == "cancelled", response.text.isEmpty {
            let message = error?["message"] as? String ?? ""
            throw TranslationError.badResponse("모델이 응답을 만들지 못했습니다" + (message.isEmpty ? "" : ": " + String(message.prefix(120))))
        }
        return response
    }

    func rejectedFeature(_ failure: APIFailure, among active: Set<RequestFeature>) -> RequestFeature? {
        let text = failure.message.lowercased()
        if text.contains("thinking") {
            // First give up "minimal" (fall back to "low"), then the setting altogether.
            if active.contains(.thinkingOff) { return .thinkingOff }
            if active.contains(.effort) { return .effort }
        }
        if active.contains(.structuredOutput),
           text.contains("response_format") || text.contains("schema") || text.contains("mime_type") {
            return .structuredOutput
        }
        return nil
    }

    func kind(of failure: APIFailure) -> FailureKind? {
        let text = failure.message.lowercased()
        // The Interactions endpoint answers with snake_case string codes; the older endpoints
        // (the model list) with a numeric code plus an upper-case `status`, which lands in `type`.
        switch failure.code {
        case "authentication": return .invalidKey
        case "payment_required", "quota_exceeded": return .noCredit
        case "model_not_found": return .modelNotFound
        case "rate_limit_exceeded", "too_many_requests", "service_unavailable": return .rateLimited
        case "failed_precondition" where text.contains("billing"): return .noCredit
        case "not_found" where text.contains("model"): return .modelNotFound
        default: break
        }
        // An invalid key is a 400 INVALID_ARGUMENT there, not a 401.
        if text.contains("api key not valid") || text.contains("api_key_invalid") || failure.type == "UNAUTHENTICATED" {
            return .invalidKey
        }
        if failure.type == "NOT_FOUND", text.contains("model") { return .modelNotFound }
        if failure.status == 503 { return .rateLimited }
        return nil
    }

    func modelsRequest(apiKey: String, pageToken: String?) -> URLRequest {
        var components = URLComponents(string: Self.modelsEndpoint)!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
        if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    /// Words in a Gemini model id that mark something other than a text-in, text-out chat model.
    static let nonChatWords = ["embedding", "image", "banana", "tts", "live", "audio", "transcribe", "omni",
                               "robotics", "computer-use", "deep-research", "veo", "imagen", "lyria", "aqa"]
    /// A model whose methods are all in this set cannot generate text.
    static let nonGenerationMethods: Set<String> = ["embedContent", "batchEmbedContents", "asyncBatchEmbedContent", "countTokens",
                                                    "predict", "predictLongRunning", "bidiGenerateContent", "createCachedContent"]

    func parseModels(_ data: Data) throws -> (models: [(id: String, name: String)], nextPage: String?) {
        let root = try ProviderBackends.object(data)
        let list = root["models"] as? [[String: Any]] ?? []
        let models = list.compactMap { item -> (id: String, name: String)? in
            guard let name = item["name"] as? String else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            guard id.lowercased().hasPrefix("gemini-"), ProviderBackends.isChatModel(id, excluding: Self.nonChatWords) else { return nil }
            if let methods = item["supportedGenerationMethods"] as? [String], !methods.isEmpty,
               Self.nonGenerationMethods.isSuperset(of: methods) {
                return nil
            }
            return (id, item["displayName"] as? String ?? id)
        }
        return (models, root["nextPageToken"] as? String)
    }
}
