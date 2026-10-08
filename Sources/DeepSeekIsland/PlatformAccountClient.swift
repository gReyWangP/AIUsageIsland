import Foundation

struct AccountSummary: Sendable {
    let balances: [String: Decimal]
}

struct AccountProfile: Sendable {
    let displayName: String
    var identity: String? = nil
    var identityAliases: Set<String> = []
    var verifiedIdentities: Set<String> { identityAliases.union(identity.map { [$0] } ?? []) }

    /// nil means the identities cannot be compared reliably.
    func matchesIdentity(of other: AccountProfile) -> Bool? {
        guard let identity, let otherIdentity = other.identity else { return nil }
        if identity.hasPrefix("user:"), otherIdentity.hasPrefix("user:") {
            return identity == otherIdentity
        }
        if !verifiedIdentities.isDisjoint(with: other.verifiedIdentities) { return true }
        let namespaces = Set(verifiedIdentities.map { $0.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "" })
        let otherNamespaces = Set(other.verifiedIdentities.map { $0.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "" })
        return namespaces.isDisjoint(with: otherNamespaces) ? nil : false
    }
}

struct OfficialUsageTotal: Sendable {
    let tokens: Int64
    let cost: Decimal
}

struct OfficialUsageSummary: Sendable {
    let today: OfficialUsageTotal
    let sevenDays: OfficialUsageTotal
    let month: OfficialUsageTotal
    var analysis: UsageAnalysisSnapshot? = nil

    init(amount: [Int64: Int64], cost: [Int64: Decimal], ranges: UsageRanges) {
        func total(in range: UsageRange) -> OfficialUsageTotal {
            OfficialUsageTotal(
                tokens: amount.reduce(0) { $0 + (range.contains($1.key) ? $1.value : 0) },
                cost: cost.reduce(.zero) { $0 + (range.contains($1.key) ? $1.value : .zero) }
            )
        }
        today = total(in: ranges.today)
        sevenDays = total(in: ranges.sevenDays)
        month = total(in: ranges.month)
    }
}

struct AuthInitialization: Decodable {
    let authorizeURL: String
    let expiresIn: Double

    enum CodingKeys: String, CodingKey {
        case authorizeURL = "authorize_url"
        case expiresIn = "expires_in"
    }
}

struct AuthExchange: Decodable {
    let token: String
    let authorizedURL: String

    enum CodingKeys: String, CodingKey {
        case token
        case authorizedURL = "authorized_url"
    }
}

enum PlatformError: LocalizedError {
    case invalidResponse
    case expired
    case invalidAuthorizationURL
    case server(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "DeepSeek 平台返回了无法识别的数据"
        case .expired: "账号授权已失效，请重新登录"
        case .invalidAuthorizationURL: "DeepSeek 授权地址不符合预期"
        case .server(let status): "DeepSeek 平台请求失败（HTTP \(status)）"
        case .cancelled: "登录已取消或超时"
        }
    }
}

private struct PlatformEnvelope<Value: Decodable>: Decodable {
    let code: Int
    let data: Business<Value>

    struct Business<Inner: Decodable>: Decodable {
        let bizCode: Int
        let bizData: Inner

        enum CodingKeys: String, CodingKey {
            case bizCode = "biz_code"
            case bizData = "biz_data"
        }
    }
}

private struct PlatformSummaryPayload: Decodable {
    struct Wallet: Decodable {
        let currency: String
        let balance: String
    }
    let normalWallets: [Wallet]
    let bonusWallets: [Wallet]

    enum CodingKeys: String, CodingKey {
        case normalWallets = "normal_wallets"
        case bonusWallets = "bonus_wallets"
    }
}

private struct PlatformProfilePayload: Decodable {
    struct Identity: Decodable {
        let name: String?
    }

    let id: PlatformNumber?
    let userID: PlatformNumber?
    let email: String?
    let mobile: String?
    let mobileNumber: String?
    let identity: Identity?

