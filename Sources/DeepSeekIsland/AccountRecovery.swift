import Foundation

enum AccountAuthorizationIssue: LocalizedError, Equatable {
    case duplicate(label: String)
    case differentAccount
    case unverifiedIdentity

    var errorDescription: String? {
        switch self {
        case .duplicate(let label): "这个账号已保存为“\(label)”，请在授权页切换账号后重试。原授权已保留。"
        case .differentAccount: "授权账号与此条目原来的账号不同，请使用“添加账号”保存新账号。原授权已保留。"
        case .unverifiedIdentity: "无法确认此次登录的账号身份，暂未保存。请先重新验证原账号后重试；已有授权已保留。"
        }
    }
}

struct AccountRecoveryPresentation {
    enum Action: Equatable { case signIn, retry, officialPage, wait }
    let label: String
    let explanation: String?
    let action: Action
    let canPerformAction: Bool

    static func make(connected: Bool, signingIn: Bool, loaded: Bool, networkAvailable: Bool,
                     loading: Bool, issue: AccountAuthorizationIssue?, failure: UsageRefreshFailure?,
                     cooldownUntil: Date?, platform: UsagePlatform, at now: Date = .now) -> Self {
        func result(_ label: String, _ action: Action, _ explanation: String? = nil) -> Self {
            .init(label: label, explanation: explanation, action: action,
                  canPerformAction: action != .wait && networkAvailable && !loading && !signingIn)
        }
        if signingIn { return result("正在登录…", .wait) }
        if let cooldownUntil, cooldownUntil > now {
            return result("限流冷却中", .wait, "可在 " + cooldownUntil.formatted(date: .omitted, time: .shortened) + " 后重试。")
        }
        if let issue {
            return result(issue.isDuplicate ? "重复账号 · 未添加" : "账号身份待确认", .signIn, issue.localizedDescription)
        }
        if connected && !networkAvailable { return result(loaded ? "离线 · 缓存" : "离线 · 等待更新", .retry, "联网后重试，无需重新登录。") }
        switch failure {
        case .authorization: return result("授权已失效", .signIn, failure?.message(for: platform))
        case .credentialPersistence: return result("授权保存失败", .signIn, "请检查本机授权存储后重新登录，避免反复使用已轮换的授权。")
        case .transport: return result("网络更新失败", .retry, failure?.message(for: platform))
        case .invalidResponse: return result("接口格式变化", .officialPage, "已有数据仍保留。可先查看官方页面，稍后重试或更新应用。")
        case .noQuota: return result("暂无适用额度", .officialPage, "此账号未返回适用额度，不能据此认定余额或用量为零。")
        case .rateLimited(let until):
            if let until, until > now { return result("限流冷却中", .wait, failure?.message(for: platform)) }
            return result("限流后待刷新", .retry)
        case .http(429): return result("限流后待刷新", .retry)
        case .http, .unknown: return result("平台更新失败", .retry, failure?.message(for: platform))
        case .cancelled, nil: break
        }
        if !connected { return result("未完成登录", .signIn) }
        if loading { return result("正在更新…", .wait) }
        return result(loaded ? "已连接" : "等待首次更新", .retry)
    }
}

private extension AccountAuthorizationIssue {
    var isDuplicate: Bool { if case .duplicate = self { return true }; return false }
}

extension AccountRuntime {
    var primaryRefreshFailure: UsageRefreshFailure? {
        switch account.platform {
        case .deepSeek: deepSeekRefreshFailure
        case .zhipu: zhipuRefreshFailure
        case .chatGPT: chatGPTRefreshFailure
        }
    }
    func recoveryPresentation(at now: Date = .now) -> AccountRecoveryPresentation {
        let signingIn: Bool
        switch account.platform {
        case .deepSeek: signingIn = isSigningIn
        case .zhipu: signingIn = zhipuSigningIn
        case .chatGPT: signingIn = chatGPTSigningIn
        }
        return .make(connected: hasConnectedAccount(for: account.platform), signingIn: signingIn,
                     loaded: hasLoadedAccountData(for: account.platform), networkAvailable: networkAvailable,
                     loading: isRefreshing, issue: authorizationIssue, failure: primaryRefreshFailure,
                     cooldownUntil: refreshPolicy.cooldownUntil, platform: account.platform, at: now)
    }
}
