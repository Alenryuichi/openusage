import Foundation

struct DeepSeekUsageClient: Sendable {
    static let balanceURL = "https://api.deepseek.com/user/balance"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Account balance: whether the account can still call the API, plus one entry per currency the
    /// balance is held in (`CNY` / `USD`), each split into granted and topped-up credit.
    func fetchBalance(apiKey: String) async throws -> HTTPResponse {
        guard let url = URL(string: Self.balanceURL) else {
            throw DeepSeekUsageError.invalidResponse
        }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum DeepSeekUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case noBalance
    /// The stored or discovered key was rejected (HTTP 401/403).
    case invalidKey
    /// DSH's session logs exist but none could be read this refresh.
    case logsUnreadable

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach DeepSeek. Check your connection."
        case .invalidResponse:
            return "DeepSeek balance unavailable. Try again later."
        case .requestFailed(let status):
            return "DeepSeek request failed (HTTP \(status))."
        case .noBalance:
            return "DeepSeek returned no balance for this key."
        case .invalidKey:
            return DeepSeekAuthError.invalidKey.errorDescription
        case .logsUnreadable:
            return "Couldn't read DSH's local session logs. Check the permissions on ~/.dsh."
        }
    }
}
