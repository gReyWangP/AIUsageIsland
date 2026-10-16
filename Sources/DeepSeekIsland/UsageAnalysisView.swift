import AppKit
import Charts
import Combine
import SwiftUI

struct UsageAnalysisOverview {
    let today: String
    let detail: String
    @MainActor static func make(_ history: UsageAnalysisStore, platform: UsagePlatform) -> Self {
        history.overview(platform:platform)
    }
    @MainActor static func build(_ history: UsageAnalysisStore, platform: UsagePlatform) -> Self {
        let snapshot = history.snapshot
        let todayKey=UsageAnalysisMath.day(.now,timezone:snapshot?.timezone ?? "Asia/Shanghai")
        let today = snapshot?.buckets.first {$0.day == todayKey}
        let recent = history.period(days:7).buckets
        var lines = ["今日：" + (today.map {TokenFormatter.short($0.tokens)+" Token（统计中）"} ?? "暂无官方数据")]
        if platform == .deepSeek {
            lines.append("近 7 天输入缓存命中率：" + (UsageAnalysisMath.cacheRate(recent).map {String(format:"%.1f%%",$0)} ?? "—"))
            if let miss = today?.uncachedInput { lines.append("今日未命中输入："+TokenFormatter.short(miss)+" Token") }
            if let cost = today?.cost { lines.append("今日官方费用："+UsageFormat.cost(cost,currency:snapshot?.currency ?? "CNY",estimated:false)) }
        } else if let total = UsageAnalysisMath.sum(recent.map(\.tokens)), !recent.isEmpty {
            lines.append("近 7 天已返回："+TokenFormatter.short(total)+" Token，覆盖 \(recent.count)/7 天")
        }
        lines.append(snapshot?.source.label ?? "等待官方用量统计")
        if let date = snapshot?.updatedAt { lines.append("更新："+date.formatted(date:.abbreviated,time:.shortened)) }
        if today?.isCached == true { lines.append("今日数值为上次返回的缓存，可能不完整") }
        if let error = history.error { lines.append(error) }
        if let error = history.persistenceError { lines.append(error) }
        return .init(today:today.map { TokenFormatter.short($0.tokens)+" Token" } ?? "—",detail:lines.joined(separator:"\n"))
    }
}
struct UsageOverviewRow: View {
    let overview: UsageAnalysisOverview?
    let action: () -> Void
    var body: some View {
        HStack(spacing:5) {
            Text("今日消耗").foregroundStyle(.secondary)
            Text(overview?.today ?? "—").monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength:0)
            Button(action:action) { Image(systemName:"chart.bar.xaxis") }.buttonStyle(.plain)
                .accessibilityLabel("用量分析").help("打开用量分析")
        }.font(.system(size:10)).padding(.vertical,5)
        .help((overview?.detail ?? "暂无官方日统计")+"\n点击查看完整趋势")
        .contentShape(Rectangle()).onTapGesture(perform:action)
    }
}
@MainActor
final class UsageAnalysisWindowController {
    static let shared = UsageAnalysisWindowController()
    private var window: NSWindow?
    private var appearanceObservation: AnyCancellable?
    var onShow: (() -> Void)?
    func show(model: IslandModel, account: AccountReference, section: UsageAnalysisSection = .consumption) {
        onShow?()
        if window == nil { window=Self.makeWindow(); window?.center() }
        if let settings=model.presentationSettings {
            window?.appearance=settings.appearanceMode.nsAppearance
            appearanceObservation=settings.$appearanceMode.sink { [weak self] mode in
                Task { @MainActor [weak self] in self?.window?.appearance=mode.nsAppearance }
            }
        }
        window?.contentView = Self.makeContentView(model:model,account:account,section:section)
        window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true)
    }
    static func makeContentView(model: IslandModel, account: AccountReference, section: UsageAnalysisSection = .consumption) -> NSHostingView<UsageAnalysisView> {
        let hosting = NSHostingView(rootView:UsageAnalysisView(model:model,initialAccount:account,initialSection:section))
        // Charts have a large ideal height. Let the resizable window propose its size,
        // rather than allowing hosting intrinsic/minimum sizes to resize the window.
        hosting.sizingOptions = []
        return hosting
    }
    static func makeWindow() -> NSWindow {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:840,height:700),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title="AIUsageIsland · 用量分析"
        window.minSize=window.frameRect(forContentRect:NSRect(x:0,y:0,width:780,height:480)).size
        window.isReleasedWhenClosed=false
        window.level = .normal
        window.collectionBehavior = []
        return window
    }

}
enum UsageAnalysisSection: String, CaseIterable, Identifiable {
    case consumption = "消耗统计"
    case quotaChanges = "额度变化"
    var id: String { rawValue }
}
struct UsageAnalysisView: View {
    @ObservedObject var model: IslandModel
    @State private var account: AccountReference?
    @State private var section: UsageAnalysisSection
    @State private var allAccounts: Bool
    init(model: IslandModel, initialAccount: AccountReference, initialSection: UsageAnalysisSection = .consumption) {
        self.model=model; _account=State(initialValue:initialAccount); _section=State(initialValue:initialSection)
        _allAccounts = State(initialValue: model.savedAccounts.count > 1)
    }
    private var combined: Bool { section == .consumption && allAccounts && model.savedAccounts.count > 1 }
    private var accountChoice: Binding<AccountReference?> {
        Binding(get: { combined ? nil : account }, set: { value in
            allAccounts = value == nil
            if let value { account = value }
        })
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("用量分析").font(.title2).fontWeight(.semibold)
                Spacer()
                Picker("统计范围",selection:accountChoice) {
                    if section == .consumption, model.savedAccounts.count > 1 {
                        Text("全部平台与账号").tag(nil as AccountReference?)
                    }
                    ForEach(model.orderedSavedAccounts) { item in Text(model.accountLabel(item) == item.platform.title ? item.platform.title : model.accountLabel(item)+" · "+item.platform.title).tag(Optional(item)) }
                    if model.savedAccounts.isEmpty { Text("尚未添加账号").tag(nil as AccountReference?) }
                }.frame(maxWidth:330).disabled(model.savedAccounts.isEmpty)
            }
            Picker("分析内容", selection: $section) {
                ForEach(UsageAnalysisSection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if combined {
                ScrollView {
                    StackedUsageAnalysisView(model: model).frame(minHeight: 540)
                        .id(model.orderedSavedAccounts.map(\.id).joined(separator: ","))
                }
            } else if let account, model.savedAccounts.contains(account) {
                ScrollView {
                    if section == .consumption {
                        UsageAnalysisAccountView(runtime:model.accountRuntime(for:account))
                            .frame(minHeight: 540)
                    } else {
                        UsageTrendView(runtime:model.accountRuntime(for:account),accountName:model.accountLabel(account),embedded:true)
                            .frame(minHeight:540)
                    }
                }.id(account.id)
            } else {
                ContentUnavailableView("账号已移除",systemImage:"person.crop.circle.badge.xmark",description:Text("请选择其他账号查看用量"))
            }
        }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity).background(.background)
        .onAppear { reconcileAccount() }
        .onChange(of: model.orderedSavedAccounts.map(\.id)) { reconcileAccount() }
    }
    private func reconcileAccount() {
        if let account, model.savedAccounts.contains(account) { return }
        account = model.orderedSavedAccounts.first
    }
}
private enum AnalysisMetric: String, CaseIterable, Identifiable { case tokens="Token", cost="费用", cache="缓存命中率"; var id: String {rawValue} }
struct UsageAnalysisAccountView: View {
    @ObservedObject var runtime: AccountRuntime
    @ObservedObject private var history: UsageAnalysisStore
    @State private var days = 7
    @State private var metric = AnalysisMetric.tokens
    @State private var selected: String?
    init(runtime: AccountRuntime) { self.runtime=runtime; history=runtime.analysis }
    private var prepared: UsageAnalysisPeriod {history.period(days:days)}
    private var buckets: [DailyUsageBucket] {prepared.buckets}
    private var averages: [DailyUsageBucket] {prepared.averages}
    private var active: DailyUsageBucket? { buckets.first {$0.day == selected} ?? buckets.last }
    private var timezoneLabel: String { history.snapshot?.source == .chatGPT ? "官方日期，暂按 UTC 解读" : (history.snapshot?.timezone ?? "Asia/Shanghai") }
    private var costText: String {
        prepared.cost.map {UsageFormat.cost($0,currency:history.snapshot?.currency ?? runtime.currency,estimated:false)} ?? "—"
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Picker("时间范围",selection:$days) { Text("近 7 天").tag(7); Text("近 30 天").tag(30) }.pickerStyle(.segmented).frame(width:200)
                Spacer()
                Button { Task { await runtime.refreshUsageAnalysis() } } label: { Label("刷新",systemImage:"arrow.clockwise") }
                    .disabled(runtime.isRefreshing || history.isLoading || !runtime.networkAvailable)
            }
            HStack(spacing:12) {
                summary("已返回 Token",prepared.totalTokens.map(TokenFormatter.short) ?? "—")
                if runtime.account.platform == .deepSeek {
                    summary("输入缓存命中率",prepared.cacheRate.map {String(format:"%.1f%%",$0)} ?? "—")
                    summary("官方费用",costText)
                } else {
                    summary("完整日均",prepared.completeAverage.map(TokenFormatter.short) ?? "—")
                    summary("返回日期","\(buckets.count) / \(days) 天")
                }
            }
            if runtime.account.platform == .deepSeek {
                Picker("指标",selection:$metric) { ForEach(AnalysisMetric.allCases) {Text($0.rawValue).tag($0)} }.pickerStyle(.segmented).frame(width:320)
            }
            if buckets.isEmpty {
                ContentUnavailableView("暂无官方日统计",systemImage:"chart.bar.xaxis",description:Text("成功读取后会补入平台返回的历史。缺失数据不会作为零消耗展示。"))
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                usageChart.frame(minHeight:220,maxHeight:.infinity)
                HStack(spacing:12) {
                    if metric == .tokens {
                        Label("每日 Token",systemImage:"square.fill").foregroundStyle(UsageChartPalette.theme(runtime.account.platform))
                        Label("完整 7 日均值",systemImage:"minus").foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("浅色柱：统计中 / 缓存").foregroundStyle(.secondary)
                }.font(.system(size:10))
                selectedDay
            }
            VStack(alignment:.leading,spacing:4) {
                Text((history.snapshot?.source.label ?? "等待官方数据")+" · 日界线："+timezoneLabel+" · 覆盖 \(buckets.count)/\(days) 天（\(buckets.filter {$0.isCached == true}.count) 天缓存）")
                if let date = history.snapshot?.updatedAt { Text("最后成功更新："+date.formatted(date:.abbreviated,time:.shortened)) }
                Text("缺失日期留空；今日仍在统计。均值仅使用连续 7 个完整日期。费用使用官方金额，不把订阅额度换算成费用。")
                if let error = history.error { Text(error).foregroundStyle(.orange) }
                if let error = history.persistenceError { Text(error).foregroundStyle(.orange) }
                if let failure = runtime.refreshPolicy.explanation { Text(failure).foregroundStyle(.secondary) }
            }.font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
        .task {
            await history.waitUntilLoaded()
            guard runtime.networkAvailable, !runtime.isRefreshing, !history.isLoading,
                  history.snapshot == nil else { return }
            await runtime.refreshUsageAnalysis()
        }
    }
    private func summary(_ title: String, _ value: String) -> some View {
        VStack(alignment:.leading,spacing:6) { Text(title).font(.system(size:11)).foregroundStyle(.secondary);Text(value).font(.system(size:22,weight:.semibold,design:.rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7) }
            .frame(maxWidth:.infinity,alignment:.leading).padding(14).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:12))
    }
    private var selectedDay: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Text(active?.day ?? "选择日期").fontWeight(.semibold)
                if active?.isPartial == true { Text("统计中 / 不完整").foregroundStyle(.secondary) }
                if active?.isCached == true || history.error != nil { Text("缓存").foregroundStyle(.orange) }
                Spacer()
                Picker("日期",selection:Binding(get:{selected ?? buckets.last?.day ?? ""},set:{selected=$0})) {
                    ForEach(buckets) { Text($0.day).tag($0.day) }
                }.labelsHidden().frame(width:145)
            }
            if let b = active {
                if b.isCached == true, let date=b.lastReturnedAt { Text("此日最后返回："+date.formatted(date:.abbreviated,time:.shortened)).foregroundStyle(.secondary) }
                Text("Token："+TokenFormatter.short(b.tokens))
                if runtime.account.platform == .deepSeek {
                    Text(categoryText(b))
                    Text(cacheCostText(b))
                }
            }
        }.font(.system(size:11)).padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
    }
    private func categoryText(_ b: DailyUsageBucket) -> String {
        let hit = b.cachedInput.map(TokenFormatter.short) ?? "—"
        let miss = b.uncachedInput.map(TokenFormatter.short) ?? "—"
        let output = b.output.map(TokenFormatter.short) ?? "—"
        return "缓存输入：\(hit) · 未缓存输入：\(miss) · 输出：\(output)"
    }
    private func cacheCostText(_ b: DailyUsageBucket) -> String {
        let rate = UsageAnalysisMath.cacheRate([b]).map {String(format:"%.1f%%",$0)} ?? "—"
        let cost = b.cost.map {UsageFormat.cost($0,currency:history.snapshot?.currency ?? runtime.currency,estimated:false)} ?? "—"
        return "输入缓存命中率：\(rate) · 官方费用：\(cost)"
    }
    private var usageChart: some View {
        Chart {
            ForEach(buckets) { b in
                if metric == .tokens {
                    RectangleMark(xStart:.value("日期",b.date.addingTimeInterval(12960)),xEnd:.value("日期",b.date.addingTimeInterval(73440)),yStart:.value("Token",0),yEnd:.value("Token",b.tokens))
                        .foregroundStyle(UsageChartPalette.theme(runtime.account.platform)).opacity(b.isPartial || b.isCached == true ? 0.45:1)
                } else if metric == .cost, let cost=b.cost {
                    RectangleMark(xStart:.value("日期",b.date.addingTimeInterval(12960)),xEnd:.value("日期",b.date.addingTimeInterval(73440)),yStart:.value("费用",0),yEnd:.value("费用",NSDecimalNumber(decimal:cost).doubleValue)).foregroundStyle(UsageChartPalette.theme(runtime.account.platform)).opacity(b.isPartial || b.isCached == true ? 0.45:1)
                } else if metric == .cache, let rate=UsageAnalysisMath.cacheRate([b]) {
                    RectangleMark(xStart:.value("日期",b.date.addingTimeInterval(12960)),xEnd:.value("日期",b.date.addingTimeInterval(73440)),yStart:.value("命中率",0),yEnd:.value("命中率",rate)).foregroundStyle(UsageChartPalette.theme(runtime.account.platform)).opacity(b.isPartial || b.isCached == true ? 0.45:1)
                }
            }
            if metric == .tokens {
                ForEach(averages) { b in
                    LineMark(x:.value("日期",b.date.addingTimeInterval(43200)),y:.value("Token",b.tokens),series:.value("连续区间",averageSegment(b)))
                        .foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth:2))
                    PointMark(x:.value("日期",b.date.addingTimeInterval(43200)),y:.value("Token",b.tokens)).foregroundStyle(.orange).symbolSize(12)
                }
            }
            if let active { RuleMark(x:.value("选择",active.date.addingTimeInterval(43200))).foregroundStyle(.secondary.opacity(0.3)) }
        }
        .chartLegend(.hidden)
        .chartXScale(domain:dateDomain)
        .chartXAxis { AxisMarks(values:axisDates) { value in
            AxisGridLine(); AxisValueLabel(anchor:.top) { if let date=value.as(Date.self) { Text(axisDateLabel(date)) } }
        } }
        .chartYAxis {
            AxisMarks(position:.leading) { value in
                AxisGridLine(); AxisValueLabel {
                    if let number=value.as(Double.self) {
                        if metric == .tokens { Text(TokenFormatter.short(Int64(max(0,min(number,Double(Int64.max)-2048))))) }
                        else if metric == .cache { Text(String(format:"%.0f%%",number)) }
                        else { Text(UsageFormat.currencySymbol(history.snapshot?.currency ?? runtime.currency)+String(format:"%.2f",number)) }
                    }
                }
            }
        }
        .chartOverlay { proxy in GeometryReader { geometry in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in if case .active(let location) = phase { select(at:location,proxy:proxy,geometry:geometry) } }
                .gesture(DragGesture(minimumDistance:0).onChanged { select(at:$0.location,proxy:proxy,geometry:geometry) })
        } }
        .accessibilityLabel("每日消耗图，缺失日期留空；也可使用下方日期选择器查看详情")
    }
    private var axisDates: [Date] { (0..<days).filter { days == 7 || $0 % 5 == 0 }.map {dateDomain.lowerBound.addingTimeInterval(Double($0)*86400+43200)} }
    private func axisDateLabel(_ date: Date) -> String {
        let day=UsageAnalysisMath.day(date,timezone:"UTC")
        return "\(Int(day.dropFirst(5).prefix(2))!)月\(Int(day.suffix(2))!)日"
    }
    private var dateDomain: ClosedRange<Date> {prepared.dateDomain}
    private func averageSegment(_ b: DailyUsageBucket) -> String {prepared.segments[b.day] ?? "0"}
    private func select(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let frame = proxy.plotFrame else { return }
        let x = location.x-geometry[frame].origin.x
        if let date: Date = proxy.value(atX:x) {
            let day=UsageAnalysisMath.day(date,timezone:"UTC")
            if selected != day, buckets.contains(where:{$0.day == day}) {selected=day}
        }
    }
}
