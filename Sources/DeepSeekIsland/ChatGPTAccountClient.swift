import Foundation

/// 本机保存的 ChatGPT 授权。和 DeepSeek 的令牌一样放在应用自己的目录里（0600），
/// **不读也不写 Codex CLI 的 `~/.codex/auth.json`**。
struct ChatGPTGrant: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    /// 多工作区账号要带 `ChatGPT-Account-Id`，单账号不带也能查。
    var accountID: String?
    var savedAt: Date
    var resolvedAccountID: String? {
        for value in [accountID, JWTClaim.accountID(in: accessToken)] {
            if let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty { return cleaned }
        }
        return nil
    }
}

enum ChatGPTAccountError: LocalizedError {
    case authorization
    case server(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .authorization: "ChatGPT 授权已失效，请重新登录"
        case .server(let status): "ChatGPT 接口请求失败（HTTP \(status)）"
        case .invalidResponse: "ChatGPT 接口返回了无法识别的数据"
        }
    }
}

/// ChatGPT（Codex）额度接口客户端。
///
/// - 额度：`GET https://chatgpt.com/backend-api/wham/usage`，只带 Bearer 就够
///   （实测不需要 originator / cookie / CSRF；这条路径不被 Cloudflare 挑战）。
/// - 令牌：`POST https://auth.openai.com/oauth/token`，请求体是 JSON。
protocol ChatGPTServing: Sendable {
    func fetchQuota(grant: ChatGPTGrant) async throws -> ChatGPTQuota
    func refresh(_ grant: ChatGPTGrant) async throws -> ChatGPTGrant
    func fetchAnalysis(grant: ChatGPTGrant) async throws -> UsageAnalysisSnapshot
}
extension ChatGPTServing {
    func fetchAnalysis(grant: ChatGPTGrant) async throws -> UsageAnalysisSnapshot { throw UsageAnalysisError.unavailable }
}

struct ChatGPTAccountClient: ChatGPTServing {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = URL(string: "https://auth.openai.com")!
    /// 只申请查额度需要的权限。Codex CLI 还会多要两个 `api.connectors.*`——
    /// 那是给它的连接器功能用的，这里不需要，也就不该向用户要。
    /// 万一授权页以 `invalid_scope` 拒绝这个子集，在这里补上
    /// `api.connectors.read api.connectors.invoke` 即可（其余参数都不用动）。
    static let scope = "openid profile email offline_access"

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        session = URLSession(configuration: config)
    }

    // MARK: - 额度

    func fetchQuota(grant: ChatGPTGrant) async throws -> ChatGPTQuota {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(grant.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = grant.resolvedAccountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTAccountError.invalidResponse }
        if http.statusCode == 429 { throw UsageRefreshFailure.rateLimited(until: RefreshPolicy.retryDate(http.value(forHTTPHeaderField: "Retry-After"))) }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw ChatGPTAccountError.authorization
        default: throw ChatGPTAccountError.server(http.statusCode)
        }
        guard data.count <= 262_144 else { throw ChatGPTAccountError.invalidResponse }
        do {
            return try ChatGPTQuotaParser.parse(data)
        } catch let error as ChatGPTQuotaError {
            switch error {
            case .authorization: throw ChatGPTAccountError.authorization
            case .noQuota, .invalidResponse: throw error
            }
        }
    }

    /// Account-wide official daily usage; never reads another client's auth or sessions.
    func fetchAnalysis(grant: ChatGPTGrant) async throws -> UsageAnalysisSnapshot {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(grant.accessToken)", forHTTPHeaderField: "Authorization")
        if let id = grant.resolvedAccountID { request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTAccountError.invalidResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 429 { throw UsageRefreshFailure.rateLimited(until: RefreshPolicy.retryDate(http.value(forHTTPHeaderField: "Retry-After"))) }
            throw UsageAnalysisError.unavailable
        }
        return try UsageAnalysisParser.chatGPT(data)
    }

    // MARK: - 令牌

    func exchange(code: String, verifier: String, redirectURI: String) async throws -> ChatGPTGrant {
        let tokens = try await tokenRequest([
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
        return try grant(from: tokens, previous: nil)
    }

    /// 用自己那份 refresh token 换新的 access token。
    ///
    /// OpenAI 的 refresh token 是**一次性**的：换一次就作废旧的。这是本应用自己
    /// 登录拿到的那一份，所以刷新只影响自己；反过来说，**绝不能**拿 Codex CLI 的
    /// refresh token 来刷——那会把用户的 CLI 挤下线。
    func refresh(_ grant: ChatGPTGrant) async throws -> ChatGPTGrant {
        let tokens = try await tokenRequest([
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": grant.refreshToken,
        ])
        return try self.grant(from: tokens, previous: grant)
    }

    private func grant(from tokens: [String: Any], previous: ChatGPTGrant?) throws -> ChatGPTGrant {
        guard let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw ChatGPTAccountError.invalidResponse
        }
        let refresh = (tokens["refresh_token"] as? String) ?? previous?.refreshToken
        guard let refresh, !refresh.isEmpty else { throw ChatGPTAccountError.invalidResponse }
        let accountID = JWTClaim.accountID(in: tokens["id_token"] as? String)
            ?? JWTClaim.accountID(in: access)
            ?? previous?.accountID
        return ChatGPTGrant(accessToken: access, refreshToken: refresh,
                            accountID: accountID, savedAt: .now)
    }

    private func tokenRequest(_ body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTAccountError.invalidResponse }
        if http.statusCode == 429 { throw UsageRefreshFailure.rateLimited(until: RefreshPolicy.retryDate(http.value(forHTTPHeaderField: "Retry-After"))) }
        guard http.statusCode == 200 else {
            if http.statusCode == 400 || http.statusCode == 401 { throw ChatGPTAccountError.authorization }
            throw ChatGPTAccountError.server(http.statusCode)
        }
        guard data.count <= 131_072,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTAccountError.invalidResponse
        }
        if object["error"] != nil { throw ChatGPTAccountError.authorization }
        return object
    }
}

/// 从 JWT 里取 `https://api.openai.com/auth` 下的 `chatgpt_account_id`。
///
/// 只解 payload，不验签——这里只是拿自己的账号 id 当请求头，不用于任何信任判断。
enum JWTClaim {
    static func accountID(in token: String?) -> String? {
        guard let token, let payload = payload(of: token) else { return nil }
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        return (auth?["chatgpt_account_id"] as? String) ?? (payload["chatgpt_account_id"] as? String)
    }

    static func payload(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), data.count <= 32_768,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}
