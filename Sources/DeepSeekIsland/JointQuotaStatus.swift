import Foundation

enum JointQuotaStatus: Equatable {
    case available([String])
    case blocked([String])
    case restricted
    case unknown
}

extension AccountRuntime {
    func jointQuotaStatus(for platform: UsagePlatform) -> JointQuotaStatus {
        guard platformAccounts.enabled.contains(platform), freshness(for: platform).allowsAlerts else { return .unknown }
        let windows: [(String, Double?)]
        switch platform {
        case .deepSeek: return .unknown
        case .zhipu:
            guard let quota = zhipuQuota else { return .unknown }
            windows = [("5 小时", quota.fiveHour.usedPercent)] + (quota.week.map { [("本周", Optional($0.usedPercent))] } ?? [])
        case .chatGPT:
            guard let quota = chatGPTQuota else { return .unknown }
            if quota.hasUnlimitedFiveHour {
                windows = [quota.session, quota.weekly].compactMap { $0 }.map { ($0.label, $0.usedPercent) }
            } else {
                windows = [(quota.session?.label ?? "5 小时", quota.session?.usedPercent),
                           (quota.weekly?.label ?? "本周", quota.weekly?.usedPercent)]
            }
        }
        let blocked = windows.compactMap { name, used -> String? in
            guard let used, used.isFinite, used >= 100 else { return nil }
            return name
        }
        if !blocked.isEmpty { return .blocked(blocked) }
        if platform == .chatGPT, chatGPTQuota?.limitReached == true { return .restricted }
        guard windows.allSatisfy({ $0.1.map { $0.isFinite && $0 >= 0 } ?? false }) else { return .unknown }
        return .available(windows.map(\.0))
    }

    func quotaRecoveryContext(for metric: UsageMetric) -> String {
        switch jointQuotaStatus(for: metric.platform) {
        case .blocked(let windows): "该窗口已恢复，仍受" + windows.joined(separator: "、") + "额度限制。"
        case .restricted: "该窗口已恢复，平台仍报告额度限制，请稍后刷新确认。"
        case .available(let windows): windows.joined(separator: "和") + "窗口均有剩余额度。"
        case .unknown: "仅确认该窗口恢复，其他窗口状态未确认。"
        }
    }
    func jointQuotaWarning(for platform: UsagePlatform) -> String? {
        switch jointQuotaStatus(for: platform) {
        case .blocked(let windows): "受" + windows.joined(separator: "、") + "额度限制，等待对应窗口重置。"
        case .restricted: "平台仍报告额度限制，请稍后刷新确认。"
        default: nil
        }
    }
}
