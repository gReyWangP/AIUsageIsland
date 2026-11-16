import Foundation

/// Antigravity groups its five-hour and weekly allowances by model family.
/// The local language server returns the same buckets as the Antigravity UI.
struct AntigravityQuota: Sendable, Equatable {
    enum Window: Sendable {
        case fiveHour
        case week
    }

    struct Bucket: Sendable, Equatable {
        let id: String
        let displayName: String
        let window: Window
        /// Remaining fraction normalized to 0...100.
        let remainingPercent: Double
        let resetAt: Date?

        var usedPercent: Double { max(0, 100 - remainingPercent) }
    }

    struct Group: Sendable, Equatable {
        let name: String
        let description: String?
        let buckets: [Bucket]

        func bucket(_ window: Window) -> Bucket? {
            buckets.first { $0.window == window }
        }
    }

    let groups: [Group]

    var geminiGroup: Group? {
        groups.first { $0.name.localizedCaseInsensitiveContains("gemini") }
    }

    /// Claude/GPT quotas share a separate allowance in Antigravity.
    var thirdPartyGroup: Group? {
        groups.first {
            $0.name.localizedCaseInsensitiveContains("claude") ||
                $0.name.localizedCaseInsensitiveContains("gpt")
        }
    }
}

enum AntigravityQuotaError: LocalizedError, Equatable {
    case notRunning
    case noPort
    case authorization
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notRunning: "未检测到正在运行的 Antigravity，请先打开 Antigravity 后重试"
        case .noPort: "Antigravity 已运行，但没有找到可用的本地额度端口"
        case .authorization: "Antigravity 本地额度服务拒绝了请求，请重启 Antigravity 后重试"
        case .http(let status): "Antigravity 本地额度请求失败（HTTP \(status)）"
        case .invalidResponse: "Antigravity 返回了无法识别的额度数据"
        }
    }
}

enum AntigravityQuotaParser {
    static func parse(_ data: Data) throws -> AntigravityQuota {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityQuotaError.invalidResponse
        }
        if let code = root["code"] as? String, code.lowercased() != "ok", code.lowercased() != "success" {
            throw AntigravityQuotaError.invalidResponse
        }
        let payload = (root["response"] as? [String: Any]) ?? root
        guard let rawGroups = payload["groups"] as? [[String: Any]] else {
            throw AntigravityQuotaError.invalidResponse
        }
        var groups: [AntigravityQuota.Group] = []
        for rawGroup in rawGroups {
            guard let name = string(rawGroup["displayName"]) ?? string(rawGroup["name"]),
                  let rawBuckets = rawGroup["buckets"] as? [[String: Any]] else { continue }
            let buckets = rawBuckets.compactMap(bucket)
            guard !buckets.isEmpty else { continue }
            groups.append(.init(name: name, description: string(rawGroup["description"]), buckets: buckets))
        }
        guard !groups.isEmpty else { throw AntigravityQuotaError.invalidResponse }
        return AntigravityQuota(groups: groups)
    }

    private static func bucket(_ object: [String: Any]) -> AntigravityQuota.Bucket? {
        guard let id = string(object["bucketId"]) ?? string(object["id"]),
              let window = window(object) else { return nil }
        let remainingFraction = number(object["remainingFraction"]) ?? number(object["remaining_fraction"])
        let percentageUsed = number(object["percentageUsed"]) ?? number(object["percentage_used"])
        let remaining: Double
        if let remainingFraction {
            remaining = remainingFraction <= 1 ? remainingFraction * 100 : remainingFraction
        } else if let percentageUsed {
            remaining = 100 - percentageUsed
        } else {
            return nil
        }
        guard remaining.isFinite else { return nil }
        return .init(
            id: id,
            displayName: string(object["displayName"]) ?? string(object["name"]) ?? id,
            window: window,
            remainingPercent: min(100, max(0, remaining)),
            resetAt: date(object["resetTime"] ?? object["resetsAt"] ?? object["reset_time"])
        )
    }

    private static func window(_ object: [String: Any]) -> AntigravityQuota.Window? {
        let explicit = string(object["window"])
        let candidates = [explicit, string(object["bucketId"]), string(object["displayName"])]
            .compactMap { $0?.lowercased().replacingOccurrences(of: "_", with: "-") }
        if candidates.contains(where: { $0 == "5h" || $0.contains("five-hour") || $0.contains("five hour") || $0 == "session" }) {
            return .fiveHour
        }
        if candidates.contains(where: { $0 == "weekly" || $0.contains("week") }) {
            return .week
        }
        return nil
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