    enum CodingKeys: String, CodingKey {
        case id, email, mobile
        case userID = "user_id"
        case mobileNumber = "mobile_number"
        case identity = "id_profile"
    }
}

private struct PlatformNumber: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            text = value
        } else if let value = try? container.decode(Int64.self) {
            text = String(value)
        } else {
            throw PlatformError.invalidResponse
        }
    }
}

private struct PlatformAmountPayload: Decodable {
    struct Series: Decodable {
        struct Bucket: Decodable {
            let time: Int64
            let usage: [String: PlatformNumber]
        }
        let buckets: [Bucket]
    }
    let series: [Series]
}

private struct PlatformCostPayload: Decodable {
    struct Currency: Decodable {
        struct Series: Decodable {
            struct Bucket: Decodable {
                let time: Int64
                let cost: PlatformNumber
            }
            let buckets: [Bucket]
        }
        let currency: String
        let series: [Series]
    }
    let data: [Currency]
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct PlatformAccountClient: PlatformAuthServing, DeepSeekServing {
    private static let origin = URL(string: "https://platform.deepseek.com")!
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    static func validateAuthorizeURL(_ raw: String) throws -> URL {
        try validateBrowserURL(raw, path: "/dsh/authorize")
    }

    static func validateCompletionURL(_ raw: String) throws -> URL {
        try validateBrowserURL(raw, path: "/dsh/authorized")
    }

    private static func validateBrowserURL(_ raw: String, path: String) throws -> URL {
        guard let url = URL(string: raw),
              url.scheme == "https", url.host == origin.host,
              url.port == nil, url.user == nil, url.password == nil,
              url.path == path, url.fragment == nil else {
            throw PlatformError.invalidAuthorizationURL
        }
        return url
    }

    static func decodeSummary(_ data: Data) throws -> AccountSummary {
        let payload: PlatformSummaryPayload = try decodeBusiness(data)
        var balances: [String: Decimal] = [:]
        for wallet in payload.normalWallets + payload.bonusWallets {
            guard let amount = Decimal(string: wallet.balance, locale: Locale(identifier: "en_US_POSIX")) else {
                throw PlatformError.invalidResponse
            }
            balances[wallet.currency, default: .zero] += amount
        }
        return AccountSummary(balances: balances)
    }

    static func decodeProfile(_ data: Data) throws -> AccountProfile {
        let payload: PlatformProfilePayload = try decodeBusiness(data)
        let candidates = [payload.identity?.name, payload.email, payload.mobile, payload.mobileNumber]
        guard let displayName = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            throw PlatformError.invalidResponse
        }
        let email = payload.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let phone = (payload.mobile ?? payload.mobileNumber)?.filter { !$0.isWhitespace }
        var contacts: Set<String> = []
        if let email, email.contains("@"), !email.contains("*") { contacts.insert("email:" + email) }
        if let phone, phone.count >= 6, phone.allSatisfy({ $0.isNumber || $0 == "+" }) { contacts.insert("phone:" + phone) }
        let ids = [payload.userID?.text, payload.id?.text].compactMap { value -> String? in
            guard let value else { return nil }
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.count <= 128, !cleaned.contains("*"),
                  !cleaned.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
            return cleaned
        }
        // Conflicting identifiers must not silently establish ownership of an account.
        guard Set(ids).count <= 1 else { throw PlatformError.invalidResponse }
        let identity = ids.first.map { "user:" + $0 } ?? contacts.sorted().first
        return AccountProfile(displayName: displayName, identity: identity, identityAliases: contacts)
    }

