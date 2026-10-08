import Foundation

/// A business reading; money, finite allowance, unlimited and unavailable stay distinct.
enum UsageReading: Equatable {
    case balance(amount: Decimal, currency: String)
    case quota(remaining: Double, window: String = "5 小时")
    case unlimited(window: String)
    case unavailable(String)

    var description: String {
        switch self {
        case .balance(let amount, let currency):
            "剩余余额：\(NSDecimalNumber(decimal: amount).stringValue) \(currency)"
        case .quota(let remaining, let window): "\(window)剩余额度：\(String(format: "%.1f", remaining))%"
        case .unlimited(let window): "\(window)额度：无限制"
        case .unavailable(let reason): reason
        }
    }
}
