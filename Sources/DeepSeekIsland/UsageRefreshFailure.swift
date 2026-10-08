import Foundation

/// Safe domain failures: never retain a response body, credential, URL, or arbitrary error text.
enum UsageRefreshFailure: Error, Equatable, Sendable {
    case cancelled
    case authorization
    case transport(Int)
    case http(Int)
    case rateLimited(until: Date?)
    case invalidResponse
    case noQuota
    case credentialPersistence
    case unknown

    static func sharedFailure(for error: Error) -> Self? {
        if let failure = error as? Self { return failure }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            return error.code == .cancelled ? .cancelled : .transport(error.code.rawValue)
        }
        return nil
    }

    @MainActor static func dailyStatisticsFailure(for error: Error) -> Self {
        if let known = sharedFailure(for: error) { return known }
        if let error = error as? UsageAnalysisError {
            switch error { case .invalidResponse: return .invalidResponse; case .unavailable: return .unknown }
        }
        if error is ZhipuQuotaError { return ZhipuUsageAdapter.failure(for: error) }
        return ChatGPTUsageAdapter.failure(for: error)
    }

    func message(for platform: UsagePlatform) -> String {
        switch self {
        case .cancelled: "刷新已取消"
        case .authorization: "\(platform.title) 授权已失效，请重新登录"
        case .transport(let code):
            switch URLError.Code(rawValue: code) {
            case .timedOut: "网络请求超时，请稍后刷新"
            case .notConnectedToInternet: "网络未连接，请联网后刷新"
            default: "网络请求失败，请检查连接后刷新"
            }
        case .rateLimited(let until): "平台暂时限流，请" + (until.map { "在 " + $0.formatted(date: .omitted, time: .shortened) + " 后" } ?? "稍后") + "再刷新"
        case .http(let status): "\(platform.title) 接口请求失败（HTTP \(status)）"
        case .invalidResponse: "\(platform.title) 接口返回了无法识别的数据"
        case .noQuota: "\(platform.title) 账号没有可用额度"
        case .credentialPersistence: "无法将更新后的授权保存到本机，请检查应用数据目录后重新登录"
        case .unknown: "\(platform.title) 额度更新失败，请稍后刷新"
        }
    }
}
