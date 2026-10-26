import Foundation

enum ImportGroup: String, CaseIterable { case appearance, controls, accounts
    var title: String { switch self { case .appearance: "外观与布局"; case .controls: "快捷键与提醒时段"; case .accounts: "账号显示、提醒与组合" } }
}
struct PortableAccount: Codable {
    let index: Int
    let platform: UsagePlatform
    let label: String
    let policy: AccountAlertPolicy
}
struct PortablePreset: Codable {
    let name: String
    let accounts: [Int]
    let compact: String
    let detail: String
}
struct PortableAppearance: Codable {
    let theme: String, background: String, compact: String, detail: String, progress: String, thickness: String
    let pausesFullscreen: Bool
    let compactMetrics: [String: Set<String>]
    var sideDockEnabled: Bool? = nil
    var sideDockOnLeft: Bool? = nil
    var sideDockAutoHide: Bool? = nil
    var sideDockY: Double? = nil
    var sideDockCurveDepth: Double? = nil
    var floatingStatus: Bool? = nil
    var floatingStatusAlwaysExpanded: Bool? = nil
}
struct PortableControls: Codable {
    let shortcuts: [ShortcutAction: KeyboardShortcut]
    let scheduled: Bool
    let startMinute: Int, endMinute: Int
}
struct SettingsArchive: Codable {
    var version: Int = 1
    let appearance: PortableAppearance
    let controls: PortableControls
    let accounts: [PortableAccount]
    let visible: [Int]
    let presets: [PortablePreset]
    let menuAccount: Int?
    let menuMetric: UsageMetric
    let showsMenu: Bool
    let autoFocus: Bool

