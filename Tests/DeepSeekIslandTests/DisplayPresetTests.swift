import XCTest
@testable import DeepSeekIsland

@MainActor
final class DisplayPresetTests: XCTestCase {
    func testPresetRestoresOrderAndLayoutWithoutChangingMenuBarOrLogin() throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root), settings = IslandSettings(defaults: defaults)
        model.networkAvailable = false; model.platformAccounts = PlatformAccounts(enabled: [.deepSeek, .chatGPT])
        let accounts = model.savedAccounts
        model.displaySelection = .init(accounts: accounts.reversed())
        settings.compactLayout = .vertical; settings.detailLayout = .stacked
        settings.menuBarAccount = accounts.first
        let preset = try model.saveDisplayPreset(name: "工作", settings: settings)
        model.displaySelection = .init(accounts: [accounts[0]])
        settings.compactLayout = .horizontal
        try model.applyDisplayPreset(preset, settings: settings)
        XCTAssertEqual(model.visibleAccounts, Array(accounts.reversed()))
        XCTAssertEqual(settings.compactLayout, .vertical)
        XCTAssertEqual(settings.menuBarAccount, accounts.first)
        XCTAssertEqual(model.displayPresets.count, 1)
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek])
        XCTAssertThrowsError(try model.applyDisplayPreset(preset, settings: settings))
    }
}
