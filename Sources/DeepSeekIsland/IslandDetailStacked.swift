import SwiftUI

/// 纵向详情：每个平台一张全宽卡片，从上到下叠加。
///
/// 卡片结构与横向完全一致（平台名 → hero → 指标 → 账号），
/// 唯一的差别是**指标那一行从竖排三行变成横排一行**——因为这里是全宽，
/// 竖排会把每一行拉出几百 pt 的空档。说明文字移到悬停提示以节省高度。
struct IslandDetailStacked: View {
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
    var onAccountDisconnect: ((String) -> Void)? = nil
    var onAccountSignIn: ((String) -> Void)? = nil
    var onAccountRefresh: ((String) -> Void)? = nil
    var onAccountReserveQuotaReset: ((String, DetailMetricRow) -> Void)? = nil

    var onAccountAnalysis: (String) -> Void = { _ in }

    /// hero 区固定宽度，保证各平台的指标列左边界对齐。
    private static let heroWidth: CGFloat = 130

    var body: some View {
        VStack(spacing: 12) {
            ForEach(snapshots) { card($0) }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: DetailSizeKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(DetailSizeKey.self) { onContentHeightChange(.stacked, $0) }
    }

    private func card(_ snapshot: PlatformSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(snapshot.title)
                .islandMatchedPosition("title-\(snapshot.id)", in: motionNamespace)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Spacer(minLength: 0)
                if snapshot.platform == .chatGPT, let officialReset {
                    OfficialResetDetailCard(content: officialReset, lastChecked: officialResetLastChecked,
                        error: officialResetError, onReserve: onReserveOfficialReset, onPopoverChange: onOfficialPopoverChange)
                        .frame(width: 230)
                }
                RefreshButton(snapshot: snapshot) {
                    if let onAccountRefresh { onAccountRefresh(snapshot.id) } else { onRefresh(snapshot.platform) }
                }
            }

            .notificationFocus(focus?.matches(snapshot, row: "platform") == true)
            .id("\(snapshot.id)-platform")

            HStack(alignment: .center, spacing: 8) {
                hero(snapshot)
                ForEach(snapshot.rows.map { (id: "\(snapshot.id)-\($0.id)", row: $0) }, id: \.id) { item in
                    metricCell(item.row, snapshot: snapshot)
                }
            }

            HStack(spacing: 6) {
                AccountRow(snapshot: snapshot,
                           onSignIn: {
                               if let onAccountSignIn { onAccountSignIn(snapshot.id) } else { onSignIn(snapshot.platform) }
                           },
                           onDisconnect: {
                               if let onAccountDisconnect { onAccountDisconnect(snapshot.id) } else { onDisconnect(snapshot.platform) }
                           },
                           trailing: snapshot.refreshText)
                    .help(snapshot.dataFreshness.detail)
                UsageOverviewRow(overview:snapshot.analysisOverview) { onAccountAnalysis(snapshot.id) }.frame(width:200)
            }

            if !snapshot.isConnected {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.platform.signInHint)
                        .font(.system(size: 9))
                        .foregroundStyle(palette.foreground.opacity(0.4))
                    if let error = snapshot.error {
                        Text(error).font(.system(size: 9)).foregroundStyle(.orange)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if let error = snapshot.error {
                Text(error).font(.system(size: 9)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let warning = snapshot.warning {
                Text(warning).font(.system(size: 9)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DetailMetrics.cardPadding)
        .padding(.vertical, 8)
        .background(palette.foreground.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        // 说明移到这里：既不占高度，又不丢信息。
        .help(snapshot.note)
    }

    private func hero(_ snapshot: PlatformSnapshot) -> some View {
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
        .frame(width: Self.heroWidth, alignment: .leading)
        .notificationFocus(focus?.matches(snapshot, row: "hero") == true)
        .id("\(snapshot.id)-hero")
    }

    private func metricCell(_ row: DetailMetricRow, snapshot: PlatformSnapshot) -> some View {
        let platform = snapshot.platform
        return VStack(alignment: .leading, spacing: 2) {
            Text(row.label)
                .font(.system(size: 9))
                .foregroundStyle(palette.foreground.opacity(0.5))
                .lineLimit(1)
            if row.resetAt != nil {
                Button {
                    if let onAccountReserveQuotaReset { onAccountReserveQuotaReset(snapshot.id, row) }
                    else { onReserveQuotaReset(platform, row) }
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
                    .minimumScaleFactor(0.7)
            }
            if let detail = row.detail {
                Text(detail)
                    .font(.system(size: 8))
                    .monospacedDigit()
                    .foregroundStyle(palette.foreground.opacity(0.48))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .notificationFocus(focus?.matches(snapshot, row: row.id) == true)
        .id("\(snapshot.id)-\(row.id)")
    }
}
