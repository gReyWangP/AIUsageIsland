import Foundation

/// OpenCode Go subscription windows. The API reports **used** percentages for
/// rolling 5-hour, weekly and monthly allowances; the app converts them to
/// remaining values through `FiniteQuotaWindow`.
struct OpenCodeGoQuota: Sendable, Equatable {
    struct Window: Sendable, Equatable {
        let usedPercent: Double
        let resetAt: Date?
        let status: String?

        var remainingPercent: Double { max(0, 100 - usedPercent) }
    }

    let rolling: Window?
    let weekly: Window?
    let monthly: Window?
}

enum OpenCodeGoQuotaError: LocalizedError, Equatable {
    case authorization
    case noQuota
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .authorization: "OpenCode Go API Key 无效或已失效，请重新填写"
        case .noQuota: "这个 OpenCode Go 账号没有返回额度窗口"
        case .invalidResponse: "OpenCode Go 用量接口没有返回可识别的数据"
        }
    }
}

enum OpenCodeGoQuotaParser {
    static func parse(_ data: Data) throws -> OpenCodeGoQuota {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenCodeGoQuotaError.invalidResponse
        }
        if root["error"] != nil || (root["type"] as? String)?.lowercased().contains("error") == true {
            throw OpenCodeGoQuotaError.authorization
        }
        let usage = (root["usage"] as? [String: Any]) ?? root
        let rolling = window(usage["rolling"])
        let weekly = window(usage["weekly"])
        let monthly = window(usage["monthly"])
        guard rolling != nil || weekly != nil || monthly != nil else {
            throw OpenCodeGoQuotaError.noQuota
        }
        return OpenCodeGoQuota(rolling: rolling, weekly: weekly, monthly: monthly)
    }

    private static func window(_ value: Any?) -> OpenCodeGoQuota.Window? {
        guard let object = value as? [String: Any] else { return nil }
        let status = (object["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var used: Double?
        if let percent = number(object["percent"]) ?? number(object["usedPercent"]) ?? number(object["used_percentage"]) {
            used = percent
        } else if let usedValue = number(object["used"]), let limit = number(object["limit"]), limit > 0 {
            used = usedValue / limit * 100
        }
        if status == "rate-limited" || status == "rate_limited" { used = 100 }
        guard var used, used.isFinite, used >= 0 else { return nil }
        used = min(100, used)
        return OpenCodeGoQuota.Window(
            usedPercent: used,
            resetAt: date(object["resetsAt"] ?? object["resetAt"] ?? object["resets_at"]),
            status: status
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            guard seconds.isFinite else { return nil }
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let text = value as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
