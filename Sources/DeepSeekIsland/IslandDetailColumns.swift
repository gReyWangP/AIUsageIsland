import SwiftUI

/// 详情页的尺寸规则。集中一处，排版与面板都用它，避免各算各的。
enum DetailMetrics {
    /// 详情左右内边距。
    static let horizontalPadding: CGFloat = 19
    /// 两列之间的间距。
    static let columnSpacing: CGFloat = 12
    /// 行间距。整块详情的纵向节奏由它控制。
    static let rowSpacing: CGFloat = 8
    /// 列内边距：行卡片与列容器背景之间的呼吸。
    static let columnPadding: CGFloat = 10
    /// 行卡片的内边距：文字与卡片边框之间的距离。
    static let cardPadding: CGFloat = 10
    /// 单列可读下限。实测 190 pt 时账号行仍会被截，220 pt 才完整。
    static let minColumnWidth: CGFloat = 220
    /// 单平台沿用的窄版宽度。
    static let singleColumnPanelWidth: CGFloat = 360
    /// 多平台的最小面板宽度（= 现在双平台的样子）。
    static let multiColumnMinPanelWidth: CGFloat = 565
    /// 面板最多占屏幕宽度的比例，超出就压缩列宽。
    static let maxScreenWidthRatio: CGFloat = 0.8

    /// 并列栏排版的面板宽度。
    ///
    /// `1 平台沿用 360；2 平台维持现状 565；3 个及以上按 N × 220 计算`——
    /// 面板宽度与悬浮条的 565 解耦，两者本来就不必一样宽。
    static func panelWidth(platformCount: Int, screenWidth: CGFloat) -> CGFloat {
        guard platformCount > 1 else {
            return min(singleColumnPanelWidth, screenWidth)
        }
        let needed = CGFloat(platformCount) * minColumnWidth
            + CGFloat(platformCount - 1) * columnSpacing
            + 2 * horizontalPadding
        let cap = screenWidth * maxScreenWidthRatio
        return max(multiColumnMinPanelWidth, min(needed, cap))
    }

    /// 给定面板宽度与平台数，每列有多宽。
    static func columnWidth(panelWidth: CGFloat, platformCount: Int) -> CGFloat {
        guard platformCount > 0 else { return panelWidth }
        let content = panelWidth - 2 * horizontalPadding
        return (content - CGFloat(platformCount - 1) * columnSpacing) / CGFloat(platformCount)
    }
}

