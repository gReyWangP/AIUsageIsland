import Foundation

struct ZhipuQuota {
    enum Kind: Equatable { case credits, tokens }

    struct Window {
        let usedPercent: Double
        let usedValue: Decimal?
        let limitValue: Decimal?
        let nextReset: Date?
    }

    let kind: Kind
    let level: String?
    let fiveHour: Window
    let week: Window?
    var accountIdentity: String? = nil
}

enum ZhipuQuotaError: LocalizedError {
    case authorization
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .authorization: "智谱网页登录已失效，请重新登录"
        case .invalidResponse: "智谱用量页面没有返回可识别的额度数据"
        }
    }
}

enum ZhipuQuotaParser {
    static func parse(_ data: Data) throws -> ZhipuQuota {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZhipuQuotaError.invalidResponse
        }
        if root["success"] as? Bool == false {
            throw ZhipuQuotaError.authorization
        }
        if let code = number(root["code"]), code != 0 && code != 200 {
            throw ZhipuQuotaError.authorization
        }
        guard let payload = root["data"] as? [String: Any],
              let limits = payload["limits"] as? [[String: Any]] else {
            throw ZhipuQuotaError.invalidResponse
        }
        let kind: ZhipuQuota.Kind = limits.contains { ($0["type"] as? String) == "CREDIT_LIMIT" }
            ? .credits : .tokens
        let type = kind == .credits ? "CREDIT_LIMIT" : "TOKENS_LIMIT"
        guard let five = window(in: limits, type: type, unit: 3) else {
            throw ZhipuQuotaError.invalidResponse
        }
        let week = window(in: limits, type: type, unit: 6)
        if limits.contains(where: { ($0["type"] as? String) == type && number($0["unit"]) == 6 }), week == nil {
            throw ZhipuQuotaError.invalidResponse
        }
        let identity = (payload["accountIdentity"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ZhipuQuota(kind: kind, level: payload["level"] as? String,
                          fiveHour: five, week: week, accountIdentity: identity.flatMap { !$0.isEmpty && $0.count <= 128 ? $0 : nil })
    }

    private static func window(in limits: [[String: Any]], type: String, unit: Int) -> ZhipuQuota.Window? {
        guard let limit = limits.first(where: {
            ($0["type"] as? String) == type && number($0["unit"]) == Double(unit)
        }), let used = number(limit["percentage"]), used.isFinite, used >= 0 else { return nil }
        let resetMilliseconds = number(limit["nextResetTime"])
        let reset = resetMilliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }
        return ZhipuQuota.Window(usedPercent: used,
                                 usedValue: decimal(limit["currentValue"]),
                                 limitValue: decimal(limit["usage"]),
                                 nextReset: reset)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        if let value = value as? NSNumber {
            return Decimal(string: value.stringValue, locale: Locale(identifier: "en_US_POSIX"))
        }
        if let value = value as? String {
            return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
        }
        return nil
    }
}
