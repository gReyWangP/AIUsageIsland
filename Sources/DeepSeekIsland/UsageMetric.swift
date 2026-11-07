import Foundation

/// Stable business identifiers. Raw values are persisted in preferences and notifications.
enum UsageMetric: String, CaseIterable, Identifiable, Codable {
    case deepSeekBalance, zhipuFiveHour, zhipuWeek, chatGPTFiveHour, chatGPTWeek
    case openCodeGoFiveHour, openCodeGoWeek, openCodeGoMonth
    var id: String { rawValue }
    var platform: UsagePlatform {
        switch self {
        case .deepSeekBalance: .deepSeek
        case .zhipuFiveHour, .zhipuWeek: .zhipu
        case .chatGPTFiveHour, .chatGPTWeek: .chatGPT
        case .openCodeGoFiveHour, .openCodeGoWeek, .openCodeGoMonth: .openCodeGo
        }
    }
    var windowLabel: String {
        switch self {
        case .deepSeekBalance: "余额"
        case .zhipuFiveHour, .chatGPTFiveHour, .openCodeGoFiveHour: "5 小时"
        case .zhipuWeek, .chatGPTWeek, .openCodeGoWeek: "本周"
        case .openCodeGoMonth: "本月"
        }
    }
    var title: String { platform.title + " · " + (self == .deepSeekBalance ? "剩余余额" : windowLabel + "剩余额度") }
    var windowSeconds: Int? {
        switch self {
        case .deepSeekBalance: nil
        case .zhipuFiveHour, .chatGPTFiveHour, .openCodeGoFiveHour: 18_000
        case .zhipuWeek, .chatGPTWeek, .openCodeGoWeek: 604_800
        case .openCodeGoMonth: 2_592_000
        }
    }
    static func defaultMetric(for platform: UsagePlatform) -> Self {
        switch platform {
        case .deepSeek: .deepSeekBalance
        case .zhipu: .zhipuFiveHour
        case .chatGPT: .chatGPTFiveHour
        case .openCodeGo: .openCodeGoFiveHour
        }
    }
    static func dualQuotaMetrics(for platform: UsagePlatform) -> (fiveHour: Self, week: Self)? {
        switch platform {
        case .deepSeek: nil
        case .zhipu: (.zhipuFiveHour, .zhipuWeek)
        case .chatGPT: (.chatGPTFiveHour, .chatGPTWeek)
        case .openCodeGo: (.openCodeGoFiveHour, .openCodeGoWeek)
        }
    }
    static func monthQuotaMetric(for platform: UsagePlatform) -> Self? {
        platform == .openCodeGo ? .openCodeGoMonth : nil
    }
}

extension UsageMetric {
    static func quotaMetric(for platform: UsagePlatform, windowSeconds: Int?) -> Self? {
        guard let windowSeconds else { return nil }
        return allCases.first { $0.platform == platform && $0.windowSeconds == windowSeconds }
    }
}