/// 横向详情：多个平台左右并排，放进**同一个** `Grid`。
///
/// 两列必须在同一个 Grid 里——各自用独立 VStack 的话行高只由自己决定，
/// 一侧多一行文案就会让分隔线和账号区错位。放进同一个 Grid 后，
/// 每行高度取所有列的最大值，基线天然对齐。
struct IslandDetailColumns: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: IslandPalette { IslandPalette(scheme: colorScheme) }
    let snapshots: [PlatformSnapshot]
    var motionNamespace: Namespace.ID? = nil
    var focus: DetailFocusTarget? = nil
    var officialReset: OfficialResetCardContent? = nil
    var officialResetLastChecked: Date? = nil
    var officialResetError: String? = nil
    var onReserveOfficialReset: (OfficialResetAnnouncement) -> Void = { _ in }
    var onOfficialPopoverChange: (Bool) -> Void = { _ in }
    /// 上报实测尺寸，并带上自己是哪个排版（原因同 `IslandCompactBar`）。
    var onContentHeightChange: (DetailLayout, CGSize) -> Void = { _, _ in }
    var onDisconnect: (UsagePlatform) -> Void = { _ in }
    var onSignIn: (UsagePlatform) -> Void = { _ in }
    var onReserveQuotaReset: (UsagePlatform, DetailMetricRow) -> Void = { _, _ in }
    var onRefresh: (UsagePlatform) -> Void = { _ in }
    /// 说明行是否保留。纵向堆叠时为了省高度会移到悬停提示。
    var showsNote: Bool = true
    var onAccountDisconnect: ((String) -> Void)? = nil
    var onAccountSignIn: ((String) -> Void)? = nil
    var onAccountRefresh: ((String) -> Void)? = nil
    var onAccountReserveQuotaReset: ((String, DetailMetricRow) -> Void)? = nil

    var onAccountAnalysis: (String) -> Void = { _ in }

    private var rowCount: Int {
        snapshots.map(\.rows.count).max() ?? 0
    }

    var body: some View {
        Grid(alignment: .leading,
             horizontalSpacing: DetailMetrics.columnSpacing,
             verticalSpacing: DetailMetrics.rowSpacing) {
            GridRow {
                ForEach(snapshots.map { (id: "\($0.id)-platform", snapshot: $0) }, id: \.id) { columnHeader($0.snapshot) }
            }
            GridRow {
                ForEach(snapshots.map { (id: "\($0.id)-hero", snapshot: $0) }, id: \.id) { heroCell($0.snapshot) }
            }
            ForEach(0..<rowCount, id: \.self) { index in
                GridRow {
                    ForEach(snapshots.map { snapshot in
                        (id: "\(snapshot.id)-\(index < snapshot.rows.count ? snapshot.rows[index].id : "empty-\(index)")", snapshot: snapshot)
                    }, id: \.id) { metricCell($0.snapshot, at: index) }
                }
            }
            GridRow { ForEach(snapshots) { snapshot in
                UsageOverviewRow(overview:snapshot.analysisOverview) { onAccountAnalysis(snapshot.id) }.cellLayout()
            } }
            if showsNote {
                GridRow {
                    ForEach(snapshots) { noteCell($0) }
                }
            }
            GridRow {
                ForEach(snapshots) { refreshCell($0) }
            }
            GridRow {
                ForEach(snapshots) { _ in dividerCell }
            }
            GridRow {
                ForEach(snapshots) { accountCell($0) }
            }
        }
        .padding(.vertical, DetailMetrics.columnPadding)
        .background {
            // 每列一块等高的圆角底；HStack 等分，正好对齐 Grid 的列。
            HStack(spacing: DetailMetrics.columnSpacing) {
                ForEach(snapshots) { _ in
                    RoundedRectangle(cornerRadius: 10).fill(palette.foreground.opacity(0.045))
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: DetailSizeKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(DetailSizeKey.self) { onContentHeightChange(.columns, $0) }
    }

    // MARK: - 单元格

    private func columnHeader(_ snapshot: PlatformSnapshot) -> some View {
        HStack(spacing: 6) {
            Text(snapshot.title)
                .islandMatchedPosition("title-\(snapshot.id)", in: motionNamespace)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.accent)
            Spacer(minLength: 0)
            RefreshButton(snapshot: snapshot) {
                if let onAccountRefresh { onAccountRefresh(snapshot.id) } else { onRefresh(snapshot.platform) }
            }
        }
        .cellLayout()
        .notificationFocus(focus?.matches(snapshot, row: "platform") == true)
        .id("\(snapshot.id)-platform")
    }

    /// 头像行：标签 + 30pt 大数字。各平台结构完全一致——
    /// 任何一边多一个元素（比如进度条）都会让这一列变高，
    /// 底部对齐时把标签和数字整体顶高，两列就对不上了。
    private func heroCell(_ snapshot: PlatformSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.heroLabel)
                .font(.system(size: 10))
                .foregroundStyle(palette.foreground.opacity(0.52))
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(snapshot.heroValue)
                    .islandMatchedPosition("hero-\(snapshot.id)", in: motionNamespace)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let suffix = snapshot.heroSuffix {
                    Text(suffix)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.foreground.opacity(0.52))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cellLayout()
        .notificationFocus(focus?.matches(snapshot, row: "hero") == true)
        .id("\(snapshot.id)-hero")
    }

    private func metricCell(_ snapshot: PlatformSnapshot, at index: Int) -> some View {
        let row = snapshot.rows[safe: index]
        return HStack(spacing: 6) {
            if let row {
                Text(row.label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(palette.foreground.opacity(0.55))
                Spacer(minLength: 0)
                if row.resetAt != nil {
                    Button {
                        if let onAccountReserveQuotaReset { onAccountReserveQuotaReset(snapshot.id, row) }
                        else { onReserveQuotaReset(snapshot.platform, row) }
                    } label: {
                        ResetTimeView(row: row).foregroundStyle(palette.foreground)
                    }.buttonStyle(.plain).disabled(row.reservationMetric == nil || !row.resetFresh || (row.resetAt ?? .distantPast) <= .now)
                    .help("点击预约重置提醒；到点不代表额度已恢复。")
                } else {
                    Text(row.value)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                }
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(palette.foreground.opacity(0.5))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, DetailMetrics.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(palette.foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .cellLayout()
        .notificationFocus(row.map { focus?.matches(snapshot, row: $0.id) == true } ?? false)
        .id("\(snapshot.id)-\(row?.id ?? "empty")")
    }

    private func noteCell(_ snapshot: PlatformSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if snapshot.platform == .chatGPT, let officialReset {
                OfficialResetDetailCard(content: officialReset, lastChecked: officialResetLastChecked,
                    error: officialResetError, onReserve: onReserveOfficialReset, onPopoverChange: onOfficialPopoverChange)
            } else {
                Text(snapshot.note)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.foreground.opacity(0.44))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = snapshot.error {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 数据行与页脚之间留出比行间距更大的分隔。
        .padding(.top, 20)
        .cellLayout()
    }

    private func refreshCell(_ snapshot: PlatformSnapshot) -> some View {
        Text(snapshot.refreshText ?? "")
            .font(.system(size: 10))
            .foregroundStyle(snapshot.dataFreshness.isWarning ? Color.orange : palette.foreground.opacity(0.38))
            .help(snapshot.dataFreshness.detail)
            .cellLayout()
    }

    private var dividerCell: some View {
        Rectangle()
            .fill(palette.foreground.opacity(0.10))
            .frame(height: 1)
            .cellLayout()
    }

    private func accountCell(_ snapshot: PlatformSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AccountRow(snapshot: snapshot,
                       onSignIn: {
                           if let onAccountSignIn { onAccountSignIn(snapshot.id) } else { onSignIn(snapshot.platform) }
                       },
                       onDisconnect: {
                           if let onAccountDisconnect { onAccountDisconnect(snapshot.id) } else { onDisconnect(snapshot.platform) }
                       })
            if !snapshot.isConnected {
                Text(snapshot.platform.signInHint)
                    .font(.system(size: 9))
                    .foregroundStyle(palette.foreground.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = snapshot.error {
                Text(error).foregroundStyle(.orange).font(.system(size: 9))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let warning = snapshot.warning {
                Text(warning).foregroundStyle(.orange).font(.system(size: 9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cellLayout()
    }
}

/// 列内水平内边距 + 撑满列宽。所有单元格统一走这里，保证各列边界严格一致。
extension View {
    func cellLayout() -> some View {
        padding(.horizontal, DetailMetrics.columnPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 详情向上汇报自身实测尺寸用的 key。
///
/// 必须带上**宽度**：只报高度的话，宽度变了而高度没变时面板不会跟着改，
/// 就会出现「面板 360 宽、卡片 565 宽」这种内容被裁掉的情况。
struct DetailSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}


/// 平台标题行右侧的刷新按钮。
struct RefreshButton: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: IslandPalette { IslandPalette(scheme: colorScheme) }
    let snapshot: PlatformSnapshot
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise").font(.system(size: 10))
                .foregroundStyle(palette.foreground.opacity(0.55))
        }
        .buttonStyle(.plain)
        .disabled(!snapshot.isConnected)
        .help("刷新\(snapshot.title)")
    }
}

/// 账号行：头像 + 名称 + 登录／退出。
struct AccountRow: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: IslandPalette { IslandPalette(scheme: colorScheme) }
    let snapshot: PlatformSnapshot
    var onSignIn: () -> Void = {}
    let onDisconnect: () -> Void
    var trailing: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: snapshot.isConnected ? "person.crop.circle.fill" : "person.crop.circle")
            Text(snapshot.isSigningIn
                 ? "正在登录…"
                 : snapshot.isConnected ? (snapshot.accountName ?? "已登录") : "未登录")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing).font(.system(size: 9))
                    .foregroundStyle(palette.foreground.opacity(0.34))
            }
            if snapshot.isConnected {
                Button("移除账号", action: onDisconnect)
                    .help("移除「\(snapshot.title)」")
                    .accessibilityLabel("移除「\(snapshot.title)」")
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundStyle(palette.foreground.opacity(0.48))
            } else if !snapshot.isSigningIn {
                // 三个平台都靠它进门：之前这里只有「退出登录」，
                // 从选择页启用平台后就再没有登录入口了。
                Button("登录", action: onSignIn)
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundStyle(palette.accent)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(palette.foreground.opacity(0.7))
    }
}
