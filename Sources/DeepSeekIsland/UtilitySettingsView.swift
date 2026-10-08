import AppKit
import SwiftUI

@MainActor
final class DailyUtilities {
    let login: LoginLaunchController
    let alerts: UsageAlertsController
    let shortcuts: GlobalShortcutController
    let reminderWindow: ResetReminderWindowController
    let quotaReminderWindow: QuotaReminderWindowController
    init(model: IslandModel, settings: IslandSettings, onOpen: @escaping () -> Void, perform: @escaping (ShortcutAction) -> Void) {
        login = LoginLaunchController()
        alerts = UsageAlertsController(model: model, settings: settings, onOpen: onOpen)
        shortcuts = GlobalShortcutController(settings: settings, perform: perform)
        let planner = ResetReminderWindowController(settings: settings, controller: alerts.resetReminders)
        reminderWindow = planner
        alerts.resetReminders.onPresent = { [weak planner] event in planner?.show(event) }
        model.officialResetCard.onReserve = { [weak alerts] event in alerts?.resetReminders.present(event) }
        let personalPlanner = QuotaReminderWindowController(settings: settings, controller: alerts.quotaReminders)
        quotaReminderWindow = personalPlanner
        alerts.quotaReminders.onPresent = { [weak personalPlanner] plan in personalPlanner?.show(plan) }
        alerts.quotaReminders.isCurrent = { [weak model] plan in
            guard let model else { return false }
            guard let account = model.accountReference(platform: plan.metric.platform, notificationKey: plan.accountKey) else { return false }
            let source = model.accountRuntime(for: account)
            return source.freshness(for: plan.metric.platform).allowsAlerts
                && source.quotaResetDate(for: plan.metric) == plan.resetAt
        }
        model.onReserveQuotaReset = { [weak alerts] metric in alerts?.reserveQuotaReminder(metric) }
        model.onReserveAccountQuotaReset = { [weak alerts] account, metric in alerts?.reserveQuotaReminder(metric, account: account) }
        model.onAccountContextChanged = { [weak alerts] platform in alerts?.accountContextChanged(platform) }
        alerts.officialResets.start()
    }
}

struct UtilitySettingsView: View {
    var model: IslandModel? = nil
    @ObservedObject var settings: IslandSettings
    @ObservedObject var login: LoginLaunchController
    @ObservedObject var alerts: UsageAlertsController
    @ObservedObject var shortcuts: GlobalShortcutController
    @Environment(\.colorScheme) private var colorScheme
    private var palette: IslandPalette { IslandPalette(scheme: settings.appearanceMode.colorScheme ?? colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DisclosureGroup("启动与快捷键") {
                    VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    title("启动")
                    Toggle("登录 Mac 时自动启动", isOn: Binding(get: { login.isEnabled }, set: { enabled in Task { await login.setEnabled(enabled) } }))
                        .disabled(login.changing)
                    note(login.statusText)
                    if let error = login.error { warning(error) }
                    Button("打开系统登录项设置") { login.openSystemSettings() }.buttonStyle(.link)
                }
                        divider
                VStack(alignment: .leading, spacing: 9) {
                    title("全局快捷键")
                    ForEach(ShortcutAction.allCases) { action in
                        HStack {
                            Text(action.title)
                            Spacer()
                            ShortcutRecorder(shortcut: settings.shortcutBindings[action], onStart: { shortcuts.suspend() },
                                onCapture: { shortcuts.set($0, for: action) }, onStop: { shortcuts.restore() })
                                .frame(width: 157, height: 24)
                            Button { shortcuts.set(nil, for: action) } label: { Image(systemName: "xmark.circle").frame(minWidth: 24, minHeight: 24) }
                                .buttonStyle(.borderless).disabled(settings.shortcutBindings[action] == nil)
                                .help("清除\(action.title)的快捷键")
                        }
                    }
                    note("点击录制，按下含 ⌘、⌃ 或 ⌥ 的组合键。Esc 取消；清除后立即停用。被占用的组合键会提示，原设置会保留。")
                    if let error = shortcuts.error { warning(error) }
                }
                    }.padding(.top,8)
                }.settingsCard()
                if let model {
                    ProductToolsSettingsView(model:model,settings:settings).settingsCard()
                    SupportSettingsView().settingsCard()
                }
            }.padding(.trailing,4)
        }
        .font(.callout).foregroundStyle(palette.foreground.opacity(0.85))
        .toggleStyle(SettingsToggleStyle())
        .onAppear { login.refreshStatus(); Task { await alerts.updatePermission() } }
    }
    private func title(_ text: String) -> some View { Text(text).font(.system(size: 11, weight: .semibold)) }
    private func note(_ text: String) -> some View { Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func warning(_ text: String) -> some View { Text(text).font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
    private var divider: some View { Rectangle().fill(palette.foreground.opacity(0.08)).frame(height: 1) }
}