    @MainActor static func capture(model: IslandModel, settings: IslandSettings) -> Self {
        let accounts = model.orderedSavedAccounts
        let indices = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($0.element, $0.offset) })
        return Self(appearance: .init(theme: settings.appearanceMode.rawValue, background: settings.backgroundEffect.rawValue,
            compact: settings.compactLayout.rawValue, detail: settings.detailLayout.rawValue,
            progress: settings.menuBarProgressStyle.rawValue, thickness: settings.menuBarRingThickness.rawValue,
            pausesFullscreen: settings.pausesHoverInFullscreen, compactMetrics: settings.compactMetricSelection,
            sideDockEnabled: settings.sideDockEnabled, sideDockOnLeft: settings.sideDockOnLeft, sideDockAutoHide: settings.sideDockAutoHide,
            sideDockY: settings.sideDockY, sideDockCurveDepth: settings.sideDockCurveDepth,
            floatingStatus: settings.floatingStatusEnabled, floatingStatusAlwaysExpanded: settings.floatingStatusAlwaysExpanded),
            controls: .init(shortcuts: settings.shortcutBindings, scheduled: settings.alertsScheduleEnabled,
                startMinute: settings.alertStartMinute, endMinute: settings.alertEndMinute),
            accounts: accounts.enumerated().map { .init(index: $0.offset, platform: $0.element.platform,
                label: model.accountLabel($0.element), policy: settings.reminderPolicy(for: $0.element, model: model)) },
            visible: model.visibleAccounts.compactMap { indices[$0] },
            presets: model.displayPresets.filter { $0.accounts.allSatisfy { indices[$0] != nil } }.map {
                .init(name: $0.name, accounts: $0.accounts.compactMap { indices[$0] }, compact: $0.compact, detail: $0.detail)
            }, menuAccount: settings.menuBarAccount.flatMap { indices[$0] }, menuMetric: settings.menuBarMetric,
            showsMenu: settings.showsMenuBarItem, autoFocus: settings.menuBarAutoFocusEnabled)
    }
    func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(self) }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_000_000 else { throw ConfigurationError(message: "配置文件过大。") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }
    func validate() throws {
        func require(_ value: Bool, _ message: String) throws { if !value { throw ConfigurationError(message: message) } }
        try require(version == 1, "不支持此配置文件版本。")
        try require(AppearanceMode(rawValue: appearance.theme) != nil && BackgroundEffect(rawValue: appearance.background) != nil &&
                    CompactLayout(rawValue: appearance.compact) != nil && DetailLayout(rawValue: appearance.detail) != nil &&
                    MenuBarProgressStyle(rawValue: appearance.progress) != nil && MenuBarRingThickness(rawValue: appearance.thickness) != nil, "配置包含无效布局。")
        try require(appearance.compactMetrics.count <= 3 && appearance.compactMetrics.allSatisfy { UsagePlatform(rawValue: $0.key) != nil && $0.value.count <= 16 && $0.value.allSatisfy { $0.count <= 64 } }, "悬浮指标配置无效。")
        try require((0..<1440).contains(controls.startMinute) && (0..<1440).contains(controls.endMinute), "提醒时段无效。")
        for (action, key) in controls.shortcuts { try require(key.keyLabel.count <= 20 && ShortcutValidation.error(for: key, action: action, bindings: controls.shortcuts) == nil, "快捷键无效或重复。") }
        let indices = Set(accounts.map(\.index))
        try require(accounts.count <= 100 && indices.count == accounts.count && accounts.allSatisfy { $0.index >= 0 && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.label.count <= 40 }, "账号配置无效。")
        for account in accounts {
            try require(account.policy.metrics.allSatisfy { $0.platform == account.platform } && account.policy.thresholds.keys.allSatisfy { $0.platform == account.platform }, "账号提醒指标不属于该平台。")
            for (metric, thresholds) in account.policy.thresholds { _ = try AlertThresholds.make(warning: thresholds.warning, critical: thresholds.critical, metric: metric) }
        }
        try require(visible.count <= 4 && Set(visible).count == visible.count && visible.allSatisfy { indices.contains($0) }, "显示账号不能重复或超过四个。")
        if let menuAccount { try require(accounts.first { $0.index == menuAccount }?.platform == menuMetric.platform, "状态栏账号与指标平台不一致。") }
        try require(presets.count <= 20 && Set(presets.map(\.name)).count == presets.count, "组合数量过多或名称重复。")
        for preset in presets {
            try require(!preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && preset.name.count <= 40 &&
                preset.accounts.count <= 4 && Set(preset.accounts).count == preset.accounts.count && preset.accounts.allSatisfy { indices.contains($0) } &&
                CompactLayout(rawValue: preset.compact) != nil && DetailLayout(rawValue: preset.detail) != nil, "显示组合无效。")
        }
    }
    @MainActor func apply(model: IslandModel, settings: IslandSettings, mapping: [Int: AccountReference], groups: Set<ImportGroup>) throws {
        try validate()
        var merged: [DisplayPreset] = []
        if groups.contains(.accounts) {
            guard Set(mapping.keys) == Set(accounts.map(\.index)), Set(mapping.values).count == accounts.count,
                accounts.allSatisfy({ entry in mapping[entry.index].map { model.savedAccounts.contains($0) && $0.platform == entry.platform } ?? false }) else {
                throw ConfigurationError(message: "请为每个导入账号选择不同的同平台本机账号；尚未添加的账号请先登录。")
            }
            let names = Set(presets.map(\.name))
            merged = model.displayPresets.filter { !names.contains($0.name) } + presets.map {
                DisplayPreset(id: UUID(), name: $0.name, accounts: $0.accounts.compactMap { mapping[$0] }, compact: $0.compact, detail: $0.detail)
            }
            guard merged.count <= 20 else { throw ConfigurationError(message: "合并后超过 20 个显示组合，请先移除部分组合。") }
        }
        // No mutations occur before every selected group's validation has completed.
        if groups.contains(.appearance) {
            settings.sideDockAutoHide = appearance.sideDockAutoHide ?? false
            settings.sideDockEnabled = appearance.sideDockEnabled ?? false
            if let left = appearance.sideDockOnLeft { settings.sideDockOnLeft = left }
            if let y = appearance.sideDockY { settings.sideDockY = min(1, max(0, y)) }
            if let depth = appearance.sideDockCurveDepth {
                settings.sideDockCurveDepth = min(Double(SideDockLayout.maxCurveDepth),
                                                  max(Double(SideDockLayout.minCurveDepth), depth))
            }
            if let expanded = appearance.floatingStatusAlwaysExpanded { settings.floatingStatusAlwaysExpanded = expanded }
            if let enabled = appearance.floatingStatus { settings.floatingStatusEnabled = enabled }
            settings.appearanceMode = AppearanceMode(rawValue: appearance.theme)!
            settings.backgroundEffect = BackgroundEffect(rawValue: appearance.background)!
            settings.compactLayout = CompactLayout(rawValue: appearance.compact)!
            settings.detailLayout = DetailLayout(rawValue: appearance.detail)!
            settings.menuBarProgressStyle = MenuBarProgressStyle(rawValue: appearance.progress)!
            settings.menuBarRingThickness = MenuBarRingThickness(rawValue: appearance.thickness)!
            settings.pausesHoverInFullscreen = appearance.pausesFullscreen
            settings.compactMetricSelection = appearance.compactMetrics
        }
        if groups.contains(.controls) {
            settings.shortcutBindings = controls.shortcuts; settings.alertsScheduleEnabled = controls.scheduled
            settings.alertStartMinute = controls.startMinute; settings.alertEndMinute = controls.endMinute
        }
        if groups.contains(.accounts) {
            for entry in accounts { if let local = mapping[entry.index] {
                model.renameAccount(local.profileID, platform: local.platform, label: entry.label)
                settings.setReminderPolicy(entry.policy, for: local)
            } }
            model.displaySelection = .init(accounts: visible.compactMap { mapping[$0] }); model.persistDisplaySelection()
            model.storeDisplayPresets(merged)
            settings.menuBarMetric = menuMetric
            settings.menuBarAccount = menuAccount.flatMap { mapping[$0] }
            settings.showsMenuBarItem = showsMenu; settings.menuBarAutoFocusEnabled = autoFocus
            model.reconcileAccountRuntimes(); model.onAccountsChanged?()
        }
    }
}
