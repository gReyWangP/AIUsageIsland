import Combine
import CoreGraphics
import Foundation

/// 悬浮内容的排版方向。
enum CompactLayout: String, CaseIterable, Identifiable {
    /// 从刘海向两侧展开，卡片一横行。
    case horizontal
    /// 以刘海宽度为准向下堆叠。
    case vertical

    var id: String { rawValue }
    var title: String {
        switch self {
        case .horizontal: "横向"
        case .vertical: "纵向"
        }
    }
    var detail: String {
        switch self {
        case .horizontal: "从刘海向两侧展开，多个平台左右并排"
        case .vertical: "保持刘海宽度向下堆叠，窄但省地方"
        }
    }

    /// 悬浮条在该排版下的宽度——**这是唯一的策略定义处**。
    ///
    /// 之前这段逻辑散在 `IslandView.compactBarWidth`、`IslandCompactBar.verticalWidth`
    /// 和面板重设三处，任何一处漏改都会让「条的宽度」和「面板的宽度」对不上，
    /// 表现为内容被裁或只剩一块空白。
    func barWidth(hasNotch: Bool, notchWidth: CGFloat,
                  horizontalBarWidth: CGFloat) -> CGFloat {
        switch self {
        case .horizontal: horizontalBarWidth
        case .vertical: hasNotch ? max(notchWidth, 170) : 200
        }
    }
}

/// 点击后详情页的排版。
enum DetailLayout: String, CaseIterable, Identifiable {
    /// 多个平台左右并排成栏。
    case columns
    /// 每个平台一张全宽卡片，从上到下叠加。
    case stacked

    var id: String { rawValue }
    var title: String {
        switch self {
        case .columns: "横向并排"
        case .stacked: "纵向堆叠"
        }
    }
    var detail: String {
        switch self {
        case .columns: "多个平台并排，逐行对齐"
        case .stacked: "每个平台一张卡片，像通知栏一样叠加"
        }
    }

    /// 还没实测过时的兜底内容高度。
    static let defaultContentHeight: CGFloat = 320

    /// 详情面板在该排版下的宽度——**唯一的策略定义处**。
    func panelWidth(platformCount: Int, screenWidth: CGFloat) -> CGFloat {
        switch self {
        case .columns:
            DetailMetrics.panelWidth(platformCount: platformCount, screenWidth: screenWidth)
        case .stacked:
            NotchLayout.externalBarWidth
        }
    }
}

/// 应用显示在哪块屏幕上。
///
/// 显示器 ID 会随插拔、重启变化，所以同时记下名字作为兜底：
/// ID 命中 → 同名唯一命中 → 回退自动。
enum ScreenSelection: Equatable {
    case automatic
    case display(id: UInt32, name: String)

    var displayID: UInt32? {
        if case .display(let id, _) = self { return id }
        return nil
    }
    var displayName: String? {
        if case .display(_, let name) = self { return name }
        return nil
    }
}

@MainActor
final class IslandSettings: ObservableObject {
    private enum Key {
        static let shortcutBindings = "shortcutBindings"
        static let alertsEnabled = "alertsEnabled"
        static let alertMetrics = "alertMetrics"
        static let hidesStartupGuide = "hidesStartupGuide"
        static let showsMenuBarItem = "showsMenuBarItem"
        static let menuBarMetric = "menuBarMetric"
        static let menuBarRingThickness = "menuBarRingThickness"
        static let menuBarProgressStyle = "menuBarProgressStyle"
        static let menuBarPlatform = "menuBarPlatform"
        static let appearanceMode = "appearanceMode"
        static let backgroundEffect = "backgroundEffect"
        static let compactLayout = "compactLayout"
        static let detailLayout = "detailLayout"
        static let screenDisplayID = "screenDisplayID"
        static let screenDisplayName = "screenDisplayName"
    }

