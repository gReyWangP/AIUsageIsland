import Foundation

struct AccountAlertPolicy: Codable, Equatable {
    var enabled = false
    var lowEnabled = true
    var recoveryEnabled = true
    var metrics: Set<UsageMetric>
    var thresholds: [UsageMetric: AlertThresholds] = [:]

    static func defaults(for platform: UsagePlatform) -> Self {
        Self(recoveryEnabled: platform != .deepSeek, metrics: Set(UsageMetric.allCases.filter { $0.platform == platform }))
    }
    func thresholds(for metric: UsageMetric) -> AlertThresholds {
        guard let value = thresholds[metric],
              let valid = try? AlertThresholds.make(warning: value.warning, critical: value.critical, metric: metric) else {
            return .defaults(for: metric)
        }
        return valid
    }
    var hasAlerts: Bool { enabled && !metrics.isEmpty && (lowEnabled || recoveryEnabled) }
}

extension IslandSettings {
    func reminderPolicy(for account: AccountReference, model: IslandModel) -> AccountAlertPolicy {
        if let saved = accountReminderPolicies[account.id] { return saved }
        var value = AccountAlertPolicy.defaults(for: account.platform)
        // Compatibility before startup migration, including existing callers of the legacy preferences.
        if !accountRemindersMigrated, account == model.activeAccountReference(for: account.platform) {
            value.enabled = alertsEnabled
            value.lowEnabled = lowAlertsEnabled; value.recoveryEnabled = recoveryAlertsEnabled
            value.metrics = alertMetrics.filter { $0.platform == account.platform }
            value.thresholds = alertThresholds.filter { $0.key.platform == account.platform }
        }
        return value
    }
    func setReminderPolicy(_ policy: AccountAlertPolicy, for account: AccountReference) {
        var value = policy
        value.metrics = value.metrics.filter { $0.platform == account.platform }
        value.thresholds = value.thresholds.filter { $0.key.platform == account.platform }
        if account.platform == .deepSeek { value.recoveryEnabled = false }
        if accountReminderPolicies[account.id] != value { accountReminderPolicies[account.id] = value }
    }
    func migrateAccountReminders(_ model: IslandModel) {
        guard !accountRemindersMigrated else { return }
        for account in model.savedAccounts where accountReminderPolicies[account.id] == nil {
            setReminderPolicy(reminderPolicy(for: account, model: model), for: account)
        }
        accountRemindersMigrated = true
    }
}

extension AccountReference {
    var notificationKey: String { profileID == AccountProfileEntry.legacyID ? "legacy" : profileID.uuidString }
    func alertKey(_ metric: UsageMetric) -> String {
        notificationKey == "legacy" ? metric.rawValue : metric.rawValue + ":" + notificationKey
    }
}

extension IslandModel {
    func accountReference(platform: UsagePlatform, notificationKey: String) -> AccountReference? {
        savedAccounts.first { $0.platform == platform && $0.notificationKey == notificationKey }
    }
    func accountPurpose(_ account: AccountReference, settings: IslandSettings) -> String {
        var parts = [visibleAccounts.contains(account) ? "显示中" : "已隐藏"]
        if settings.showsMenuBarItem, settings.menuBarAccount == account { parts.append("用于状态栏") }
        let policy = settings.reminderPolicy(for: account, model: self)
        parts.append(policy.hasAlerts ? (settings.alertsEnabled ? "提醒已开" : "提醒已暂停") : "提醒未开")
        return parts.joined(separator: " · ")
    }
    func accountConnectionLabel(_ account: AccountReference) -> String {
        accountRuntime(for: account).recoveryPresentation().label
    }
}
