import SwiftUI

/// Keeps the current day's official totals and cache categories together. Old days
/// must never appear as today's usage when a card stays open across midnight.
struct DeepSeekDailyUsageSummary {
    let bucket: DailyUsageBucket?
    let tokens: Int64?
    let cost: Decimal?
    let currency: String
    let timezone: String
    let freshness: DataFreshness

    init(snapshot: UsageAnalysisSnapshot?, officialUsage: OfficialUsageSummary?,
         usageUpdatedAt: Date?, currency: String, freshness: DataFreshness, now: Date = .now) {
        let snapshot = snapshot?.source == .deepSeek ? snapshot : nil
        timezone = snapshot?.timezone ?? TimeZone.current.identifier
        let today = UsageAnalysisMath.day(now, timezone: timezone)
        bucket = snapshot?.buckets.first { $0.day == today }
        // The summary endpoint can establish zero usage even when there is no
        // Token bucket. Its today range uses the system calendar at fetch time.
        let currentTotal = usageUpdatedAt.flatMap { updated -> OfficialUsageTotal? in
            guard UsageAnalysisMath.day(updated, timezone: TimeZone.current.identifier)
                    == UsageAnalysisMath.day(now, timezone: TimeZone.current.identifier) else { return nil }
            return officialUsage?.today
        }
        if let bucket {
            tokens = bucket.tokens
            cost = bucket.cost
            self.currency = snapshot?.currency ?? currency
        } else {
            tokens = currentTotal?.tokens
            cost = currentTotal?.cost
            self.currency = currency
        }
        self.freshness = freshness
    }

    var tokensText: String { tokens.map(TokenFormatter.short) ?? "—" }
    var costText: String { cost.map { MenuBarPopoverView.balanceText($0, currency: currency) } ?? "—" }
    var cacheRate: Double? { bucket.flatMap { UsageAnalysisMath.cacheRate([$0]) } }
    var cacheRateText: String { cacheRate.map { String(format: "%.1f%%", $0) } ?? "—" }
    var cachedInputText: String { bucket?.cachedInput.map(TokenFormatter.short) ?? "—" }
    var uncachedInputText: String { bucket?.uncachedInput.map(TokenFormatter.short) ?? "—" }
    var outputText: String { bucket?.output.map(TokenFormatter.short) ?? "—" }
    var isCached: Bool {
        bucket?.isCached == true || freshness.isCached || freshness.phase == .loading
    }
    var note: String {
        guard tokens != nil || cost != nil else {
            return freshness.phase == .loading ? "正在获取今日用量" : "暂无今日官方用量"
        }
        let zone = timezone == "Asia/Shanghai" ? "按北京时间累计" : "按 \(timezone) 累计"
        return (isCached ? "今日用量为缓存" : "今日仍在统计") + " · " + zone
    }
}

struct DeepSeekDailyUsageView: View {
    @ObservedObject var source: AccountRuntime
    @ObservedObject private var history: UsageAnalysisStore

    init(source: AccountRuntime) {
        self.source = source
        history = source.analysis
    }

    private var summary: DeepSeekDailyUsageSummary {
        DeepSeekDailyUsageSummary(snapshot: history.snapshot, officialUsage: source.officialUsage,
            usageUpdatedAt: source.usageLastUpdated, currency: source.currency,
            freshness: source.deepSeekUsageFreshness())
    }

    var body: some View {
        let usage = summary
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                dailyMetric("今日消耗", value: usage.costText, note: "官方费用")
                dailyMetric("今日 Token", value: usage.tokensText, note: "输入 + 输出")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("今日输入缓存命中率").foregroundStyle(.secondary)
                    Spacer()
                    Text(usage.cacheRateText).monospacedDigit()
                        .foregroundStyle(usage.cacheRate == nil ? Color.secondary : .teal)
                }.font(.callout)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.16))
                        if let rate = usage.cacheRate {
                            Capsule().fill(Color.teal)
                                .frame(width: geometry.size.width * rate / 100)
                        }
                    }
                }.frame(height: 5)
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    Text("缓存输入 " + usage.cachedInputText)
                    Spacer(minLength: 4)
                    Text("未缓存 " + usage.uncachedInputText)
                    Spacer(minLength: 4)
                    Text("输出 " + usage.outputText)
                }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .help("缓存命中率 = 缓存输入 Token ÷ 全部输入 Token；不包含输出。没有输入数据时显示 —。")
            Text(usage.note).font(.system(size: 10))
                .foregroundStyle(usage.isCached ? Color.orange : Color.secondary)
                .lineLimit(2)
                .help(source.deepSeekUsageFreshness().detail + "\n" + (history.error ?? "费用与 Token 取自平台官方用量接口。"))
        }
    }

    private func dailyMetric(_ title: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(note).font(.system(size: 10)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
