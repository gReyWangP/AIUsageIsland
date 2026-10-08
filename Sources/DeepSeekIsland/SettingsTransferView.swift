import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsTransferView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: IslandSettings
    @State private var preview: SettingsArchive?
    @State private var message: String?
    @State private var error = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("导出设置…") { export() }
                Button("导入设置…") { load() }
            }
            Text("导出外观、快捷键、账号显示和提醒偏好，不包含 Token、Cookie、登录状态或系统权限。账号名称会包含在文件中。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message { Text(message).font(.system(size: 10)).foregroundStyle(error ? .orange : .secondary) }
        }.sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview {
                SettingsImportPreview(archive: preview, model: model, settings: settings) { message = "设置已导入"; error = false; self.preview = nil }
            }
        }
    }
    private func export() {
        do {
            let data = try SettingsArchive.capture(model: model, settings: settings).encoded()
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "AIUsageIsland-settings.json"
            let complete: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                do { try data.write(to: url, options: .atomic); message = "设置已导出"; error = false }
                catch { message = "无法保存配置文件：\(error.localizedDescription)"; self.error = true }
            }
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: complete) }
            else { panel.begin(completionHandler: complete) }
        } catch { message = error.localizedDescription; self.error = true }
    }
    private func load() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1_000_000 else { throw ConfigurationError(message: "配置文件过大。") }
                preview = try SettingsArchive.decode(Data(contentsOf: url)); message = nil
            } catch { message = "配置文件无法导入：\(error.localizedDescription)"; self.error = true }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }
}

private struct SettingsImportPreview: View {
    let archive: SettingsArchive
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: IslandSettings
    let onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var groups: Set<ImportGroup> = [.appearance, .controls]
    @State private var mapping: [Int: AccountReference] = [:]
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("预览导入设置").font(.title3).fontWeight(.semibold)
            Text("\(archive.accounts.count) 个账号配置 · \(archive.visible.count) 个显示位 · \(archive.presets.count) 个组合")
            ForEach(ImportGroup.allCases, id: \.self) { group in
                Toggle(group.title, isOn: Binding(get: { groups.contains(group) }, set: { if $0 { groups.insert(group) } else { groups.remove(group) } }))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if groups.contains(.accounts) {
                        Text("请逐项对应同平台的本机账号。名称不会自动匹配；同名组合将被替换。尚无账号时，先取消导入并在账号页登录。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(archive.accounts, id: \.index) { account in
                            Picker(account.label + " · " + account.platform.title, selection: Binding<AccountReference?>(get: { mapping[account.index] }, set: { mapping[account.index] = $0 })) {
                                Text("请选择本机账号").tag(nil as AccountReference?)
                                ForEach(model.orderedSavedAccounts.filter { $0.platform == account.platform }) { local in
                                    Text(model.accountLabel(local)).tag(Optional(local))
                                }
                            }
                        }
                    }
                    Text("导入不会改变登录凭据、系统通知权限、登录项或提醒总开关；请在本机检查快捷键是否可用。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.orange) }
                }
            }
            HStack {
                Button("取消") { dismiss() }; Spacer()
                Button("应用所选配置") {
                    do { try archive.apply(model: model, settings: settings, mapping: mapping, groups: groups); onApplied() }
                    catch { self.error = error.localizedDescription }
                }.disabled(groups.isEmpty)
            }
        }.padding(22).frame(width: 520, height: 470)
    }
}
