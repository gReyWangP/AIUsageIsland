import Foundation

enum MetricCapability {
    case balance, limited(FiniteQuotaWindow), unlimited, unknown, unsupported
    var canSelect: Bool { if case .unsupported = self { return false }; return true }
    var canConfigureAlerts: Bool {
        switch self { case .balance, .limited, .unknown: true; case .unlimited, .unsupported: false }
    }
    var canReserve: Bool { if case .limited(let value) = self { return value.resetAt != nil }; return false }
    var explanation: String? {
        switch self {
        case .unlimited: "此窗口无限制，无需额度提醒或重置预约。"
        case .unknown: "等待账号数据确认；提醒仅在有效数据更新后生效。"
        case .unsupported: "此账号没有该额度窗口。"
        default: nil
        }
    }
    var suffix: String {
        switch self { case .unlimited: "（无限制）"; case .unknown: "（待确认）"; case .unsupported: "（不适用）"; default: "" }
    }
}

struct PlatformCapabilities {
    let platform: UsagePlatform
    let metrics: [UsageMetric: MetricCapability]
    var availableMetrics: [UsageMetric] { UsageMetric.allCases.filter { $0.platform == platform } }
    func alertMetric(preferred: UsageMetric?) -> UsageMetric {
        if let preferred, preferred.platform == platform, metric(preferred).canConfigureAlerts { return preferred }
        return availableMetrics.first { metric($0).canConfigureAlerts } ?? .defaultMetric(for: platform)
    }
    func metric(_ value: UsageMetric) -> MetricCapability { metrics[value] ?? .unsupported }
}

extension AccountRuntime {
    var capabilities: PlatformCapabilities {
        let entries = UsageMetric.allCases.filter { $0.platform == account.platform }.map { metric -> (UsageMetric, MetricCapability) in
            if metric == .deepSeekBalance { return (metric, .balance) }
            switch quotaWindow(for: metric) {
            case .limited(let value): return (metric, .limited(value))
            case .unlimited: return (metric, .unlimited)
            case .unavailable:
                let loaded = account.platform == .zhipu ? zhipuQuota != nil : chatGPTQuota != nil
                return (metric, loaded ? .unsupported : .unknown)
            }
        }
        return PlatformCapabilities(platform: account.platform, metrics: Dictionary(uniqueKeysWithValues: entries))
    }
}
