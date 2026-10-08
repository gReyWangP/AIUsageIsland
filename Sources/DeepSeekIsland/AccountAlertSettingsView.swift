import SwiftUI

struct AccountAlertSettingsView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: IslandSettings
    @ObservedObject var alerts: UsageAlertsController
    @State private var selectedAccount: AccountReference?
    private var account: AccountReference? {
        if let selectedAccount, model.savedAccounts.contains(selectedAccount) { return selectedAccount }
        return model.orderedSavedAccounts.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("提醒账号", selection: Binding(get: { account }, set: { selectedAccount = $0 })) {
                ForEach(model.orderedSavedAccounts) { account in Text(model.accountLabel(account)).tag(Optional(account)) }
                if model.savedAccounts.isEmpty { Text("尚未添加账号").tag(nil as AccountReference?) }
            }.disabled(model.savedAccounts.isEmpty)
            if let account {
                Toggle("为这个账号开启额度提醒", isOn: Binding(get: {
                    settings.reminderPolicy(for: account, model: model).enabled
                }, set: { enabled in Task { await alerts.setAccountEnabled(account, enabled: enabled) } }))
                    .disabled(alerts.changing)
                if settings.reminderPolicy(for: account, model: model).enabled {
                    Toggle("低余量提醒", isOn: policyBinding(account, \.lowEnabled))
                    if account.platform != .deepSeek { Toggle("额度实际恢复后提醒", isOn: policyBinding(account, \.recoveryEnabled)) }
                    DisclosureGroup("高级提醒规则") {
                        VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.accountRuntime(for: account).capabilities.availableMetrics) { metric in
                        Toggle(metric == .deepSeekBalance ? "人民币余额" : metric.windowLabel + "窗口", isOn: Binding(get: {
                            settings.reminderPolicy(for: account, model: model).metrics.contains(metric)
                        }, set: { selected in
                            var policy = settings.reminderPolicy(for: account, model: model)
                            if selected { policy.metrics.insert(metric) } else { policy.metrics.remove(metric) }
                            settings.setReminderPolicy(policy, for: account)
                        })).disabled(!model.accountRuntime(for: account).capabilities.metric(metric).canConfigureAlerts)
                        if let explanation = model.accountRuntime(for: account).capabilities.metric(metric).explanation {
                            Text(metric.windowLabel + "：" + explanation).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    AccountAlertThresholdView(model: model, settings: settings, account: account).id(account.id)
                        }.padding(.top, 8)
                    }
                }
                Text("设置仅作用于所选账号；账号改名或切换显示不会改变提醒。")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !settings.alertsEnabled { Text("额度提醒总开关已关闭。开启这个账号的提醒时会申请通知权限并恢复总开关。")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }.onAppear { settings.migrateAccountReminders(model) }
    }
    private func policyBinding(_ account: AccountReference, _ keyPath: WritableKeyPath<AccountAlertPolicy, Bool>) -> Binding<Bool> {
        Binding(get: { settings.reminderPolicy(for: account, model: model)[keyPath: keyPath] }, set: {
            var policy = settings.reminderPolicy(for: account, model: model)
            policy[keyPath: keyPath] = $0; settings.setReminderPolicy(policy, for: account)
        })
    }
}

private struct AccountAlertThresholdView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: IslandSettings
    let account: AccountReference
    @State private var metric: UsageMetric?
    @State private var warning: Double = 20
    @State private var critical: Double = 10
    @State private var error: String?
    private var selectedMetric: UsageMetric { model.accountRuntime(for: account).capabilities.alertMetric(preferred: metric) }
    var body: some View {
        DisclosureGroup("自定义通知阈值") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("指标", selection: Binding(get: { selectedMetric }, set: { metric = $0; load() })) {
                    ForEach(model.accountRuntime(for: account).capabilities.availableMetrics) { metric in
                        Text((metric == .deepSeekBalance ? "剩余余额" : metric.windowLabel + "剩余额度") + model.accountRuntime(for: account).capabilities.metric(metric).suffix).tag(metric)
                            .disabled(!model.accountRuntime(for: account).capabilities.metric(metric).canConfigureAlerts)
                    }
                }
                HStack {
                    Text("偏低"); TextField("偏低", value: $warning, format: .number).frame(width: 55)
                    Text("严重"); TextField("严重", value: $critical, format: .number).frame(width: 55)
                    Text(account.platform == .deepSeek ? "元" : "%")
                }
                HStack {
                    Button("保存阈值") {
                        do {
                            let threshold = try AlertThresholds.make(warning: warning, critical: critical, metric: selectedMetric)
                            var policy = settings.reminderPolicy(for: account, model: model)
                            policy.thresholds[selectedMetric] = threshold; settings.setReminderPolicy(policy, for: account); error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                    Button("恢复默认") {
                        var policy = settings.reminderPolicy(for: account, model: model)
                        policy.thresholds.removeValue(forKey: selectedMetric); settings.setReminderPolicy(policy, for: account); load()
                    }
                }
                Text("仅改变这个账号的通知判断，图标颜色沿用原标准。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }.padding(.top, 6)
        }.disabled(!model.accountRuntime(for: account).capabilities.metric(selectedMetric).canConfigureAlerts)
        .onAppear { load() }.onChange(of: selectedMetric) { load() }
    }
    private func load() {
        let value = settings.reminderPolicy(for: account, model: model).thresholds(for: selectedMetric)
        warning = value.warning; critical = value.critical; error = nil
    }
}
