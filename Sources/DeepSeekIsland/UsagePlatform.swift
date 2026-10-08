import Foundation

enum UsagePlatform: String, Codable, CaseIterable, Identifiable {
    /// `allCases` 的顺序就是界面上平台的固定顺序。
    case deepSeek = "deepseek"
    case zhipu = "zhipu"
    case chatGPT = "chatgpt"

    var id: String { rawValue }
    var officialUsageURL: URL {
        switch self {
        case .deepSeek: URL(string: "https://platform.deepseek.com/usage")!
        case .zhipu: URL(string: "https://bigmodel.cn/coding-plan/personal/usage")!
        case .chatGPT: URL(string: "https://chatgpt.com/codex/settings/usage")!
        }
    }
    var title: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .zhipu: "智谱 CodingPlan"
        case .chatGPT: "ChatGPT"
        }
    }

    /// 三个平台的登录方式不同，未登录时的说明也各说各的。
    var signInHint: String {
        switch self {
        case .deepSeek: "网页登录使用系统浏览器；授权仅保存在本机应用数据。"
        case .zhipu: "在应用内打开智谱官方网页；登录状态保存在本机 WebKit。"
        case .chatGPT: "跳转系统浏览器完成 OpenAI 授权；令牌只存在本机应用数据里。"
        }
    }

    static func restore(saved: String?, hasDeepSeekGrant: Bool) -> UsagePlatform? {
        if let saved, let platform = UsagePlatform(rawValue: saved) { return platform }
        return hasDeepSeekGrant ? .deepSeek : nil
    }
}

struct PlatformAccounts: Equatable {
    let enabled: Set<UsagePlatform>

    var detailTitle: String {
        switch enabled.count {
        case 0: "选择平台"
        case 1: enabled.first?.title ?? "选择平台"
        default: "用量统计"
        }
    }

    static func restore(stored: [String]?,
                        legacy: String?,
                        hasDeepSeekGrant: Bool,
                        hasChatGPTGrant: Bool = false) -> PlatformAccounts {
        var platforms = Set((stored ?? []).compactMap(UsagePlatform.init(rawValue:)))
        if stored == nil, let legacy, let selected = UsagePlatform(rawValue: legacy) {
            platforms.insert(selected)
        }
        if hasDeepSeekGrant { platforms.insert(.deepSeek) }
        if hasChatGPTGrant { platforms.insert(.chatGPT) }
        return PlatformAccounts(enabled: platforms)
    }

    func adding(_ platform: UsagePlatform) -> PlatformAccounts {
        PlatformAccounts(enabled: enabled.union([platform]))
    }

    func removing(_ platform: UsagePlatform) -> PlatformAccounts {
        PlatformAccounts(enabled: enabled.subtracting([platform]))
    }

    var storedValues: [String] { enabled.map(\.rawValue).sorted() }

    /// 已启用的平台，按 `allCases` 的固定顺序（DeepSeek、智谱）。
    /// `Set` 本身无序，菜单与文案都需要稳定顺序。
    var ordered: [UsagePlatform] {
        UsagePlatform.allCases.filter { enabled.contains($0) }
    }
}
