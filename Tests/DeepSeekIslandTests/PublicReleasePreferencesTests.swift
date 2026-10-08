import XCTest
@testable import DeepSeekIsland

@MainActor
final class PublicReleasePreferencesTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testNewInstallationHasMenuEntryAndAnnouncementSubscription() {
        withDefaults { defaults in
            let settings = IslandSettings(defaults: defaults)
            XCTAssertTrue(settings.showsMenuBarItem)
            XCTAssertTrue(settings.officialResetAlertsEnabled)
            XCTAssertEqual(defaults.object(forKey: "publicReleasePreferencesV1") as? Bool, true)
        }
    }

    func testOldInstallationWithMissingSwitchesPreservesPreviousDefaults() {
        withDefaults { defaults in
            defaults.set("light", forKey: "appearanceMode")
            let settings = IslandSettings(defaults: defaults)
            XCTAssertFalse(settings.showsMenuBarItem)
            XCTAssertTrue(settings.officialResetAlertsEnabled)
        }
    }

    func testExplicitAnnouncementOptOutSurvivesInitialMigration() {
        withDefaults { defaults in
            defaults.set(false, forKey: "officialResetAlertsEnabled")
            let settings = IslandSettings(defaults: defaults)
            XCTAssertFalse(settings.officialResetAlertsEnabled)
            XCTAssertFalse(IslandSettings(defaults: defaults).officialResetAlertsEnabled)
        }
    }

    func testExplicitSwitchesSurviveRepeatedMigrationAndUserChanges() {
        withDefaults { defaults in
            defaults.set(false, forKey: "showsMenuBarItem")
            defaults.set(true, forKey: "officialResetAlertsEnabled")
            let settings = IslandSettings(defaults: defaults)
            XCTAssertFalse(settings.showsMenuBarItem)
            XCTAssertTrue(settings.officialResetAlertsEnabled)
            settings.showsMenuBarItem = true
            settings.officialResetAlertsEnabled = false
            let restored = IslandSettings(defaults: defaults)
            XCTAssertTrue(restored.showsMenuBarItem)
            XCTAssertFalse(restored.officialResetAlertsEnabled)
        }
    }

    func testExistingAccountsMarkGuideCompletedDuringUpgrade() {
        withDefaults { defaults in
            defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
            _ = IslandSettings(defaults: defaults)
            XCTAssertEqual(defaults.object(forKey: "startupGuideCompletedV1") as? Bool, true)
        }
    }

    func testUncertainStoragePreservesOldDefaults() {
        withDefaults { defaults in
            let settings = IslandSettings(defaults: defaults, storageEvidence: .unavailable)
            XCTAssertFalse(settings.showsMenuBarItem)
            XCTAssertTrue(settings.officialResetAlertsEnabled)
            XCTAssertTrue(settings.shouldShowStartupGuide)
        }
    }

    func testOldCredentialMetadataSkipsGuideWithoutReadingCredentials() {
        withDefaults { defaults in
            let settings = IslandSettings(defaults: defaults, storageEvidence: .existing(hasAccounts: true))
            XCTAssertFalse(settings.shouldShowStartupGuide)
            XCTAssertFalse(settings.showsMenuBarItem)
            XCTAssertTrue(settings.officialResetAlertsEnabled)
        }
    }

    func testStartCompletesGuideButConstructingAndReopeningDoesNot() {
        withDefaults { defaults in
            let settings = IslandSettings(defaults: defaults)
            XCTAssertTrue(settings.shouldShowStartupGuide)
            _ = IslandGuideView(settings: settings, onFinish: {})
            XCTAssertFalse(settings.startupGuideCompleted)
            settings.completeStartupGuide()
            let restored = IslandSettings(defaults: defaults)
            XCTAssertFalse(restored.shouldShowStartupGuide)
            _ = IslandGuideView(settings: restored, onFinish: {})
            XCTAssertTrue(restored.startupGuideCompleted)
        }
    }

    func testLegacyGuideOptOutPersists() {
        withDefaults { defaults in
            defaults.set(true, forKey: "hidesStartupGuide")
            let settings = IslandSettings(defaults: defaults)
            XCTAssertTrue(settings.hidesStartupGuide)
            XCTAssertFalse(settings.shouldShowStartupGuide)
        }
    }

    func testStorageCaptureDistinguishesAbsentDirectoryEmptyDirectoryAndFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        if case .absent = InstallationStorageEvidence.capture(directory: directory) {} else { XCTFail("Absent directory") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if case .existing(hasAccounts: false) = InstallationStorageEvidence.capture(directory: directory) {} else { XCTFail("Existing empty directory") }
        try Data("not a credential".utf8).write(to: directory.appendingPathComponent("chatgpt-grant"))
        if case .existing(hasAccounts: true) = InstallationStorageEvidence.capture(directory: directory) {} else { XCTFail("Existing account metadata") }
        if case .unavailable = InstallationStorageEvidence.capture(directory: directory.appendingPathComponent("chatgpt-grant")) {} else { XCTFail("File is not a data directory") }
    }
}
