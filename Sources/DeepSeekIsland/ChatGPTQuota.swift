import Foundation

/// ChatGPT 订阅（Codex）额度：一个短窗口 + 一个长窗口。
///
/// 数据来自 `GET https://chatgpt.com/backend-api/wham/usage`，与 Codex CLI、
/// ChatGPT 网页版「用量」页同源。Plus 的两个窗口是 5 小时（18000 s）与一周（604800 s）。
struct ChatGPTQuota: Sendable {
    struct Window: Sendable {
        /// 窗口长度（秒）。
        let windowSeconds: Int
        let usedPercent: Double
        let resetAt: Date?

        /// 窗口名。
        ///
        /// **不能按 primary/secondary 槽位写死**：Team 账号返回的是周 + 月窗口，
        /// 所以名字由窗口长度推出来，而不是「第一个就是 5 小时」。
        var label: String {
            switch windowSeconds {
            case 18_000: "5 小时"
            case 86_400: "今日"
            case 604_800: "本周"
            case 2_592_000, 2_678_400: "本月"
            default:
                if windowSeconds > 0, windowSeconds % 86_400 == 0 { "\(windowSeconds / 86_400) 天" }
                else { "\(max(1, windowSeconds / 3_600)) 小时" }
            }
        }
    }

    /// 接口返回的套餐标识，如 `plus`、`pro`。
    let planType: String?
    /// 短窗口（Plus 是 5 小时）。
    let session: Window?
    /// 长窗口（Plus 是一周）。
    let weekly: Window?
    let email: String?
    let accountID: String?
    /// 额度是否已经用尽（接口的 `limit_reached`）。
    let limitReached: Bool

    static func isProPlan(_ plan: String?) -> Bool {
        ["pro", "prolite", "promax", "pro_100", "pro_200", "pro_500"].contains((plan ?? "").lowercased())
    }
    /// Only infer the absent five-hour limit from a successfully returned weekly allowance.
    var hasUnlimitedFiveHour: Bool {
        Self.isProPlan(planType) && weekly?.windowSeconds == 604_800 &&
        ![session, weekly].compactMap({ $0 }).contains { $0.windowSeconds == 18_000 }
    }

    /// 账号区显示名，如「ChatGPT Plus」。
    var planName: String {
        let raw = (planType ?? "").lowercased()
        let suffix: String
        switch raw {
        case "": suffix = ""
        case "plus": suffix = "Plus"
        case "pro", "prolite", "promax", "pro_100", "pro_200", "pro_500": suffix = "Pro"
        case "go": suffix = "Go"
        case "free", "guest": suffix = "Free"
        case "team": suffix = "Team"
        case "business": suffix = "Business"
        case "enterprise": suffix = "Enterprise"
        case "edu", "education", "edu_plus", "edu_pro": suffix = "Edu"
        default: suffix = raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return suffix.isEmpty ? "ChatGPT" : "ChatGPT \(suffix)"
    }
}

enum ChatGPTQuotaError: LocalizedError {
    case authorization
    case noQuota
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .authorization: "ChatGPT 授权已失效，请重新登录"
        case .noQuota: "这个账号没有 Codex 额度（需要 Plus 及以上订阅）"
        case .invalidResponse: "ChatGPT 用量接口没有返回可识别的额度窗口"
        }
    }
}

enum ChatGPTQuotaParser {
    static func parse(_ data: Data) throws -> ChatGPTQuota {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTQuotaError.invalidResponse
        }
        // 未授权时接口返回 {"detail": "Unauthorized"}，HTTP 状态码也可能只是 403。
        if let detail = root["detail"] as? String, !detail.isEmpty {
            throw ChatGPTQuotaError.authorization
        }
        if string(root["error"]) != nil || string(root["message"]) != nil {
            throw ChatGPTQuotaError.authorization
        }
        // 免费账号的 rate_limit 是 null——这是「没有额度」，不是解析失败。
        guard let rateLimit = root["rate_limit"] as? [String: Any] else {
            throw ChatGPTQuotaError.noQuota
        }
        var windows: [ChatGPTQuota.Window] = []
        for key in ["primary_window", "secondary_window"] {
            guard let raw = rateLimit[key], !(raw is NSNull) else { continue }
            guard let object = raw as? [String: Any], let parsed = window(object) else {
                throw ChatGPTQuotaError.invalidResponse
            }
            windows.append(parsed)
        }
        windows.sort { $0.windowSeconds < $1.windowSeconds }
        guard let shortest = windows.first else { throw ChatGPTQuotaError.noQuota }
        let proWithoutFive = ChatGPTQuota.isProPlan(string(root["plan_type"])) &&
            !windows.contains { $0.windowSeconds == 18_000 } && windows.contains { $0.windowSeconds == 604_800 }
        return ChatGPTQuota(
            planType: string(root["plan_type"]),
            session: proWithoutFive ? windows.first(where: { $0.windowSeconds != 604_800 }) : shortest,
            // Pro 仅周窗口时保留在 weekly；其他套餐单窗口沿用实际窗口名称。
            weekly: proWithoutFive ? windows.first(where: { $0.windowSeconds == 604_800 }) : (windows.count > 1 ? windows[windows.count - 1] : nil),
            email: string(root["email"]),
            accountID: string(root["account_id"]),
            limitReached: (rateLimit["limit_reached"] as? Bool) ?? false
        )
    }

    private static func window(_ object: [String: Any]) -> ChatGPTQuota.Window? {
        guard let used = number(object["used_percent"]), used.isFinite, used >= 0,
              let seconds = number(object["limit_window_seconds"]), seconds.isFinite, seconds > 0,
              let windowSeconds = Int(exactly: seconds) else { return nil }
        let reset = number(object["reset_at"]).map { Date(timeIntervalSince1970: $0) }
        return ChatGPTQuota.Window(windowSeconds: windowSeconds,
                                   usedPercent: min(used, 100),
                                   resetAt: reset)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
