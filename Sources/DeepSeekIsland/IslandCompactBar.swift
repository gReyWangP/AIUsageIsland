import SwiftUI

/// 仅测量卡片自然高度，避免把动画中的尺寸反馈为下一帧目标。
private struct CompactCellHeightsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 悬浮内容。按设置选择横向或纵向排版，两者共用同一份快照。
struct IslandCompactBar: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: IslandPalette { IslandPalette(scheme: colorScheme) }
    @State private var cellHeights: [String: CGFloat] = [:]
    let snapshots: [PlatformSnapshot]
    let layout: CompactLayout
    let hasNotch: Bool
    /// 横向时的总宽度（刘海 + 两侧翅膀，或外接屏的固定宽度）。
    let horizontalWidth: CGFloat
    let notchWidth: CGFloat
    let bandHeight: CGFloat
    var currentWidth: CGFloat? = nil
    var currentProgress: CGFloat? = nil
    /// 上报实测尺寸，**并且带上自己是哪个排版**。
    ///
    /// 必须带上：切换排版时上一个排版的测量会迟到，
    /// 若由接收方按「当前设置」猜是哪个排版，就会把 A 的尺寸记到 B 名下、
    /// 甚至把已经改对的面板尺寸又覆盖回旧值。
    var onContentSizeChange: (CompactLayout, CGSize) -> Void = { _, _ in }
    /// 点击悬浮条展开／收起详情。
    ///
    /// 这是无刘海屏幕上**唯一**的展开入口——`acceptsCameraClick` 在没有刘海时恒为 false，
    /// 所以这层 Button 不能省。
    var onTap: () -> Void = {}

    /// 纵向时的宽度：以刘海宽度为准，但要保证两行指标放得下。
    private var verticalWidth: CGFloat {
        CompactLayout.vertical.barWidth(hasNotch: hasNotch,
                                        notchWidth: notchWidth,
                                        horizontalBarWidth: horizontalWidth)
    }

    var body: some View {
        Button(action: onTap) {
            Group {
                if usesNotchWings {
                    // 两种内容始终在场，横纵切换时渐变接续；相机空位保持不变。
                    ZStack(alignment: .top) {
                        belowNotchContent.opacity(1 - layoutProgress)
                            .accessibilityHidden(layout == .horizontal)
                        notchWings
                            .frame(width: displayedWidth, alignment: .center)
                            .opacity(layoutProgress)
                            .accessibilityHidden(layout == .vertical)
                    }
                    .frame(width: displayedWidth, height: displayedBarHeight, alignment: .top)
                } else {
                    belowNotchContent
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击展开或收起详情")
        // 按理想尺寸布局，不受容器高度影响——防止任何弹性子视图
        // 把悬浮条撑到面板高度，也切断「测量值 → 面板 → 可用高度 → 测量值」的循环。
        .fixedSize(horizontal: false, vertical: true)
        .onPreferenceChange(CompactCellHeightsKey.self) { heights in
            cellHeights = heights
            reportSize(heights)
        }
        .onChange(of: layout) { _, _ in reportSize(cellHeights) }
        .onChange(of: hasNotch) { _, _ in reportSize(cellHeights) }
        .onChange(of: bandHeight) { _, _ in reportSize(cellHeights) }
        .onChange(of: activeWidth) { _, _ in reportSize(cellHeights) }
    }

    /// 1 个平台拆成两项指标，2 个平台左右各一张卡片；更多平台在刘海下方。
    private var usesNotchWings: Bool {
        hasNotch && (snapshots.count == 2
                     || (snapshots.count == 1 && (snapshots.first?.compactMetrics.count ?? 0) <= 2))
    }

    private var belowNotchContent: some View {
        VStack(spacing: 0) {
            if hasNotch {
                if usesNotchWings { Color.clear.frame(height: bandHeight) }
                else { notchRow.opacity(layoutProgress) }
            }
            platformLayout {
                ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                    compactCell(snapshot)
                        .overlay(alignment: layout == .horizontal ? .leading : .top) {
                            if index > 0 {
                                Rectangle().fill(palette.foreground.opacity(0.07))
                                    .frame(width: layout == .horizontal ? 1 : nil,
                                           height: layout == .vertical ? 1 : nil)
                            }
                        }
                }
            }
        }
        .frame(width: displayedWidth)
    }

    private var wingHeight: CGFloat {
        snapshots.count == 1 ? max(bandHeight, 32)
            : max(bandHeight, naturalCellHeights.max() ?? 55)
    }

    private var naturalCellHeights: [CGFloat] {
        snapshots.map { cellHeights[$0.id] ?? 55 }
    }

    private var displayedBarHeight: CGFloat {
        let vertical = naturalCellHeights.reduce(0, +) + bandHeight
        return vertical + (wingHeight - vertical) * layoutProgress
    }

    private var notchWings: some View {
        let width = max(0, (displayedWidth - notchWidth) / 2)
        return HStack(spacing: 0) {
            wing(at: 0)
                .frame(width: width, height: wingHeight)
                .clipped()
            Color.clear.frame(width: notchWidth, height: wingHeight)
            wing(at: 1)
                .frame(width: width, height: wingHeight)
                .clipped()
        }
        .frame(width: displayedWidth, height: wingHeight)
    }

    @ViewBuilder private func wing(at index: Int) -> some View {
        if snapshots.count == 1, let snapshot = snapshots.first {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(snapshot.compactMetrics[safe: index]?.label ?? "")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.foreground.opacity(0.58))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let metric = snapshot.compactMetrics[safe: index] {
                    metricValue(metric)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
        } else if let snapshot = snapshots[safe: index] {
            compactCell(snapshot, measuresHeight: false)
        }
    }

    private var layoutProgress: CGFloat { min(1, max(0, currentProgress ?? (layout == .horizontal ? 1 : 0))) }
    private var platformLayout: IslandCompactFlowLayout {
        IslandCompactFlowLayout(width: displayedWidth, horizontalProgress: layoutProgress)
    }

    private func reportSize(_ heights: [String: CGFloat]) {
        let selected = snapshots.compactMap { heights[$0.id] }
        guard selected.count == snapshots.count, !selected.isEmpty else { return }
        let below = (layout == .horizontal ? (selected.max() ?? 0) : selected.reduce(0, +))
            + (hasNotch ? bandHeight : 0)
        let height = usesNotchWings && layout == .horizontal ? wingHeight : below
        onContentSizeChange(layout, CGSize(width: activeWidth, height: height))
    }

    private var activeWidth: CGFloat { layout == .horizontal ? horizontalWidth : verticalWidth }

    private var displayedWidth: CGFloat { currentWidth ?? activeWidth }

    private var notchRow: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.foreground.opacity(0.5))
                .lineLimit(1)
                .padding(.leading, 14)
                .frame(width: max(0, (displayedWidth - notchWidth) / 2), alignment: .leading)
            Color.clear.frame(width: notchWidth, height: bandHeight)
            Color.clear.frame(width: max(0, (displayedWidth - notchWidth) / 2))
        }
        .frame(height: bandHeight)
    }

    // MARK: - 共用

    private func metricValue(_ metric: CompactMetric) -> some View {
        HStack(spacing: 6) {
            Text(metric.value).fontWeight(.semibold).foregroundStyle(palette.foreground)
            if let reset = metric.resetAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(metric.resetText(at: context.date) ?? "")
                        .font(.system(size: 8.5)).foregroundStyle(palette.foreground.opacity(0.5))
                }.help("重置时间：" + OfficialResetAnnouncement.beijingDate(reset))
            }
        }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.72)
    }

    private func compactCell(_ snapshot: PlatformSnapshot, measuresHeight: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.title + (snapshot.dataFreshness.isCached ? " · 缓存" : ""))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(snapshot.dataFreshness.isWarning ? Color.orange : palette.accent)
                .help(snapshot.dataFreshness.detail)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            ForEach(snapshot.compactMetrics) { metric in
                HStack(spacing: 4) {
                    Text(metric.label)
                        .foregroundStyle(palette.foreground.opacity(0.58))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    metricValue(metric).layoutPriority(1)
                }
                .font(.system(size: 9, design: .rounded))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if measuresHeight {
                GeometryReader { proxy in
                    Color.clear.preference(key: CompactCellHeightsKey.self,
                                           value: [snapshot.id: proxy.size.height])
                }
            }
        }
    }

    private var title: String {
        snapshots.count == 1 ? (snapshots.first?.platform.title ?? "") : "用量统计"
    }
}
