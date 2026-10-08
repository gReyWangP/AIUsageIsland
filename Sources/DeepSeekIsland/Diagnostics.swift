import Foundation

@MainActor
enum DiagnosticReport {
    static func render(model: IslandModel, at now: Date = .now) -> String {
        let version = ApplicationVersion.version ?? "development"
        let build = ApplicationVersion.build ?? "development"
        var rows = ["AIUsageIsland \(version) (\(build))", "生成时间：\(now.ISO8601Format())",
                    "macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)", "联网：\(model.networkAvailable)"]
        for (index, account) in model.orderedSavedAccounts.enumerated() {
            let source = model.accountRuntime(for: account), freshness = source.freshness(for: account.platform)
            rows.append("账号 \(index + 1) · \(account.platform.rawValue) · connected=\(source.hasConnectedAccount(for: account.platform)) · state=\(freshness.phase)")
            rows.append("最近成功：" + (freshness.lastSuccess?.ISO8601Format() ?? "none"))
            rows.append("额度错误类别：" + code(source.primaryRefreshFailure))
            let analysis = source.analysis.freshness(connected: source.hasConnectedAccount(for: account.platform), networkAvailable: source.networkAvailable, at: now)
            rows.append("日统计状态：\(analysis.phase)")
            rows.append("日统计最近成功：" + (analysis.lastSuccess?.ISO8601Format() ?? "none"))
            rows.append("日统计错误类别：" + code(source.analysis.refreshFailure))
            for metric in source.capabilities.availableMetrics {
                let state: String
                switch source.capabilities.metric(metric) {
                case .limited: state = "finite"
                case .balance: state = "balance"
                case .unlimited: state = "unlimited"
                case .unknown: state = "unknown"
                case .unsupported: state = "unsupported"
                }
                rows.append(metric.rawValue + "=" + state)
            }
            if account.platform == .deepSeek { rows.append("辅助用量错误：" + code(source.deepSeekUsageFailure)) }
            if let next = source.refreshPolicy.nextAttempt { rows.append("下次尝试：" + next.ISO8601Format()) }
        }
        return rows.joined(separator: "\n")
    }
    private static func code(_ failure: UsageRefreshFailure?) -> String {
        guard let failure else { return "none" }
        switch failure {
        case .cancelled: return "cancelled"
        case .authorization: return "authorization"
        case .transport(let code): return "network:\(code)"
        case .http(let code): return "http:\(code)"
        case .rateLimited: return "rate_limited"
        case .invalidResponse: return "invalid_response"
        case .noQuota: return "no_quota"
        case .credentialPersistence: return "credential_persistence"
        case .unknown: return "unknown"
        }
    }
}
