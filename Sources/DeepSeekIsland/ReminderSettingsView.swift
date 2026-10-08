import SwiftUI

struct ReminderSettingsView: View {
    @ObservedObject var settings: IslandSettings
    @ObservedObject var alerts: UsageAlertsController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.alertsEnabled && !settings.accountRemindersMigrated {
            HStack(spacing: 16) {
                Toggle("低余量提醒", isOn: $settings.lowAlertsEnabled)
                Toggle("额度恢复提醒", isOn: $settings.recoveryAlertsEnabled)
            }
            }
            Toggle("仅在指定时段提醒", isOn: $settings.alertsScheduleEnabled)
            if settings.alertsScheduleEnabled {
                HStack(spacing: 8) {
                    DatePicker("从", selection: timeBinding($settings.alertStartMinute), displayedComponents: .hourAndMinute)
                    DatePicker("至", selection: timeBinding($settings.alertEndMinute), displayedComponents: .hourAndMinute)
                }
                Text("按本地时间，可跨午夜；起止相同代表全天。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let until = settings.alertsSnoozedUntil, context.date < until {
                    HStack {
                        Text("已暂停至 " + until.formatted(.dateTime.month().day().hour().minute()))
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复提醒") { settings.alertsSnoozedUntil = nil }
                    }
                } else {
                    Button("今天暂不提醒") {
                        alerts.handleNotificationAction(UsageNotificationAction.snoozeToday, metric: nil)
                    }
                }
            }
            Text("静默期间继续更新数据，恢复提醒后不补发旧通知。通知中也可选择今天暂不提醒。")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!settings.alertsEnabled && !settings.officialResetAlertsEnabled)
    }
    private func timeBinding(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            let value = max(0, min(1439, minute.wrappedValue))
            return Calendar.current.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: .now) ?? .now
        }, set: { value in
            minute.wrappedValue = Calendar.current.component(.hour, from: value) * 60
                + Calendar.current.component(.minute, from: value)
        })
    }
}
