import SwiftUI

struct AppUpdateSettingsView: View {
    @ObservedObject var service: AppUpdateService
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("软件更新").font(.headline)
            HStack {
                Text("当前版本 " + IslandBrand.version).foregroundStyle(.secondary)
                Spacer()
                Button("检查更新", action: service.checkForUpdates)
                    .disabled(!service.canCheckForUpdates)
            }
            Toggle("自动检查更新", isOn: Binding(
                get: { service.automaticallyChecksForUpdates },
                set: { service.setAutomaticChecks($0) }))
            Text("默认关闭。开启后定期检查新版；下载和安装前会征求你的确认。关闭时仍可手动检查。")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
