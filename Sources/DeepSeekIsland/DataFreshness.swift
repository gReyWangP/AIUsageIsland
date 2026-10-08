import Foundation

struct DataFreshness {
    enum Phase { case empty, disconnected, loading, fresh, partial, failed, offline, stale }
    let phase: Phase
    let lastSuccess: Date?
    var reason: String? = nil
    var failure: UsageRefreshFailure? = nil
    var isWarning: Bool { [.partial, .failed, .offline, .stale].contains(phase) }
    var isCached: Bool { [.partial, .failed, .offline, .stale].contains(phase) && lastSuccess != nil }
    var allowsAlerts: Bool { phase == .fresh || phase == .partial }
    var label: String {
        let time = lastSuccess.map { $0.formatted(date: .omitted, time: .shortened) }
        let cached = time.map { " · 缓存 \($0)" } ?? " · 暂无数据"
        switch phase {
        case .empty: return "等待首次更新"
        case .disconnected: return "未登录"
        case .loading: return "更新中" + (time.map { " · 上次 \($0)" } ?? "")
        case .fresh: return time.map { "已更新：\($0)" } ?? "已更新"
        case .partial: return "余额已更新 · 用量更新失败"
        case .failed: return "更新失败" + cached
        case .offline: return "离线" + cached
        case .stale: return "数据较旧" + cached
        }
    }
    var detail: String {
        label + (reason.map { "\n\($0)" } ?? "") + (isCached ? "\n显示上次成功获取的数据，请在网络恢复后刷新。" : "")
    }
}

/// One policy for all platform readings. Legacy messages remain a compatibility input;
/// a typed failure takes precedence and cancellation never becomes a failed reading.
extension DataFreshness {
    static func resolve(connected: Bool, loading: Bool, lastSuccess: Date?,
                        networkAvailable: Bool, failure: UsageRefreshFailure?,
                        legacyReason: String?, platform: UsagePlatform,
                        at now: Date) -> DataFreshness {
        let effectiveFailure = failure == .cancelled ? nil : failure
        let reason = failure == .cancelled ? nil
            : effectiveFailure?.message(for: platform) ?? legacyReason
        func state(_ phase: Phase, updated: Date?) -> DataFreshness {
            DataFreshness(phase: phase, lastSuccess: updated,
                          reason: reason, failure: effectiveFailure)
        }
        guard connected else { return state(.disconnected, updated: nil) }
        if !networkAvailable { return state(.offline, updated: lastSuccess) }
        if loading { return state(.loading, updated: lastSuccess) }
        if effectiveFailure != nil || reason != nil { return state(.failed, updated: lastSuccess) }
        guard let lastSuccess else { return state(.empty, updated: nil) }
        return state(now.timeIntervalSince(lastSuccess) > 600 ? .stale : .fresh, updated: lastSuccess)
    }
}

extension AccountRuntime {
    func freshness(for platform: UsagePlatform, at now: Date = .now) -> DataFreshness {
        let connected: Bool
        let loading: Bool
        let updated: Date?
        let error: String?
        let failure: UsageRefreshFailure?
        switch platform {
        case .deepSeek:
            (connected, loading, updated, error, failure) =
                (accountConnected, isLoading, lastUpdated, errorMessage, deepSeekRefreshFailure)
        case .zhipu:
            (connected, loading, updated, error, failure) =
                (zhipuConnected, zhipuLoading, zhipuLastUpdated, zhipuError ?? zhipuUsageError, zhipuRefreshFailure)
        case .chatGPT:
            (connected, loading, updated, error, failure) =
                (chatGPTConnected, chatGPTLoading, chatGPTLastUpdated, chatGPTError ?? chatGPTUsageError, chatGPTRefreshFailure)
        }
        let state = DataFreshness.resolve(connected: connected, loading: loading, lastSuccess: updated,
            networkAvailable: networkAvailable, failure: failure, legacyReason: error, platform: platform, at: now)
        if platform == .deepSeek, state.phase == .fresh {
            let usageState = deepSeekUsageFreshness(at: now)
            if usageState.phase == .failed {
                return DataFreshness(phase: .partial, lastSuccess: updated,
                    reason: usageError ?? usageState.reason, failure: usageState.failure)
            }
        }
        return state
    }

    /// Usage has its own success clock: a fresh balance must not make old billing data fresh.
    /// This is deliberately separate from balance freshness used by balance alerts.
    func deepSeekUsageFreshness(at now: Date = .now) -> DataFreshness {
        DataFreshness.resolve(connected: accountConnected, loading: isLoading,
            lastSuccess: usageLastUpdated, networkAvailable: networkAvailable,
            failure: deepSeekUsageFailure, legacyReason: usageError, platform: .deepSeek, at: now)
    }

    func recoveryPlatforms(at now: Date = .now) -> [UsagePlatform] {
        automaticRefreshPlatforms().filter { platform in
            let state = freshness(for: platform, at: now)
            return canAutomaticallyRefresh(platform, at: now)
                && (state.isWarning || state.lastSuccess.map { now.timeIntervalSince($0) >= 60 } ?? true)
        }
    }

    func recoverDataIfNeeded() async {
        for platform in recoveryPlatforms() { await refresh(platform) }
    }
}
