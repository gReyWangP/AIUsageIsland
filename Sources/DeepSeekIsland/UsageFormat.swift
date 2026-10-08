import Foundation

/// 详情页与缩略条共用的格式化逻辑。
/// 收敛到一处，避免两列各自实现导致字号、位数、前缀不一致。
enum UsageFormat {
    private static let moneyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let exactFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func money(_ amount: Decimal) -> String {
        moneyFormatter.string(from: amount as NSDecimalNumber) ?? "—"
    }

    static func currencySymbol(_ currency: String) -> String {
        currency == "CNY" ? "¥" : ""
    }

    /// 带货币符号的金额；估算值前置「≈」以区别于平台账单。
    static func cost(_ amount: Decimal, currency: String, estimated: Bool) -> String {
        (estimated ? "≈" : "") + currencySymbol(currency) + money(amount)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value)
    }

    static func remainingPercent(_ used: Double?) -> String {
        guard let used, used.isFinite else { return "—" }
        let remaining = max(0, min(100, 100 - used))
        if remaining > 0 && remaining < 1 { return "<1%" }
        return percent(floor(remaining))
    }

    static func exactTokens(_ count: Int64) -> String {
        exactFormatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    static func resetTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        // 额度窗口最长一周，重置时间必定在近期，因此省略年份以节省横向空间。
        return date.formatted(.dateTime.month().day().hour().minute())
    }

    static func refreshTime(_ date: Date?) -> String {
        guard let date else { return "" }
        return "刷新：" + date.formatted(date: .omitted, time: .shortened)
    }
}
