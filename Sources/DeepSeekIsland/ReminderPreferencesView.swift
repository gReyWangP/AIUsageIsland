import AppKit
import SwiftUI

struct ReminderPreferencesView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: IslandSettings
    @ObservedObject var alerts: UsageAlertsController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    Text("提醒状态").font(.headline)
                    Toggle("自动额度提醒", isOn: Binding(get: { settings.alertsEnabled }, set: { enabled in
                        Task { await alerts.setEnabled(enabled) }
                    })).disabled(alerts.changing)
                    Text(!settings.alertsEnabled ? "自动额度提醒已暂停，账号规则仍保留。"
                         : settings.allowsReminder(at: context.date) ? "自动额度提醒已开启，按各账号规则判断。"
                         : settings.alertsSnoozedUntil.map({ $0 > context.date }) == true ? "今天暂不提醒生效中。" : "当前不在自动提醒时段。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(alerts.permissionText).font(.footnote).foregroundStyle(.secondary)
                    Text("公告订阅：" + (settings.officialResetAlertsEnabled ? "已开启" : "已关闭") + "；暂停额度提醒不会关闭公告订阅。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("已确认的到点预约按预约时间执行，不受自动提醒暂停或时段限制；移除账号、周期变化或手动取消可能使预约失效。")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let error = alerts.lastError { Text(error).foregroundStyle(.orange) }
                }.settingsCard()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("账号额度提醒").font(.headline)
                        AccountAlertSettingsView(model: model, settings: settings, alerts: alerts)
                        Text("实际恢复以平台最新数据为准；无限或不适用的指标不能开启数值提醒。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.settingsCard()
                    DisclosureGroup("Bark 手机推送") {
                        BarkPushSettingsView(settings: settings, service: alerts.barkPush, monitor: alerts.officialResets).padding(.top, 8)
                    }.settingsCard()
                    DisclosureGroup("高级时段与暂停") {
                        VStack(alignment: .leading, spacing: 10) {
                            ReminderSettingsView(settings: settings, alerts: alerts)
                            Button("打开系统通知设置") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                            }
                        }.padding(.top, 8)
                    }.settingsCard()
                    DisclosureGroup("Codex 重置公告") {
                        OfficialResetSettingsView(settings: settings, alerts: alerts, monitor: alerts.officialResets).padding(.top, 8)
                    }.settingsCard()
                    DisclosureGroup("高级预约与提醒事项") {
                        VStack(alignment: .leading, spacing: 10) {
                            QuotaReminderSettingsView(controller: alerts.quotaReminders)
                            ResetReminderStatusView(controller: alerts.resetReminders, latest: alerts.officialResets.latest)
                            Text("主动预约独立于自动提醒；只在选择相应通知或提醒事项时申请所需权限。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }.settingsCard()
                }.padding(.trailing, 4)
            }
        }.font(.callout).toggleStyle(SettingsToggleStyle())
        .task { await alerts.updatePermission() }
    }
}
