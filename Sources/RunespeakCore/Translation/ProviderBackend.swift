import Foundation

/// Optional parts of a request. Each is dropped (for that model, until the app restarts) when
/// the API rejects it with a 400, so an account or a model that lacks one still translates.
enum RequestFeature: Hashable, Sendable, CaseIterable {
    /// The model's "no thinking" setting — fastest for live chat. Without it the lowest
    /// ordinary reasoning level is used.
    case thinkingOff
    /// Any explicit reasoning-effort setting. Without it the model's default applies.
    case effort
    /// Claude: server-side refusal fallback (`fallbacks: "default"` + beta header).
    case fallbacks
    /// JSON-schema constrained output; without it the prompt's format instruction and the
    /// tolerant parser carry the load.
    case structuredOutput
    /// OpenAI: an explicit prompt-cache breakpoint after the system prompt.
    case explicitCache
}

/// Token counts of one response, already split the way `UsageTracking.record` wants them.
struct BackendUsage: Equatable, Sendable {
    /// Input billed at the full rate (not read from, not written to the cache).
    var input = 0
    /// Includes reasoning/thinking tokens.
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
}

struct BackendResponse: Equatable, Sendable {
    /// The model's visible text, all text parts joined.
    var text = ""
    var usage: BackendUsage?
    /// Stopped at the output-token limit.
    var truncated = false
    /// The model or a safety filter declined.
    var refused = false
}

/// What a provider's error means, where the HTTP status alone does not say it.
enum FailureKind: Equatable, Sendable {
    case invalidKey, noCredit, rateLimited, modelNotFound
}

/// A non-200 answer, reduced to the fields the three APIs share.
struct APIFailure: Equatable, Sendable {
    var status: Int
    /// `error.type` (Anthropic, OpenAI) or the gRPC-style `error.status` (older Google endpoints).
    var type = ""
    /// `error.code` (OpenAI, Gemini).
    var code = ""
    /// `error.param` (OpenAI): the request field at fault.
    var param = ""
    var message = ""
    /// `error.details.error_code` (Anthropic): what kind of limit a 429 is about.
    var detailCode = ""

    /// Reads `{"error": {"type" | "status", "code", "param", "message"}}`; anything else
    /// (an HTML gateway page) leaves the fields empty.
    init(status: Int, data: Data) {
        self.status = status
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let error = root?["error"] as? [String: Any] else { return }
        type = (error["type"] as? String) ?? (error["status"] as? String) ?? ""
        if let text = error["code"] as? String { code = text } else if let number = error["code"] as? NSNumber { code = number.stringValue }
        param = error["param"] as? String ?? ""
        message = error["message"] as? String ?? ""
        detailCode = (error["details"] as? [String: Any])?["error_code"] as? String ?? ""
    }

    /// The one place where API failures become user-facing errors. `modelID` is the model the
    /// request asked for, nil for requests that name none (the model list).
    func translationError(backend: ProviderBackend, modelID: String?) -> TranslationError {
        switch backend.kind(of: self) {
        case .invalidKey: return .invalidAPIKey
        case .noCredit: return .insufficientCredit
        case .rateLimited: return .rateLimited
        case .modelNotFound: if let modelID { return .modelNotFound(modelID) }
        case nil: break
        }
        switch status {
        case 401:
            return .invalidAPIKey
        case 402:
            return .insufficientCredit
        case 429:
            return .rateLimited
        case 408:
            return .network("시간 초과")
        case 403:
            return .badResponse("이 API 키로는 사용할 수 없습니다 (403)")
        case 404:
            if let modelID { return .modelNotFound(modelID) }
            return .badResponse("요청한 주소를 찾을 수 없습니다 (404)")
        case 413:
            return .badResponse("요청이 너무 큽니다 (413)")
        case 500...599:
            return .badResponse("\(backend.provider.companyName) 서버 오류 (\(status))")
        default:
            let detail = message.isEmpty ? "" : ": " + String(message.prefix(120))
            return .badResponse("요청 오류 (\(status))\(detail)")
        }
    }
}

/// The wire format of one provider's API. Stateless; everything else is `LLMTranslator`.
protocol ProviderBackend: Sendable {
    var provider: AIProvider { get }

    /// The optional features to try for this model. `careful` is the retranslation profile.
    func features(modelID: String, careful: Bool) -> Set<RequestFeature>

    /// The generation request: endpoint, auth headers, body. The stable part (model, system
    /// prompt) must come first and be byte-identical between requests so prompt caches can hit.
    /// `addendum` is system prompt that only some requests carry: it goes behind `system`,
    /// outside the cached part, so that `system` stays the cache entry of every request.
    func request(apiKey: String, modelID: String, system: String, addendum: String?, user: String, careful: Bool,
                 features: Set<RequestFeature>) -> URLRequest

    /// Reads a 200 body. Throws `TranslationError.badResponse` when it is not this API's JSON.
    func parseResponse(_ data: Data) throws -> BackendResponse

    func failure(status: Int, data: Data) -> APIFailure

    /// Which active optional feature a 400 is complaining about, if any.
    func rejectedFeature(_ failure: APIFailure, among active: Set<RequestFeature>) -> RequestFeature?

    /// Provider-specific reading of an error body; nil leaves it to the HTTP status.
    func kind(of failure: APIFailure) -> FailureKind?

    /// The model-list request; `pageToken` is whatever `parseModels` returned as `nextPage`.
    func modelsRequest(apiKey: String, pageToken: String?) -> URLRequest

    /// Models usable for chat translation only (no embeddings, image, audio, realtime, moderation…).
    func parseModels(_ data: Data) throws -> (models: [(id: String, name: String)], nextPage: String?)

    /// Shown next to a translation.
    func engineName(modelID: String) -> String
}

extension ProviderBackend {
    func failure(status: Int, data: Data) -> APIFailure { APIFailure(status: status, data: data) }

    func engineName(modelID: String) -> String {
        ModelCatalog.displayName(provider: provider, modelID: modelID)
    }
}

enum ProviderBackends {
    static func backend(for provider: AIProvider) -> ProviderBackend {
        switch provider {
        case .claude: return ClaudeBackend()
        case .openai: return OpenAIBackend()
        case .gemini: return GeminiBackend()
        }
    }

    /// Output-token ceiling for every provider. Reasoning/thinking tokens count against it on
    /// models where thinking cannot be turned off, so it is deliberately far above what a batch
    /// of chat lines needs.
    static let maxOutputTokens = 16_000

    static func jsonRequest(_ url: URL, headers: KeyValuePairs<String, String>, body: JSONValue) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data(body.serialized().utf8)
        return request
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TranslationError.badResponse("응답을 읽을 수 없습니다")
        }
        return root
    }

    static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    /// True when `id` contains none of the words that mark a non-chat model.
    static func isChatModel(_ id: String, excluding words: [String]) -> Bool {
        let lower = id.lowercased()
        return !words.contains { lower.contains($0) }
    }
}

/// Builds the translator for a provider.
public enum TranslatorFactory {
    public static func make(provider: AIProvider, apiKey: String, glossary: GlossaryProviding,
                            usage: UsageTracking?, session: URLSession = .shared) -> Translating {
        LLMTranslator(provider: provider, apiKey: apiKey, glossary: glossary, usage: usage, session: session)
    }
}

extension ProviderBackend {
    /// A request that carries the frozen system prompt and nothing behind it.
    func request(apiKey: String, modelID: String, system: String, user: String, careful: Bool, features: Set<RequestFeature>) -> URLRequest {
        request(apiKey: apiKey, modelID: modelID, system: system, addendum: nil, user: user, careful: careful, features: features)
    }
}
