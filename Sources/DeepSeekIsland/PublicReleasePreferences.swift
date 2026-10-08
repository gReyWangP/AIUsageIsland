import Foundation

/// Captured before startup creates the instance lock or writes any preferences.
enum InstallationStorageEvidence {
    case absent
    case existing(hasAccounts: Bool)
    case unavailable

    static func capture(directory: URL) -> Self {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { return .unavailable }
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            return .existing(hasAccounts: names.contains("account-grant")
                || names.contains("chatgpt-grant") || names.contains("accounts"))
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError { return .absent }
            return .unavailable
        }
    }
}

@MainActor
enum PublicReleasePreferences {
    private static let migrationKey = "publicReleasePreferencesV1"
    static let guideCompletedKey = "startupGuideCompletedV1"
    // Use app-owned keys only: dictionaryRepresentation also contains macOS global defaults.
    private static let legacyKeys: Set<String> = [
        "shortcutBindings", "alertsEnabled", "alertMetrics", "hidesStartupGuide", "showsMenuBarItem",
        "menuBarMetric", "menuBarRingThickness", "menuBarProgressStyle", "menuBarPlatform",
        "appearanceMode", "backgroundEffect", "compactLayout", "detailLayout", "screenDisplayID",
        "screenDisplayName", "pausesHoverInFullscreen", "platformOrder", "compactMetricSelection",
        "accountReminderPoliciesV1", "accountRemindersMigratedV1", "officialResetAlertsEnabled",
        "alertThresholdsV1", "lowAlertsEnabled", "recoveryAlertsEnabled", "alertsScheduleEnabled",
        "alertStartMinute", "alertEndMinute", "alertsSnoozedUntil", "menuBarAccountV1",
        "menuBarAutoFocusEnabled", "accountProfilesV1", "displayedAccountsV1", "displayPresetsV1",
        "enabledUsagePlatforms", "selectedUsagePlatform", "officialResetPendingBaselineV1",
        "personalQuotaAppointmentsV1", "personalQuotaAppointmentsV2", "quotaRecoveryLatchV1",
        "usageAlertLatchV1", guideCompletedKey
    ]

    static func migrate(defaults: UserDefaults, storage: InstallationStorageEvidence) {
        // Any existing marker, including an unrecognized future value, must not reset defaults.
        guard defaults.object(forKey: migrationKey) == nil else { return }
        let hasPreferences = defaults.dictionaryRepresentation().keys.contains {
            legacyKeys.contains($0) || $0.hasPrefix("platformUsageLedger") || $0.hasPrefix("officialReset")
        }
        let fresh: Bool
        let storedAccounts: Bool
        switch storage {
        case .absent: fresh = !hasPreferences; storedAccounts = false
        case .existing(let hasAccounts): fresh = false; storedAccounts = hasAccounts
        case .unavailable: fresh = false; storedAccounts = false
        }
        if defaults.object(forKey: "showsMenuBarItem") == nil {
            defaults.set(fresh, forKey: "showsMenuBarItem")
        }
        if defaults.object(forKey: "officialResetAlertsEnabled") == nil {
            defaults.set(true, forKey: "officialResetAlertsEnabled")
        }
        let hasAccounts = storedAccounts || defaults.data(forKey: "accountProfilesV1") != nil
            || !(defaults.stringArray(forKey: "enabledUsagePlatforms") ?? []).isEmpty
            || defaults.string(forKey: "selectedUsagePlatform") != nil
        if defaults.object(forKey: guideCompletedKey) == nil {
            defaults.set(hasAccounts || defaults.bool(forKey: "hidesStartupGuide"), forKey: guideCompletedKey)
        }
        // Write the marker last; a repeated migration preserves every already-written choice.
        defaults.set(true, forKey: migrationKey)
    }
}
