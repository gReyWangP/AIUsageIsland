import Charts
import Combine
import SwiftUI

@MainActor
final class StackedUsageHistory: ObservableObject {
    let runtimes: [AccountRuntime]
    private var observations = Set<AnyCancellable>()
    init(runtimes: [AccountRuntime]) {
        self.runtimes = runtimes
        for runtime in runtimes {
            runtime.analysis.objectWillChange.merge(with: runtime.objectWillChange)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &observations)
        }
    }
    var inputs: [StackedUsageInput] {
        runtimes.map { runtime in
            var snapshot = runtime.analysis.snapshot
            let state = runtime.analysis.freshness(connected: runtime.hasConnectedAccount(for: runtime.account.platform), networkAvailable: runtime.networkAvailable)
            if state.isCached || runtime.analysis.error != nil {
                let buckets: [DailyUsageBucket] = snapshot?.buckets.map { bucket in
                    var cached = bucket; cached.isCached = true; return cached
                } ?? []
                snapshot?.buckets = buckets
            }
            return StackedUsageInput(account: runtime.account, snapshot: snapshot)
        }
    }
    func refresh(onlyMissing: Bool) async {
        for runtime in runtimes {
            await runtime.analysis.waitUntilLoaded()
            guard !Task.isCancelled else { return }
            guard runtime.networkAvailable, !runtime.isRefreshing, !runtime.analysis.isLoading,
                  !onlyMissing || runtime.analysis.snapshot == nil else { continue }
            await runtime.refreshUsageAnalysis()
        }
    }
}

