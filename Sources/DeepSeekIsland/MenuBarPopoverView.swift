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
    var sideDockCallout = false
    var calloutPointsLeft = false
    @ObservedObject var calloutSurface = SideDockCalloutSurface()

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
            if platform == .deepSeek {
                Divider()
                DeepSeekDailyUsageView(source: source)
            } else {
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
                Divider().frame(height: 16)
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power").frame(width: 24, height: 24)
                }
                .help("退出应用")
                .accessibilityLabel("退出应用")
            }.buttonStyle(.borderless).font(.callout)
        }
        .padding(20).frame(width: 360, alignment: .leading)
        .padding(.leading, sideDockCallout && calloutPointsLeft ? SideDockCalloutShape.pointerWidth : 0)
        .padding(.trailing, sideDockCallout && !calloutPointsLeft ? SideDockCalloutShape.pointerWidth : 0)
        .background {
            if sideDockCallout { Color.black }
            else { IslandBackground(effect: settings.backgroundEffect) }
        }
        .clipShape(PopoverOutline(callout: sideDockCallout, pointsLeft: calloutPointsLeft, pointerY: calloutSurface.pointerY))
        .foregroundStyle(.primary)
        .preferredColorScheme(sideDockCallout ? .dark : settings.appearanceMode.colorScheme)
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
                    Text(Self.balanceText(amount, currency: currency))
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
    nonisolated static func balanceText(_ amount: Decimal, currency: String) -> String {
        var original = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &original, 2, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let prefix = currency == "CNY" ? "¥" : currency == "USD" ? "$" : currency + " "
        return prefix + (formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? "—")
    }

    private func quotaColor(_ remaining: Double, metric: UsageMetric) -> Color {
        if remaining < 10 { return .red }
        if remaining < 20 { return .orange }
        return metric.windowSeconds == 604_800 ? .blue : .green
    }
}

private struct PopoverOutline: Shape {
    var callout: Bool
    var pointsLeft: Bool
    var pointerY: CGFloat
    func path(in rect: CGRect) -> Path {
        callout ? SideDockCalloutShape(pointsLeft: pointsLeft, pointerY: pointerY).path(in: rect)
            : RoundedRectangle(cornerRadius: 16, style: .continuous).path(in: rect)
    }
}