    @Published var centralHoverEnabled: Bool {
        didSet { defaults.set(centralHoverEnabled, forKey: "centralHoverEnabled") }
    }
    @Published var menuBarHoverEnabled: Bool {
        didSet { defaults.set(menuBarHoverEnabled, forKey: "menuBarHoverEnabled") }
    }
    @Published var pausesHoverInFullscreen: Bool {
        didSet { defaults.set(pausesHoverInFullscreen, forKey: "pausesHoverInFullscreen") }
    }
    @Published var platformOrder: [UsagePlatform] {
        didSet { defaults.set(platformOrder.map(\.rawValue), forKey: "platformOrder") }
    }
    @Published var compactMetricSelection: [String: Set<String>] {
        didSet { if let data = try? JSONEncoder().encode(compactMetricSelection) { defaults.set(data, forKey: "compactMetricSelection") } }
    }
    var orderedPlatforms: [UsagePlatform] {
        var seen = Set<UsagePlatform>()
        return (platformOrder + UsagePlatform.allCases).filter { seen.insert($0).inserted }
    }
    func visibleMetricIDs(for platform: UsagePlatform, allIDs: [String]) -> Set<String> {
        let valid = compactMetricSelection[platform.rawValue]?.intersection(Set(allIDs)) ?? Set(allIDs)
        return valid.isEmpty ? Set(allIDs) : valid
    }
    func setCompactMetric(_ id: String, visible: Bool, for platform: UsagePlatform, allIDs: [String]) {
        var selected = visibleMetricIDs(for: platform, allIDs: allIDs)
        if visible { selected.insert(id) } else { selected.remove(id) }
        if !selected.isEmpty { compactMetricSelection[platform.rawValue] = selected }
    }
    func movePlatform(_ platform: UsagePlatform, by offset: Int) {
        var order = orderedPlatforms
        guard let index = order.firstIndex(of: platform), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        platformOrder = order
    }

    @Published var accountReminderPolicies: [String: AccountAlertPolicy] {
        didSet { if let data = try? JSONEncoder().encode(accountReminderPolicies) { defaults.set(data, forKey: "accountReminderPoliciesV1") } }
    }
    @Published var accountRemindersMigrated: Bool {
        didSet { defaults.set(accountRemindersMigrated, forKey: "accountRemindersMigratedV1") }
    }
    @Published var officialResetAlertsEnabled: Bool {
        didSet { defaults.set(officialResetAlertsEnabled, forKey: "officialResetAlertsEnabled") }
    }
    @Published var alertThresholds: [UsageMetric: AlertThresholds] {
        didSet { if let data = try? JSONEncoder().encode(alertThresholds) { defaults.set(data, forKey: "alertThresholdsV1") } }
    }
    @Published var lowAlertsEnabled: Bool {
        didSet { defaults.set(lowAlertsEnabled, forKey: "lowAlertsEnabled") }
    }
    @Published var recoveryAlertsEnabled: Bool {
        didSet { defaults.set(recoveryAlertsEnabled, forKey: "recoveryAlertsEnabled") }
    }
    @Published var alertsScheduleEnabled: Bool {
        didSet { defaults.set(alertsScheduleEnabled, forKey: "alertsScheduleEnabled") }
    }
    @Published var alertStartMinute: Int {
        didSet { defaults.set(alertStartMinute, forKey: "alertStartMinute") }
    }
    @Published var alertEndMinute: Int {
        didSet { defaults.set(alertEndMinute, forKey: "alertEndMinute") }
    }
    @Published var alertsSnoozedUntil: Date? {
        didSet {
            if let until = alertsSnoozedUntil { defaults.set(until, forKey: "alertsSnoozedUntil") }
            else { defaults.removeObject(forKey: "alertsSnoozedUntil") }
        }
    }