struct StackedUsageAnalysisView: View {
    @ObservedObject var model: IslandModel
    @StateObject private var history: StackedUsageHistory
    @State private var days = 7
    @State private var selected: String?
    @State private var refreshing = false
    init(model: IslandModel) {
        self.model = model
        _history = StateObject(wrappedValue: StackedUsageHistory(runtimes: model.orderedSavedAccounts.map { model.accountRuntime(for: $0) }))
    }
    private var accounts: [AccountReference] { history.runtimes.map(\.account) }
    var body: some View {
        let period = StackedUsagePeriod(inputs: history.inputs, days: days)
        let active = period.buckets.first { $0.day == selected } ?? period.buckets.last
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("时间范围", selection: $days) { Text("近 7 天").tag(7); Text("近 30 天").tag(30) }
                    .pickerStyle(.segmented).frame(width: 200)
                Spacer()
                Button {
                    refreshing = true
                    Task { await history.refresh(onlyMissing: false); refreshing = false }
                } label: { Label("刷新", systemImage: "arrow.clockwise") }
                .disabled(refreshing || history.runtimes.allSatisfy { !$0.networkAvailable })
            }
            HStack(spacing: 12) {
                summary("已返回 Token 合计", period.totalTokens.map(TokenFormatter.short) ?? "—")
                summary("统计范围", "\(period.platforms.count) 个平台 · \(accounts.count) 个账号")
                summary("完整日期", "\(period.completeDays) / \(days) 天")
            }
            if period.buckets.allSatisfy({ $0.totalTokens == nil }) {
                ContentUnavailableView("暂无官方日统计", systemImage: "chart.bar.xaxis", description: Text("各账号成功读取后会自动汇入图表。"))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                chart(period, active: active).frame(height: 230)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(accounts) { account in
                    accountLabel(account)
                        .lineLimit(1).help(label(account))
                }
            }.font(.system(size: 11))
            Text("每个色块代表一个账号 · 浅色表示统计中、缓存或当日数据不完整")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let active { details(active, period: period) }
            VStack(alignment: .leading, spacing: 4) {
                Text("按各平台返回的统计日期合并；ChatGPT 使用 UTC，其他账号沿用各自日界线。")
                Text("同平台多账号分别计入；缺失数据留空，合计仅包含已返回用量。")
                ForEach(history.runtimes, id: \.account) { runtime in
                    if let error = runtime.analysis.error {
                        Text(label(runtime.account) + "：" + error).foregroundStyle(.orange)
                    }
                }
                if period.hasOverflow { Text("部分用量超出可显示范围，暂不绘制该日合计。").foregroundStyle(.orange) }
            }.font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task { await history.refresh(onlyMissing: true) }
    }
    private func label(_ account: AccountReference) -> String {
        let peers = accounts.filter { $0.platform == account.platform }.sorted { $0.id < $1.id }
        let name = model.accountLabel(account)
        let duplicate = peers.filter { model.accountLabel($0) == name }.count > 1
        let suffix = duplicate ? " · 账号\((peers.firstIndex(of: account) ?? 0) + 1)" : ""
        return (name == account.platform.title ? account.platform.title : account.platform.title + " · " + name) + suffix
    }
    private func accountLabel(_ account: AccountReference) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.fill").foregroundStyle(color(account))
            Text(label(account)).foregroundStyle(.primary)
        }
    }
    private func color(_ account: AccountReference) -> Color {
        UsageChartPalette.account(account, among: accounts)
    }
    private func summary(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    private func details(_ day: StackedUsageDay, period: StackedUsagePeriod) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(day.day).fontWeight(.semibold)
                if day.isPartial { Text("统计中 / 不完整").foregroundStyle(.secondary) }
                if day.isCached { Text("缓存").foregroundStyle(.orange) }
                Spacer()
                Picker("日期", selection: Binding(get: { selected ?? period.buckets.last?.day ?? "" }, set: { selected = $0 })) {
                    ForEach(period.buckets) { Text($0.day).tag($0.day) }
                }.labelsHidden().frame(width: 145)
            }
            Text("已返回合计：" + (day.totalTokens.map(TokenFormatter.short) ?? "—") + " Token").fontWeight(.medium)
            ForEach(accounts) { account in
                let segment = day.segments.first { $0.account == account }
                HStack {
                    accountLabel(account).lineLimit(1)
                    Spacer()
                    if let segment {
                        Text(TokenFormatter.short(segment.tokens) + " Token").monospacedDigit()
                    } else { Text("暂无数据").foregroundStyle(.secondary) }
                }
            }
        }.font(.system(size: 11)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
    private func chart(_ period: StackedUsagePeriod, active: StackedUsageDay?) -> some View {
        Chart {
            ForEach(period.buckets) { day in
                ForEach(day.segments) { segment in
                    RectangleMark(xStart: .value("日期", day.date.addingTimeInterval(12960)), xEnd: .value("日期", day.date.addingTimeInterval(73440)), yStart: .value("Token", segment.lower), yEnd: .value("Token", segment.upper))
                        .foregroundStyle(color(segment.account))
                        .opacity(day.isPartial || segment.isCached ? 0.45 : 1)
                        .accessibilityLabel(day.day + " · " + label(segment.account))
                        .accessibilityValue(TokenFormatter.short(segment.tokens) + " Token")
                }
            }
            if let active { RuleMark(x: .value("选择", active.date.addingTimeInterval(43200))).foregroundStyle(.secondary.opacity(0.3)) }
        }
        .chartLegend(.hidden).chartXScale(domain: period.dateDomain)
        .chartXAxis {
            AxisMarks(values: (0..<days).filter { days == 7 || $0 % 5 == 0 }.map { period.dateDomain.lowerBound.addingTimeInterval(Double($0) * 86400 + 43200) }) { value in
                AxisGridLine()
                AxisValueLabel { if let date = value.as(Date.self) { Text(String(UsageAnalysisMath.day(date, timezone: "UTC").suffix(5)).replacingOccurrences(of: "-", with: "/")) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let number = value.as(Double.self) { Text(TokenFormatter.short(Int64(max(0, min(number, Double(Int64.max) - 2048))))) } }
            }
        }
        .chartOverlay { proxy in GeometryReader { geometry in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in if case .active(let location) = phase { select(location, proxy: proxy, geometry: geometry, period: period) } }
                .gesture(DragGesture(minimumDistance: 0).onChanged { select($0.location, proxy: proxy, geometry: geometry, period: period) })
        } }
        .accessibilityLabel("每日各账号用量堆叠柱状图；每种颜色代表一个账号，可在下方选择日期查看明细")
    }
    private func select(_ location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy, period: StackedUsagePeriod) {
        guard let frame = proxy.plotFrame, let date: Date = proxy.value(atX: location.x - geometry[frame].origin.x) else { return }
        let day = UsageAnalysisMath.day(date, timezone: "UTC")
        if selected != day, period.buckets.contains(where: { $0.day == day }) { selected = day }
    }
}
