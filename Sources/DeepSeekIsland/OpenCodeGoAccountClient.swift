import Foundation

enum OpenCodeGoAccountError: LocalizedError {
    case authorization
    case server(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .authorization: "OpenCode Go API Key 无效或已失效，请重新填写"
        case .server(let status): "OpenCode Go 接口请求失败（HTTP \(status)）"
        case .invalidResponse: "OpenCode Go 接口返回了无法识别的数据"
        }
    }
}

protocol OpenCodeGoServing: Sendable {
    func fetchQuota(apiKey: String) async throws -> OpenCodeGoQuota
}

/// Reads the Go subscription allowance. The Go API key is different from the
/// Zen balance key; it is sent only to OpenCode's own usage endpoint.
struct OpenCodeGoAccountClient: OpenCodeGoServing {
    private static let primaryURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private static let fallbackURL = URL(string: "https://opencode.ai/inference/go/v1/usage")!
    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "AIUsageIsland/\(version)"
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        session = URLSession(configuration: configuration)
    }

    func fetchQuota(apiKey: String) async throws -> OpenCodeGoQuota {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 4_096, !key.contains("\n"), !key.contains("\r") else {
            throw OpenCodeGoAccountError.authorization
        }
        do {
            return try await fetch(url: Self.primaryURL, apiKey: key)
        } catch OpenCodeGoAccountError.server(404) {
            return try await fetch(url: Self.fallbackURL, apiKey: key)
        }
    }

    private func fetch(url: URL, apiKey: String) async throws -> OpenCodeGoQuota {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeGoAccountError.invalidResponse }
        if http.statusCode == 429 {
            throw UsageRefreshFailure.rateLimited(until: RefreshPolicy.retryDate(http.value(forHTTPHeaderField: "Retry-After")))
        }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw OpenCodeGoAccountError.authorization
        default: throw OpenCodeGoAccountError.server(http.statusCode)
        }
        guard data.count <= 131_072 else { throw OpenCodeGoAccountError.invalidResponse }
        do {
            return try OpenCodeGoQuotaParser.parse(data)
        } catch let error as OpenCodeGoQuotaError {
            switch error {
            case .authorization: throw OpenCodeGoAccountError.authorization
            case .noQuota, .invalidResponse: throw error
            }
        }
    }
}

enum OpenCodeGoUsageAdapter {
    static func failure(for error: Error) -> UsageRefreshFailure {
        if let failure = UsageRefreshFailure.sharedFailure(for: error) { return failure }
        if let error = error as? OpenCodeGoAccountError {
            switch error {
            case .authorization: return .authorization
            case .server(let status): return .http(status)
            case .invalidResponse: return .invalidResponse
            }
        }
        if let error = error as? OpenCodeGoQuotaError {
            switch error {
            case .authorization: return .authorization
            case .noQuota: return .noQuota
            case .invalidResponse: return .invalidResponse
            }
        }
        return .unknown
    }
}
