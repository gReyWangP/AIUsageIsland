import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: IslandSettings
    @ObservedObject var source: AccountRuntime
    let canRefresh: Bool
    let onRefresh: () -> Void
    let onAnalysis: () -> Void
    let onSettings: () -> Void
    var onClose: () -> Void = {}

    private var platform: UsagePlatform { source.account.platform }
    private var metrics: [UsageMetric] { UsageMetric.allCases.filter { $0.platform == platform } }
    private var nextReset: Date? {
        metrics.compactMap { source.quotaResetDate(for: $0) }.filter { $0 > .now }.min()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.accountLabel(source.account)).font(.system(size: 17, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if platform == .chatGPT {
                        Text("Codex").font(.caption).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                Text(source.freshness(for: platform).label).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).help(source.freshness(for: platform).detail)
            }
            ForEach(metrics) { metric in metricRow(metric) }
            if platform != .deepSeek {
                Divider()
                HStack {
                    Label("下次重置", systemImage: "clock").foregroundStyle(.secondary)
                    Spacer()
                    if let nextReset {
                        Text(nextReset.formatted(date: Calendar.current.isDateInToday(nextReset) ? .omitted : .abbreviated, time: .shortened))
                            .monospacedDigit()
                    } else { Text("暂无时间").foregroundStyle(.secondary) }
                }.font(.callout)
            }
            Divider()
            HStack {
                Button(action: onRefresh) { Label("刷新", systemImage: "arrow.clockwise") }.disabled(!canRefresh)
                Spacer(minLength: 8)
                Button(action: onAnalysis) { Label("用量分析", systemImage: "chart.bar") }
                    .disabled(!source.hasConnectedAccount(for: platform))
                Spacer(minLength: 8)
                Button(action: onSettings) { Label("设置", systemImage: "gearshape") }
            }.buttonStyle(.borderless).font(.callout)
        }
        .padding(20).frame(width: 360, alignment: .leading)
        .background(IslandBackground(effect: settings.backgroundEffect))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .foregroundStyle(.primary)
        .preferredColorScheme(settings.appearanceMode.colorScheme)
        .onExitCommand(perform: onClose)
    }

    private func metricRow(_ metric: UsageMetric) -> some View {
        let data = source.localMenuBarData(for: metric)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric == .deepSeekBalance ? "剩余余额" : metric.windowLabel + "额度")
                Spacer()
                switch data {
                case .quota(let remaining, _) where remaining.isFinite:
                    Text("剩余 \(remaining, specifier: "%.0f")%").monospacedDigit()
                        .foregroundStyle(quotaColor(remaining, metric: metric))
                case .balance(let amount, let currency):
                    Text((currency == "CNY" ? "¥" : currency == "USD" ? "$" : currency + " ") + NSDecimalNumber(decimal: amount).stringValue)
                        .monospacedDigit()
                case .unlimited: Text("无限制").foregroundStyle(.secondary)
                default: Text("—").foregroundStyle(.secondary)
                }
            }.font(.callout)
            if case .quota(let remaining, _) = data, remaining.isFinite {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.16))
                        Capsule().fill(quotaColor(remaining, metric: metric))
                            .frame(width: geometry.size.width * max(0, min(100, remaining)) / 100)
                    }
                }.frame(height: 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(metric.title)
                    .accessibilityValue("剩余 \(Int(max(0, min(100, remaining))))%")
            } else if case .unavailable(let reason) = data {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
    private func quotaColor(_ remaining: Double, metric: UsageMetric) -> Color {
        if remaining < 10 { return .red }
        if remaining < 20 { return .orange }
        return metric.windowSeconds == 604_800 ? .blue : .green
    }
}