    @Published var shortcutBindings: [ShortcutAction: KeyboardShortcut] {
        didSet {
            if let data = try? JSONEncoder().encode(shortcutBindings) { defaults.set(data, forKey: Key.shortcutBindings) }
        }
    }
    @Published var alertsEnabled: Bool {
        didSet { defaults.set(alertsEnabled, forKey: Key.alertsEnabled) }
    }
    @Published var alertMetrics: Set<UsageMetric> {
        didSet { defaults.set(alertMetrics.map(\.rawValue).sorted(), forKey: Key.alertMetrics) }
    }
    @Published var hidesStartupGuide: Bool {
        didSet { defaults.set(hidesStartupGuide, forKey: Key.hidesStartupGuide) }
    }
    @Published private(set) var startupGuideCompleted: Bool {
        didSet { defaults.set(startupGuideCompleted, forKey: PublicReleasePreferences.guideCompletedKey) }
    }
    var shouldShowStartupGuide: Bool { !startupGuideCompleted && !hidesStartupGuide }
    func completeStartupGuide() { startupGuideCompleted = true }
    @Published var showsMenuBarItem: Bool {
        didSet { defaults.set(showsMenuBarItem, forKey: Key.showsMenuBarItem) }
    }
    @Published var menuBarAutoFocusEnabled: Bool {
        didSet { defaults.set(menuBarAutoFocusEnabled, forKey: "menuBarAutoFocusEnabled") }
    }
    @Published var menuBarMetric: UsageMetric {
        didSet {
            defaults.set(menuBarMetric.rawValue, forKey: Key.menuBarMetric)
            if let account = menuBarAccount, account.platform != menuBarMetric.platform { menuBarAccount = nil }
        }
    }
    @Published var menuBarAccount: AccountReference? {
        didSet {
            if let account = menuBarAccount {
                defaults.set(try? JSONEncoder().encode(account), forKey: "menuBarAccountV1")
                if menuBarMetric.platform != account.platform { menuBarMetric = .defaultMetric(for: account.platform) }
            } else { defaults.removeObject(forKey: "menuBarAccountV1") }
        }
    }
    @Published var menuBarRingThickness: MenuBarRingThickness {
        didSet { defaults.set(menuBarRingThickness.rawValue, forKey: Key.menuBarRingThickness) }
    }
    @Published var menuBarProgressStyle: MenuBarProgressStyle {
        didSet { defaults.set(menuBarProgressStyle.rawValue, forKey: Key.menuBarProgressStyle) }
    }
    var menuBarPlatform: UsagePlatform {
        get { menuBarMetric.platform }
        set { menuBarMetric = .defaultMetric(for: newValue) }
    }
    @Published var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: Key.appearanceMode) }
    }
    @Published var backgroundEffect: BackgroundEffect {
        didSet { defaults.set(backgroundEffect.rawValue, forKey: Key.backgroundEffect) }
    }
    @Published var compactLayout: CompactLayout {
        didSet { defaults.set(compactLayout.rawValue, forKey: Key.compactLayout) }
    }
    @Published var detailLayout: DetailLayout {
        didSet { defaults.set(detailLayout.rawValue, forKey: Key.detailLayout) }
    }
    @Published var screenSelection: ScreenSelection {
        didSet {
            switch screenSelection {
            case .automatic:
                defaults.removeObject(forKey: Key.screenDisplayID)
                defaults.removeObject(forKey: Key.screenDisplayName)
            case .display(let id, let name):
                defaults.set(Int(id), forKey: Key.screenDisplayID)
                defaults.set(name, forKey: Key.screenDisplayName)
            }
        }
    }

    var barkPushAddresses: [String] {
        get { barkPushAddress.components(separatedBy: "\n") }
        set { barkPushAddress = newValue.joined(separator: "\n") }
    }
    @Published var barkPushEnabled: Bool { didSet { defaults.set(barkPushEnabled, forKey: "barkPushEnabled") } }
    @Published var barkPushAddress: String { didSet { defaults.set(barkPushAddress, forKey: "barkPushAddress") } }

    @Published var sideDockEnabled: Bool {
        didSet { defaults.set(sideDockEnabled, forKey: "sideDockEnabled") }
    }
    @Published var sideDockAutoHide: Bool {
        didSet { defaults.set(sideDockAutoHide, forKey: "sideDockAutoHide") }
    }
    var floatingStatusAutoHides: Bool {
        sideDockEnabled ? sideDockAutoHide : !floatingStatusAlwaysExpanded
    }
    @Published var sideDockOnLeft: Bool {
        didSet { defaults.set(sideDockOnLeft, forKey: "sideDockOnLeft") }
    }
    @Published var sideDockY: Double {
        didSet { defaults.set(sideDockY, forKey: "sideDockY") }
    }
    @Published var sideDockCurveDepth: Double {
        didSet { defaults.set(sideDockCurveDepth, forKey: "sideDockCurveDepth") }
    }
    var displayMode: IslandDisplayMode {
        get { floatingStatusEnabled ? (sideDockEnabled ? .sideDock : .floating) : .island }
        set {
            sideDockEnabled = newValue == .sideDock
            floatingStatusEnabled = newValue != .island
        }
    }
    @Published var floatingStatusAlwaysExpanded: Bool {
        didSet { defaults.set(floatingStatusAlwaysExpanded, forKey: "floatingStatusAlwaysExpanded") }
    }
    @Published var floatingStatusEnabled: Bool {
        didSet { defaults.set(floatingStatusEnabled, forKey: "floatingStatusEnabled") }
    }
    @Published var floatingStatusPlacement: FloatingStatusPlacement {
        didSet { defaults.set(try? JSONEncoder().encode(floatingStatusPlacement), forKey: "floatingStatusPlacement") }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, storageEvidence: InstallationStorageEvidence = .absent) {
        PublicReleasePreferences.migrate(defaults: defaults, storage: storageEvidence)
        self.defaults = defaults
        sideDockAutoHide = defaults.bool(forKey: "sideDockAutoHide")
        sideDockEnabled = defaults.bool(forKey: "sideDockEnabled")
        sideDockOnLeft = defaults.bool(forKey: "sideDockOnLeft")
        sideDockY = min(2, max(-1, defaults.object(forKey: "sideDockY") as? Double ?? 0.5))
        sideDockCurveDepth = min(Double(SideDockLayout.maxCurveDepth),
                                 max(Double(SideDockLayout.minCurveDepth),
                                     defaults.object(forKey: "sideDockCurveDepth") as? Double ?? Double(SideDockLayout.defaultCurveDepth)))
        floatingStatusAlwaysExpanded = defaults.bool(forKey: "floatingStatusAlwaysExpanded")
        floatingStatusEnabled = defaults.bool(forKey: "floatingStatusEnabled")
        floatingStatusPlacement = defaults.data(forKey: "floatingStatusPlacement")
            .flatMap { try? JSONDecoder().decode(FloatingStatusPlacement.self, from: $0) } ?? FloatingStatusPlacement()
        barkPushEnabled = defaults.bool(forKey: "barkPushEnabled")
        barkPushAddress = defaults.string(forKey: "barkPushAddress") ?? ""
        centralHoverEnabled = defaults.object(forKey: "centralHoverEnabled") as? Bool ?? true
        menuBarHoverEnabled = defaults.object(forKey: "menuBarHoverEnabled") as? Bool ?? false
        pausesHoverInFullscreen = defaults.object(forKey: "pausesHoverInFullscreen") as? Bool ?? true
        platformOrder = defaults.stringArray(forKey: "platformOrder")?.compactMap(UsagePlatform.init(rawValue:)) ?? UsagePlatform.allCases
        compactMetricSelection = defaults.data(forKey: "compactMetricSelection")
            .flatMap { try? JSONDecoder().decode([String: Set<String>].self, from: $0) } ?? [:]
        accountReminderPolicies = defaults.data(forKey: "accountReminderPoliciesV1")
            .flatMap { try? JSONDecoder().decode([String: AccountAlertPolicy].self, from: $0) } ?? [:]
        accountRemindersMigrated = defaults.bool(forKey: "accountRemindersMigratedV1")
        officialResetAlertsEnabled = defaults.object(forKey: "officialResetAlertsEnabled") as? Bool ?? true
        alertThresholds = defaults.data(forKey: "alertThresholdsV1").flatMap { try? JSONDecoder().decode([UsageMetric: AlertThresholds].self, from: $0) } ?? [:]
        lowAlertsEnabled = defaults.object(forKey: "lowAlertsEnabled") as? Bool ?? true
        recoveryAlertsEnabled = defaults.object(forKey: "recoveryAlertsEnabled") as? Bool ?? true
        alertsScheduleEnabled = defaults.bool(forKey: "alertsScheduleEnabled")
        alertStartMinute = max(0, min(1439, defaults.object(forKey: "alertStartMinute") as? Int ?? 540))
        alertEndMinute = max(0, min(1439, defaults.object(forKey: "alertEndMinute") as? Int ?? 1080))
        alertsSnoozedUntil = defaults.object(forKey: "alertsSnoozedUntil") as? Date
        shortcutBindings = defaults.data(forKey: Key.shortcutBindings)
            .flatMap { try? JSONDecoder().decode([ShortcutAction: KeyboardShortcut].self, from: $0) } ?? [:]
        alertsEnabled = defaults.bool(forKey: Key.alertsEnabled)
        alertMetrics = defaults.stringArray(forKey: Key.alertMetrics)
            .map { Set($0.compactMap(UsageMetric.init(rawValue:))) } ?? Set(UsageMetric.allCases)
        hidesStartupGuide = defaults.bool(forKey: Key.hidesStartupGuide)
        startupGuideCompleted = defaults.bool(forKey: PublicReleasePreferences.guideCompletedKey)
        showsMenuBarItem = defaults.bool(forKey: Key.showsMenuBarItem)
        menuBarProgressStyle = defaults.string(forKey: Key.menuBarProgressStyle)
            .flatMap(MenuBarProgressStyle.init(rawValue:)) ?? .ring
        menuBarRingThickness = defaults.string(forKey: Key.menuBarRingThickness)
            .flatMap(MenuBarRingThickness.init(rawValue:)) ?? .standard
        menuBarAutoFocusEnabled = defaults.bool(forKey: "menuBarAutoFocusEnabled")
        let previousPlatform = defaults.string(forKey: Key.menuBarPlatform)
            .flatMap(UsagePlatform.init(rawValue:)) ?? .deepSeek
        menuBarMetric = defaults.string(forKey: Key.menuBarMetric)
            .flatMap(UsageMetric.init(rawValue:)) ?? .defaultMetric(for: previousPlatform)
        menuBarAccount = defaults.data(forKey: "menuBarAccountV1")
            .flatMap { try? JSONDecoder().decode(AccountReference.self, from: $0) }
        appearanceMode = defaults.string(forKey: Key.appearanceMode)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .dark
        backgroundEffect = defaults.string(forKey: Key.backgroundEffect)
            .flatMap(BackgroundEffect.init(rawValue:)) ?? .solid
        compactLayout = defaults.string(forKey: Key.compactLayout)
            .flatMap(CompactLayout.init(rawValue:)) ?? .horizontal
        detailLayout = defaults.string(forKey: Key.detailLayout)
            .flatMap(DetailLayout.init(rawValue:)) ?? .columns
        // 只有同时存了 ID 与名字才算有效记录，否则回退自动。
        if let raw = defaults.object(forKey: Key.screenDisplayID) as? Int,
           let name = defaults.string(forKey: Key.screenDisplayName) {
            screenSelection = .display(id: UInt32(truncatingIfNeeded: raw), name: name)
        } else {
            screenSelection = .automatic
        }
    }
}
