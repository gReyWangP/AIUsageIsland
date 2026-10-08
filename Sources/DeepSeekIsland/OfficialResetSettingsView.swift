import AppKit
import SwiftUI

struct OfficialResetSettingsView: View {
    @ObservedObject var settings: IslandSettings
    @ObservedObject var alerts: UsageAlertsController
    @ObservedObject var monitor: OfficialResetMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex 重置公告").font(.headline)
            Toggle("关注官方重置公告并通知我", isOn: $settings.officialResetAlertsEnabled)
            Text("默认开启；没有付费账号也可关闭。无需登录 X，每 15 分钟检查一次。公告由第三方整理，不代表当前账号已恢复；账号实际恢复仍使用额度恢复提醒。")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if settings.officialResetAlertsEnabled {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 5) {
                        if let event = monitor.latest {
                            Text(event.resetType == "banked" ? "重置券发放动态（需要手动使用）" : "公开重置公告")
                                .font(.system(size: 10, weight: .medium))
                            Text(event.timeDescription).font(.footnote).fixedSize(horizontal: false, vertical: true)
                            if event.phase == .scheduled, let end = event.latestExpectedAt, context.date >= end {
                                Text("预告时间已到，等待确认；请刷新账号检查实际额度。")
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                            HStack {
                                Button("查看 Tibo 原帖") { NSWorkspace.shared.open(event.sourceURL) }.buttonStyle(.link)
                                Spacer()
                                if event.phase == .scheduled && event.latestExpectedAt.map({ $0 > context.date }) == true {
                                    Button("到时提醒我") { alerts.resetReminders.present(event) }
                                }
                            }
                        } else {
                            Text(monitor.checking ? "正在检查公开公告…" : "暂无可确认的近期公告")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let date = monitor.lastChecked {
                    Text("上次检查：" + date.formatted(.dateTime.month().day().hour().minute()))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = monitor.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                HStack {
                    Button(monitor.checking ? "检查中…" : "检查公告") { Task { await monitor.check(manual: true) } }
                        .disabled(monitor.checking)
                    Button("允许系统通知") { Task { await alerts.requestOfficialPermission() } }
                    Spacer()
                    Link("来源：Codex Resets", destination: URL(string: "https://codex-resets.com")!)
                }.font(.footnote)
                Text("自动公告提醒共用提醒时段及“今天暂不提醒”；主动预约按确认的时间提醒。首次发现新公告时申请系统通知权限。")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ResetReminderStatusView(controller: alerts.resetReminders, latest: monitor.latest)
        }
    }
}
