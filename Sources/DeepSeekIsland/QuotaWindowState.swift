import Foundation

/// Validated finite allowance. Invalid timing removes scheduling, not otherwise useful usage.
struct FiniteQuotaWindow: Equatable {
    let usedPercent: Double
    let resetAt: Date?
    var remainingPercent: Double { max(0, 100 - usedPercent) }

    init?(usedPercent: Double, resetAt: Date?) {
        guard usedPercent.isFinite, usedPercent >= 0 else { return nil }
        self.usedPercent = usedPercent
        self.resetAt = resetAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
    }
}

enum QuotaWindowState: Equatable {
    case limited(FiniteQuotaWindow)
    case unlimited
    case unavailable

    static func finite(usedPercent: Double, resetAt: Date?) -> Self {
        FiniteQuotaWindow(usedPercent: usedPercent, resetAt: resetAt).map(Self.limited) ?? .unavailable
    }
    var finiteValue: FiniteQuotaWindow? {
        guard case .limited(let window) = self else { return nil }
        return window
    }
    var resetAt: Date? {
        guard case .limited(let window) = self else { return nil }
        return window.resetAt
    }
}

extension AccountRuntime {
    /// Raw cached window semantics; consumers separately apply freshness/connection policy.
    /// No fixed primary/secondary-slot assumptions: match the actual duration.
    func quotaWindow(for metric: UsageMetric) -> QuotaWindowState {
        guard metric.platform == account.platform, metric.windowSeconds != nil else { return .unavailable }
        switch metric {
        case .deepSeekBalance: return .unavailable
        case .zhipuFiveHour, .zhipuWeek:
            guard let quota = zhipuQuota else { return .unavailable }
            if metric == .zhipuWeek, quota.week == nil { return .unlimited }
            guard let window = metric == .zhipuFiveHour ? quota.fiveHour : quota.week else { return .unavailable }
            return .finite(usedPercent: window.usedPercent, resetAt: window.nextReset)
        case .chatGPTFiveHour, .chatGPTWeek:
            guard let quota = chatGPTQuota else { return .unavailable }
            if let window = [quota.session, quota.weekly].compactMap({ $0 }).first(where: { $0.windowSeconds == metric.windowSeconds }) {
                return .finite(usedPercent: window.usedPercent, resetAt: window.resetAt)
            }
            if metric == .chatGPTFiveHour, quota.hasUnlimitedFiveHour { return .unlimited }
            return .unavailable
        }
    }

    /// Shared by notifications and presentation; unavailable data never becomes a numeric zero.
    func usageReading(for metric: UsageMetric) -> UsageReading {
        let platform = metric.platform
        guard platformAccounts.enabled.contains(platform) else { return .unavailable("平台未添加") }
        guard networkAvailable else { return .unavailable("离线，详情中可查看缓存数据") }
        if freshness(for: platform).phase == .stale { return .unavailable("数据较旧，请刷新") }
        guard hasConnectedAccount(for: platform) else { return .unavailable("未登录") }
        if metric == .deepSeekBalance {
            guard errorMessage == nil, let balance, !balance.isNaN else { return .unavailable("余额暂不可用") }
            return .balance(amount: balance, currency: currency)
        }
        switch platform {
        case .deepSeek: return .unavailable("余额没有额度窗口")
        case .zhipu:
            guard zhipuError == nil, zhipuUsageError == nil, zhipuQuota != nil else { return .unavailable("额度暂不可用") }
        case .chatGPT:
            guard chatGPTError == nil, chatGPTUsageError == nil, chatGPTQuota != nil else { return .unavailable("额度暂不可用") }
        }
        switch quotaWindow(for: metric) {
        case .limited(let window): return .quota(remaining: window.remainingPercent, window: metric.windowLabel)
        case .unlimited: return .unlimited(window: metric.windowLabel)
        case .unavailable: return .unavailable("当前账号没有可用的\(metric.windowLabel)额度窗口")
        }
    }
}

extension AccountRuntime {
    func hasLoadedAccountData(for platform: UsagePlatform) -> Bool {
        switch platform {
        case .deepSeek: lastUpdated != nil || balance != nil
        case .zhipu: zhipuLastUpdated != nil || zhipuQuota != nil
        case .chatGPT: chatGPTLastUpdated != nil || chatGPTQuota != nil
        }
    }
    func hasConnectedAccount(for platform: UsagePlatform) -> Bool {
        switch platform {
        case .deepSeek: accountConnected
        case .zhipu: zhipuConnected
        case .chatGPT: chatGPTConnected
        }
    }
}
