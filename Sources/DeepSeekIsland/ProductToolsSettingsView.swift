import AppKit
import SwiftUI

struct ProductToolsSettingsView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: IslandSettings
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("诊断与配置").fontWeight(.semibold)
            Button(copied ? "已复制诊断信息" : "复制诊断信息") {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(DiagnosticReport.render(model: model), forType: .string)
            }
            SettingsTransferView(model: model, settings: settings)
            Text("仅包含匿名账号序号、平台、更新时间和错误类别，不包含登录凭据或账号名称。")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
