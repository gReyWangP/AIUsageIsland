import AppKit
import XCTest
@testable import DeepSeekIsland

@MainActor
final class MenuBarAutoFocusTests: XCTestCase {
    func testUrgencyStableTieCooldownAndImmediateEscalation() {
        var focus = MenuBarAutoFocus()
        let now = Date.now
        func q(_ metric: MenuBarMetric, _ remaining: Double) -> MenuBarFocusCandidate {
            .init(metric: metric, data: .quota(remaining: remaining))
        }
        XCTAssertEqual(focus.resolve([q(.chatGPTFiveHour, 15), q(.chatGPTWeek, 14)], fallback: .chatGPTFiveHour, at: now), .chatGPTWeek)
        XCTAssertEqual(focus.resolve([q(.chatGPTFiveHour, 10), q(.chatGPTWeek, 14)], fallback: .chatGPTFiveHour, at: now.addingTimeInterval(10)), .chatGPTWeek)
        XCTAssertEqual(focus.resolve([q(.chatGPTFiveHour, 10), q(.chatGPTWeek, 14)], fallback: .chatGPTFiveHour, at: now.addingTimeInterval(61)), .chatGPTFiveHour)
        XCTAssertEqual(focus.resolve([q(.chatGPTFiveHour, 10), q(.chatGPTWeek, 0)], fallback: .chatGPTFiveHour, at: now.addingTimeInterval(62)), .chatGPTWeek)
        XCTAssertEqual(focus.resolve([q(.chatGPTFiveHour, 50), q(.chatGPTWeek, 60)], fallback: .chatGPTFiveHour, at: now.addingTimeInterval(130)), .chatGPTWeek, "健康时不无意义地轮换")
    }
    func testRoutineLoadingPreservesFocusButSevereEscalationCanInterrupt() {
        var focus = MenuBarAutoFocus()
        let now = Date.now
        let first = MenuBarFocusCandidate(metric: .chatGPTFiveHour, data: .quota(remaining: 1))
        let second = MenuBarFocusCandidate(metric: .zhipuFiveHour, data: .quota(remaining: 2))
        XCTAssertEqual(focus.resolve([first, second], fallback: .chatGPTFiveHour, at: now), .chatGPTFiveHour)
        XCTAssertEqual(focus.resolve([second], fallback: .chatGPTFiveHour, at: now.addingTimeInterval(1), temporarilyLoading: .chatGPTFiveHour), .chatGPTFiveHour)
        let exhausted = MenuBarFocusCandidate(metric: .zhipuFiveHour, data: .quota(remaining: 0))
        XCTAssertEqual(focus.resolve([exhausted], fallback: .chatGPTFiveHour, at: now.addingTimeInterval(2), temporarilyLoading: .chatGPTFiveHour), .zhipuFiveHour)
    }
    func testInvalidAndRemovedCandidateFallbackDoesNotLookHealthy() {
        var focus = MenuBarAutoFocus()
        let now = Date.now
        let valid = MenuBarFocusCandidate(metric: .zhipuWeek, data: .quota(remaining: 0))
        XCTAssertEqual(focus.resolve([valid], fallback: .chatGPTFiveHour, at: now), .zhipuWeek)
        XCTAssertEqual(focus.resolve([], fallback: .chatGPTFiveHour, at: now), .chatGPTFiveHour)
    }
    func testManualSelectionTurnsAutoOffAndPreservesFallbackWhileAutoChanges() {
        let name = UUID().uuidString; let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        XCTAssertFalse(settings.menuBarAutoFocusEnabled)
        settings.menuBarMetric = .chatGPTFiveHour; settings.menuBarAutoFocusEnabled = true
        let model = IslandModel(); model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        model.chatGPTConnected = true; model.chatGPTLastUpdated = .now
        model.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: 0, resetAt: nil), weekly: .init(windowSeconds: 604800, usedPercent: 100, resetAt: nil), email: nil, accountID: nil, limitReached: false)
        let controller = MenuBarStatusController(model: model, settings: settings, onOpen: {})
        controller.update()
        XCTAssertEqual(controller.displayedMetric, .chatGPTWeek)
        XCTAssertEqual(settings.menuBarMetric, .chatGPTFiveHour)
        controller.selectMetric(.chatGPTFiveHour)
        XCTAssertFalse(settings.menuBarAutoFocusEnabled)
        XCTAssertEqual(controller.displayedMetric, .chatGPTFiveHour)
        model.networkAvailable = false; settings.menuBarAutoFocusEnabled = true; controller.update()
        XCTAssertEqual(controller.displayedMetric, .chatGPTFiveHour)
        XCTAssertEqual(model.menuBarData(for: controller.displayedMetric).health, .unknown)
    }
    func testAutoWindowLabelsAreNativeSizeAndPreserveBalanceWidth() {
        let quota = MenuBarRenderer.autoImage(platform: .chatGPT, data: .quota(remaining: 40, window: "本周"), dark: false)
        XCTAssertGreaterThan(quota.size.width, 20)
        XCTAssertLessThanOrEqual(quota.size.width, 36)
        XCTAssertEqual(quota.size.height, 18)
        let data = MenuBarData.balance(amount: 39, currency: "CNY")
        XCTAssertEqual(MenuBarRenderer.autoImage(platform: .deepSeek, data: data, dark: false).size,
                       MenuBarRenderer.image(platform: .deepSeek, data: data, dark: false).size)
    }
}
