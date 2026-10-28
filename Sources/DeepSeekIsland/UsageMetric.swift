import Foundation

/// Stable business identifiers. Raw values are persisted in preferences and notifications.
enum UsageMetric: String, CaseIterable, Identifiable, Codable {
    case deepSeekBalance, zhipuFiveHour, zhipuWeek, chatGPTFiveHour, chatGPTWeek
    var id: String { rawValue }
    var platform: UsagePlatform {
        switch self {
        case .deepSeekBalance: .deepSeek
        case .zhipuFiveHour, .zhipuWeek: .zhipu
        case .chatGPTFiveHour, .chatGPTWeek: .chatGPT
        }
    }
    var windowLabel: String {
        switch self {
        case .deepSeekBalance: "余额"
        case .zhipuFiveHour, .chatGPTFiveHour: "5 小时"
        case .zhipuWeek, .chatGPTWeek: "本周"
        }
    }
    var title: String { platform.title + " · " + (self == .deepSeekBalance ? "剩余余额" : windowLabel + "剩余额度") }
    var windowSeconds: Int? {
        switch self {
        case .deepSeekBalance: nil
        case .zhipuFiveHour, .chatGPTFiveHour: 18_000
        case .zhipuWeek, .chatGPTWeek: 604_800
        }
    }
    static func defaultMetric(for platform: UsagePlatform) -> Self {
        switch platform { case .deepSeek: .deepSeekBalance; case .zhipu: .zhipuFiveHour; case .chatGPT: .chatGPTFiveHour }
    }
    static func dualQuotaMetrics(for platform: UsagePlatform) -> (fiveHour: Self, week: Self)? {
        switch platform {
        case .deepSeek: nil
        case .zhipu: (.zhipuFiveHour, .zhipuWeek)
        case .chatGPT: (.chatGPTFiveHour, .chatGPTWeek)
        }
    }
}

extension UsageMetric {
    static func quotaMetric(for platform: UsagePlatform, windowSeconds: Int?) -> Self? {
        guard let windowSeconds else { return nil }
        return allCases.first { $0.platform == platform && $0.windowSeconds == windowSeconds }
    }
}
