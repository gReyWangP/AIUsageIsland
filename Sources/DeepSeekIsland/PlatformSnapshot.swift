import Foundation

/// 详情里的一行指标。
struct DetailMetricRow: Identifiable {
    let id: String
    let label: String
    let value: String
    var detail: String?
    var resetAt: Date? = nil
    var resetUsedPercent: Double? = nil
    var resetFresh = true
    var reservationMetric: UsageMetric? = nil
}

/// 悬浮条里的一格指标。
struct CompactMetric: Identifiable {
    let id: String
    let label: String
    let value: String
    var resetAt: Date? = nil
    func resetText(at now: Date = .now) -> String? {
        guard let resetAt else { return nil }
        guard resetAt > now else { return "待刷新" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(resetAt, inSameDayAs: now) ? "HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: resetAt)
    }
}

/// 一个平台要展示的全部内容，**与排版无关**。
///
/// 排版只消费这个结构：横向悬浮条、纵向悬浮条、并列栏详情、堆叠详情
/// 都从同一份快照取值，所以新增平台只需要多产出一份快照，
/// 新增排版只需要多写一个消费快照的 View——两者正交。
struct PlatformSnapshot: Identifiable {
    /// 唯一键。刻意不用 `UsagePlatform` 当身份——同一个平台将来可能有多个账号，
    /// 那时会出现两份同平台快照。
    var id: String
    let platform: UsagePlatform
    /// 卡片与悬浮条上的展示名。
    var title: String

    // 悬浮内容
    var compactMetrics: [CompactMetric]

    // 详情内容
    let heroLabel: String
    let heroValue: String
    let heroSuffix: String?
    let rows: [DetailMetricRow]
    let note: String
    let accountName: String?
    let isConnected: Bool
    let isSigningIn: Bool
    let error: String?
    /// 非致命提示（余额不足、额度用尽…）。文案由各平台自己给，
    /// 排版层只负责用橙色小字显示——它不该知道「余额」是什么意思。
    let warning: String?
    let refreshText: String?
    var analysisOverview: UsageAnalysisOverview? = nil
    var dataFreshness = DataFreshness(phase: .empty, lastSuccess: nil)
}

extension Array {
    /// 越界返回 nil。各平台行数可能不同，排版要按最大行数遍历。
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
