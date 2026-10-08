import XCTest
@testable import DeepSeekIsland

@MainActor
final class SettingsTransferTests: XCTestCase {
    func testArchiveOmitsCredentialsAndRequiresExplicitAccountMapping() throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root), settings = IslandSettings(defaults: defaults)
        model.networkAvailable = false; model.platformAccounts = PlatformAccounts(enabled: [.deepSeek])
        XCTAssertTrue(root.savePlatformToken("never-export-me"))
        model.accountProfiles.identify(AccountProfileEntry.legacyID, platform: .deepSeek, identity: "private-identity")
        settings.compactLayout = .vertical
        let archive = SettingsArchive.capture(model: model, settings: settings)
        let data = try archive.encoded()
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("never-export-me")); XCTAssertFalse(json.contains("private-identity"))
        XCTAssertFalse(json.contains(AccountProfileEntry.legacyID.uuidString))
        settings.compactLayout = .horizontal
        XCTAssertThrowsError(try archive.apply(model: model, settings: settings, mapping: [:], groups: [.appearance, .accounts]))
        XCTAssertEqual(settings.compactLayout, .horizontal)
        try archive.apply(model: model, settings: settings, mapping: [0: model.savedAccounts[0]], groups: [.appearance, .accounts])
        XCTAssertEqual(settings.compactLayout, .vertical)
        XCTAssertEqual(root.readPlatformToken(), "never-export-me")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["visible", "appearance", "controls"] {
            var malformed = object
            if key == "visible" { malformed[key] = [0, 0] }
            if key == "appearance" { var part = object[key] as! [String: Any]; part["compact"] = "invalid"; malformed[key] = part }
            if key == "controls" { var part = object[key] as! [String: Any]; part["startMinute"] = 1440; malformed[key] = part }
            XCTAssertThrowsError(try SettingsArchive.decode(JSONSerialization.data(withJSONObject: malformed)), key)
        }
        var invalid = archive; invalid.version = 99
        XCTAssertThrowsError(try SettingsArchive.decode(invalid.encoded()))
    }
}
