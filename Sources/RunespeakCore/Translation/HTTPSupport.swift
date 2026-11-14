import Foundation

/// Shared HTTP plumbing for the translators: bounded retry and URLError → TranslationError.
enum HTTPSupport {

    /// Sends `request`, retrying 429 / 5xx a bounded number of times and honouring `retry-after`.
    /// `shouldRetry` can veto a retry after looking at the error body. Returns whatever the last
    /// attempt answered (any status); throws `TranslationError.network` for transport failures,
    /// `.timedOut` when no answer came in time and `CancellationError` when the task was cancelled.
    static func send(_ request: URLRequest,
                     session: URLSession,
                     maxRetries: Int,
                     maxRetryDelay: TimeInterval,
                     retryRateLimit: Bool = true,
                     rateLimitNeedsRetryAfter: Bool = false,
                     shouldRetry: (@Sendable (_ status: Int, _ body: Data) -> Bool)? = nil,
                     sleep: @Sendable (TimeInterval) async throws -> Void) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                // A pooled connection the server already closed fails instantly; one retry is free.
                if error.code == .networkConnectionLost && attempt < maxRetries {
                    attempt += 1
                    continue
                }
                if error.code == .timedOut { throw TranslationError.timedOut }
                throw TranslationError.network(describe(error))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TranslationError.network(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else {
                throw TranslationError.badResponse("HTTP 응답이 아닙니다")
            }
            let retryable = (retryRateLimit && http.statusCode == 429) || (500...599).contains(http.statusCode)
            guard retryable, attempt < maxRetries, shouldRetry?(http.statusCode, data) ?? true else { return (data, http) }
            // A 429 that does not say when to come back is a per-minute limit as a rule: trying
            // again within a second only uses up more of it. The caller paces those.
            if http.statusCode == 429, rateLimitNeedsRetryAfter, retryAfter(http) == nil { return (data, http) }

            let delay = retryAfter(http) ?? min(maxRetryDelay, 0.5 * pow(2, Double(attempt)))
            // The server asked for a longer pause than live chat can sit through: report now.
            if delay > maxRetryDelay { return (data, http) }
            try await sleep(delay)
            attempt += 1
        }
    }

    /// `retry-after` in seconds. (The HTTP-date form is not used by these APIs.)
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespaces),
              let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "응답 시간 초과"
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return "인터넷에 연결되어 있지 않습니다"
        case .cannotFindHost, .dnsLookupFailed:
            return "서버 주소를 찾을 수 없습니다"
        case .cannotConnectToHost, .networkConnectionLost:
            return "서버에 연결할 수 없습니다"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "보안 연결에 실패했습니다"
        default:
            return error.localizedDescription
        }
    }
}
