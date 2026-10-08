import SwiftUI

struct DisplayPresetSettingsView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: IslandSettings
    @State private var selected: UUID?
    @State private var name = ""
    @State private var message: String?
    var body: some View {
        DisclosureGroup("显示组合") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("已保存组合", selection: $selected) {
                    Text("选择组合").tag(nil as UUID?)
                    ForEach(model.displayPresets) { Text($0.name).tag(Optional($0.id)) }
                }
                HStack {
                    Button("应用组合") {
                        guard let preset = model.displayPresets.first(where: { $0.id == selected }) else { return }
                        do { try model.applyDisplayPreset(preset, settings: settings); message = "已应用“\(preset.name)”" }
                        catch { message = error.localizedDescription }
                    }.disabled(selected == nil)
                    Button("移除组合") { if let selected { model.removeDisplayPreset(selected) }; selected = nil }
                        .disabled(selected == nil)
                }
                HStack {
                    TextField("例如：工作、个人", text: $name)
                    Button("保存当前显示") {
                        do { selected = try model.saveDisplayPreset(name: name, settings: settings).id; name = ""; message = "组合已保存" }
                        catch { message = error.localizedDescription }
                    }
                }
                Text("保存账号选择、顺序及两种布局；切换组合不改变状态栏账号、提醒或登录。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message { Text(message).font(.system(size: 10)).foregroundStyle(.secondary) }
            }.padding(.top, 6)
        }
    }
}
