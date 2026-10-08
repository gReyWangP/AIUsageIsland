import AppKit
import XCTest
@testable import DeepSeekIsland

@MainActor
final class MenuBarQuickMenuTests: XCTestCase {
    func testMenuContainsAddedMetricsWithCurrentCheckAndNoUnaddedPlatforms() {
        let store = UserDefaults(suiteName: UUID().uuidString)!
        let settings = IslandSettings(defaults: store)
        settings.menuBarMetric = .chatGPTWeek
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        let controller = MenuBarStatusController(model: model, settings: settings, onOpen: {})
        let metrics = controller.makeQuickMenu().items.filter { $0.representedObject is String }
        XCTAssertEqual(metrics.count, 2)
        XCTAssertEqual(metrics.first { ($0.representedObject as? String) == MenuBarMetric.chatGPTWeek.rawValue }?.state, .on)
        controller.selectMetric(.deepSeekBalance)
        XCTAssertEqual(settings.menuBarMetric, .chatGPTWeek, "不允许选择未添加平台")
        controller.selectMetric(.chatGPTFiveHour)
        XCTAssertEqual(settings.menuBarMetric, .chatGPTFiveHour)
    }
    func testRefreshTargetsCurrentPlatformAndCannotRefreshLoggedOut() {
        let settings = IslandSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.menuBarMetric = .chatGPTWeek
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        model.chatGPTConnected = false
        let controller = MenuBarStatusController(model: model, settings: settings, onOpen: {})
        var refreshed: UsagePlatform?
        controller.onRefresh = { refreshed = $0 }
        controller.refreshDisplayedPlatform()
        XCTAssertNil(refreshed)
        model.chatGPTConnected = true
        controller.refreshDisplayedPlatform()
        XCTAssertEqual(refreshed, .chatGPT)
    }
}
