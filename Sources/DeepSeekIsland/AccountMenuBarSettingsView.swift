import SwiftUI

struct AccountMenuBarSettingsView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: IslandSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("显示入口与状态栏账号").fontWeight(.semibold)
            Toggle("顶部中央移入显示", isOn: $settings.centralHoverEnabled).toggleStyle(SettingsToggleStyle(switchControl: true))
            Toggle("显示状态栏图标", isOn: $settings.showsMenuBarItem).toggleStyle(SettingsToggleStyle(switchControl: true))
            Toggle("状态栏移入显示", isOn: $settings.menuBarHoverEnabled)
                .toggleStyle(SettingsToggleStyle(switchControl: true)).disabled(!settings.showsMenuBarItem)
            if !settings.centralHoverEnabled && !settings.showsMenuBarItem {
                Text("显示入口均已关闭。重新打开应用可进入设置，也可使用已有快捷键。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if settings.showsMenuBarItem {
                Picker("显示账号", selection: Binding<AccountReference?>(get: {
                    if let account = settings.menuBarAccount, model.savedAccounts.contains(account) { return account }
                    let fallback = model.menuBarAccount(for: settings.menuBarMetric.platform)
                    return model.savedAccounts.contains(fallback) ? fallback : model.orderedSavedAccounts.first
                }, set: { settings.menuBarAccount = $0 })) {
                    ForEach(model.orderedSavedAccounts) { account in
                        let source = model.accountRuntime(for: account)
                        let ready = source.hasConnectedAccount(for: account.platform) && source.hasLoadedAccountData(for: account.platform)
                        Text(model.accountLabel(account) + (ready ? "" : "（待登录或更新）"))
                            .tag(Optional(account)).disabled(!ready)
                    }
                    if model.savedAccounts.isEmpty { Text("尚未添加账号").tag(nil as AccountReference?) }
                }.disabled(model.savedAccounts.isEmpty)
            }
            Text("顶部只显示一个图标；停留预览，点击保持展开，右键打开快捷菜单。额度窗口和图标样式在“外观”的高级外观中调整。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 8)
    }
}
