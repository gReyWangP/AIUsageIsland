import Foundation

struct DisplayPreset: Codable, Identifiable {
    let id: UUID
    let name: String
    let accounts: [AccountReference]
    let compact: String
    let detail: String
}
struct ConfigurationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension IslandModel {
    var displayPresets: [DisplayPreset] {
        defaults.data(forKey: "displayPresetsV1").flatMap { try? JSONDecoder().decode([DisplayPreset].self, from: $0) } ?? []
    }
    func storeDisplayPresets(_ presets: [DisplayPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: "displayPresetsV1"); objectWillChange.send()
    }
    @discardableResult func saveDisplayPreset(name: String, settings: IslandSettings) throws -> DisplayPreset {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw ConfigurationError(message: "请输入 1～40 字的组合名称。") }
        guard displayPresets.count < 20 else { throw ConfigurationError(message: "最多保存 20 个显示组合。") }
        guard !displayPresets.contains(where: { $0.name == name }) else { throw ConfigurationError(message: "已有同名组合，请移除原组合后再保存。") }
        let preset = DisplayPreset(id: UUID(), name: name, accounts: visibleAccounts, compact: settings.compactLayout.rawValue, detail: settings.detailLayout.rawValue)
        storeDisplayPresets(displayPresets + [preset]); return preset
    }
    func applyDisplayPreset(_ preset: DisplayPreset, settings: IslandSettings) throws {
        guard preset.accounts.count <= 4, Set(preset.accounts).count == preset.accounts.count,
              preset.accounts.allSatisfy({ savedAccounts.contains($0) }),
              let compact = CompactLayout(rawValue: preset.compact), let detail = DetailLayout(rawValue: preset.detail) else {
            throw ConfigurationError(message: "组合包含已移除的账号或无效布局，请重新保存组合；当前显示未改变。")
        }
        displaySelection = AccountDisplaySelection(accounts: preset.accounts); persistDisplaySelection()
        settings.compactLayout = compact; settings.detailLayout = detail
        reconcileAccountRuntimes(); onAccountsChanged?()
    }
    func removeDisplayPreset(_ id: UUID) { storeDisplayPresets(displayPresets.filter { $0.id != id }) }
}
