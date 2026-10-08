import SwiftUI

struct AccountMenuBarSettingsView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: IslandSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("状态栏账号").fontWeight(.semibold)
            Toggle("显示状态栏图标", isOn: $settings.showsMenuBarItem).toggleStyle(SettingsToggleStyle(switchControl: true))
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
            Text("顶部只显示一个图标；额度窗口和图标样式在“外观与布局”中调整。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 8)
    }
}
