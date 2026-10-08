import Foundation

struct AlertThresholds: Codable, Equatable {
    let warning: Double
    let critical: Double
    static func defaults(for metric: UsageMetric) -> Self {
        metric == .deepSeekBalance ? Self(warning: 5, critical: 1) : Self(warning: 20, critical: 10)
    }
    static func make(warning: Double, critical: Double, metric: UsageMetric) throws -> Self {
        guard warning.isFinite, critical.isFinite, critical > 0, warning > critical,
              warning <= (metric == .deepSeekBalance ? 100000 : 100) else {
            throw ResetReminderError(message: "请填写有效阈值：严重阈值大于 0，且小于偏低阈值；百分比最多为 100%。")
        }
        return Self(warning: warning, critical: critical)
    }
    func severity(_ data: UsageReading) -> Int? {
        let value: Double
        switch data {
        case .quota(let remaining, _): value = remaining
        case .balance(let amount, let currency):
            guard currency == "CNY" else { return nil }; value = NSDecimalNumber(decimal: amount).doubleValue
        case .unavailable, .unlimited: return nil
        }
        guard value.isFinite else { return nil }
        return value < critical ? 2 : value < warning ? 1 : 0
    }
}
extension IslandSettings {
    func thresholds(for metric: UsageMetric) -> AlertThresholds {
        guard let value = alertThresholds[metric],
              let valid = try? AlertThresholds.make(warning: value.warning, critical: value.critical, metric: metric) else {
            return .defaults(for: metric)
        }
        return valid
    }
    func alertSeverity(for metric: UsageMetric, data: UsageReading) -> Int? { thresholds(for: metric).severity(data) }
}