    static func decodeAmount(_ data: Data) throws -> [Int64: Int64] {
        let payload: PlatformAmountPayload = try decodeBusiness(data)
        let tokenTypes = ["PROMPT_CACHE_HIT_TOKEN", "PROMPT_CACHE_MISS_TOKEN", "RESPONSE_TOKEN"]
        var amounts: [Int64: Int64] = [:]
        for series in payload.series {
            for bucket in series.buckets {
                if bucket.usage.keys.contains(where: { $0.contains("TOKEN") && !tokenTypes.contains($0) }) {
                    throw PlatformError.invalidResponse
                }
                for type in tokenTypes {
                    guard let raw = bucket.usage[type] else { continue }
                    guard let value = Int64(raw.text), value >= 0 else { throw PlatformError.invalidResponse }
                    let (sum, overflow) = amounts[bucket.time, default: 0].addingReportingOverflow(value)
                    guard !overflow else { throw PlatformError.invalidResponse }
                    amounts[bucket.time] = sum
                }
            }
        }
        return amounts
    }

    static func decodeAnalysis(_ data: Data, cost: [Int64: Decimal], currency: String, now: Date = .now) throws -> UsageAnalysisSnapshot {
        let payload: PlatformAmountPayload = try decodeBusiness(data)
        var totals: [String: [Int64]] = [:], costs: [String: Decimal] = [:]
        let timezone = TimeZone.current.identifier
        let types = ["PROMPT_CACHE_HIT_TOKEN", "PROMPT_CACHE_MISS_TOKEN", "RESPONSE_TOKEN"]
        for series in payload.series {
            for bucket in series.buckets {
                guard !bucket.usage.keys.contains(where: { $0.contains("TOKEN") && !types.contains($0) }),
                      bucket.time > 0 else { throw PlatformError.invalidResponse }
                let day = UsageAnalysisMath.day(Date(timeIntervalSince1970: Double(bucket.time)), timezone: timezone)
                var total = totals[day] ?? [0,0,0]
                for (index,type) in types.enumerated() {
                    guard let raw = bucket.usage[type] else { continue }
                    guard let number = Int64(raw.text), let sum = UsageAnalysisMath.sum([total[index],number]) else { throw PlatformError.invalidResponse }; total[index] = sum
                }
                // A bucket without any token field does not establish zero usage.
                if types.contains(where: { bucket.usage[$0] != nil }) { totals[day] = total }
            }
        }
        for (stamp,value) in cost {
            guard !value.isNaN, value >= 0 else { throw PlatformError.invalidResponse }
            let day = UsageAnalysisMath.day(Date(timeIntervalSince1970: Double(stamp)), timezone: timezone)
            costs[day, default: .zero] += value
        }
        let today = UsageAnalysisMath.day(now, timezone:timezone)
        let buckets = try totals.keys.sorted().map { day -> DailyUsageBucket in
            let categories = totals[day]!
            guard let total = UsageAnalysisMath.sum(categories), day <= today else { throw PlatformError.invalidResponse }
            return .init(day:day,tokens:total,cachedInput:categories[0],uncachedInput:categories[1],output:categories[2],cost:costs[day],isPartial:day == today)
        }
        guard UsageAnalysisMath.validate(buckets) else { throw PlatformError.invalidResponse }
        return .init(source:.deepSeek,buckets:buckets,updatedAt:now,currency:currency,timezone:timezone)
    }

    static func decodeCost(_ data: Data, currency: String) throws -> [Int64: Decimal] {
        let payload: PlatformCostPayload = try decodeBusiness(data)
        guard payload.data.isEmpty || payload.data.contains(where: { $0.currency == currency }) else {
            throw PlatformError.invalidResponse
        }
        var costs: [Int64: Decimal] = [:]
        for group in payload.data where group.currency == currency {
            for series in group.series {
                for bucket in series.buckets {
                    guard let amount = Decimal(string: bucket.cost.text,
                                               locale: Locale(identifier: "en_US_POSIX")) else {
                        throw PlatformError.invalidResponse
                    }
                    costs[bucket.time, default: .zero] += amount
                }
            }
        }
        return costs
    }

    func fetchSummary(token: String) async throws -> AccountSummary {
        let data = try await request(path: "/api/v0/users/get_user_summary", method: "GET", token: token)
        return try Self.decodeSummary(data)
    }

    func fetchProfile(token: String) async throws -> AccountProfile {
        let data = try await request(path: "/auth-api/v0/users/current", method: "GET", token: token)
        return try Self.decodeProfile(data)
    }

    func logout(token: String) async {
        _ = try? await request(path: "/auth-api/v0/users/logout", method: "POST", token: token)
    }

    func fetchUsage(token: String, currency: String, ranges: UsageRanges) async throws -> OfficialUsageSummary {
        guard let amountURL = ranges.queryRange.url(kind: "amount", timezoneOffset: ranges.timezoneOffset),
              let costURL = ranges.queryRange.url(kind: "cost", timezoneOffset: ranges.timezoneOffset) else {
            throw PlatformError.invalidResponse
        }
        async let amountData = request(url: amountURL, method: "GET", token: token, maxResponseBytes: 2_000_000)
        async let costData = request(url: costURL, method: "GET", token: token, maxResponseBytes: 2_000_000)
        let amounts = try await amountData
        let costs = try Self.decodeCost(await costData, currency: currency)
        var summary = try OfficialUsageSummary(amount: Self.decodeAmount(amounts), cost: costs, ranges: ranges)
        summary.analysis = try Self.decodeAnalysis(amounts, cost: costs, currency: currency)
        return summary
    }

    func initializeAuth(body: [String: String]) async throws -> AuthInitialization {
        let data = try await request(path: "/auth-api/v0/dsh/auth_init", method: "POST", body: body)
        return try Self.decodeBusiness(data)
    }

    func exchangeAuth(body: [String: String]) async throws -> AuthExchange {
        let data = try await request(path: "/auth-api/v0/dsh/auth_exchange", method: "POST", body: body)
        return try Self.decodeBusiness(data)
    }

    private static func decodeBusiness<Value: Decodable>(_ data: Data) throws -> Value {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let business = object["data"] as? [String: Any]
            if (object["code"] as? Int) == 40003 || (business?["biz_code"] as? Int) == 40003 {
                throw PlatformError.expired
            }
        }
        let envelope: PlatformEnvelope<Value>
        do { envelope = try JSONDecoder().decode(PlatformEnvelope<Value>.self, from: data) }
        catch { throw PlatformError.invalidResponse }
        guard envelope.code == 0, envelope.data.bizCode == 0 else { throw PlatformError.invalidResponse }
        return envelope.data.bizData
    }

    private func request(
        path: String,
        method: String,
        token: String? = nil,
        body: [String: String]? = nil
    ) async throws -> Data {
        try await request(url: Self.origin.appending(path: path), method: method, token: token, body: body)
    }

    private func request(
        url: URL,
        method: String,
        token: String? = nil,
        body: [String: String]? = nil,
        maxResponseBytes: Int = 65_536
    ) async throws -> Data {
        guard url.scheme == "https", url.host == Self.origin.host, url.port == nil else {
            throw PlatformError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("", forHTTPHeaderField: "x-client-bundle-id")
        request.setValue("desktop-mac", forHTTPHeaderField: "x-client-platform")
        request.setValue("1.0.0", forHTTPHeaderField: "x-client-version")
        request.setValue("zh_CN", forHTTPHeaderField: "x-client-locale")
        request.setValue(String(TimeZone.current.secondsFromGMT()), forHTTPHeaderField: "x-client-timezone-offset")
        if let token { request.setValue(token, forHTTPHeaderField: "x-dsh-auth-token") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PlatformError.invalidResponse }
        if response.statusCode == 429 { throw UsageRefreshFailure.rateLimited(until: RefreshPolicy.retryDate(response.value(forHTTPHeaderField: "Retry-After"))) }
        if response.statusCode == 401 { throw PlatformError.expired }
        guard response.statusCode == 200 else { throw PlatformError.server(response.statusCode) }
        guard data.count <= maxResponseBytes else { throw PlatformError.invalidResponse }
        return data
    }
}
