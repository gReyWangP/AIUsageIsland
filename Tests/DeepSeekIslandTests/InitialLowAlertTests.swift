import XCTest
@testable import DeepSeekIsland

@MainActor
final class InitialLowAlertTests: XCTestCase {
    func testInitiallyLowWeekAndFiveHourNotifyIndependentlyAndSurviveRestart() async {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        settings.alertsEnabled = true; settings.alertMetrics = [.zhipuFiveHour, .zhipuWeek]
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.zhipu]); model.zhipuConnected = true
        model.zhipuLastUpdated = .now
        let reset = Date.now.addingTimeInterval(3600)
        func update(_ five: Double, _ week: Double, shift: TimeInterval = 0) {
            model.zhipuQuota = .init(kind: .tokens, level: nil,
                fiveHour: .init(usedPercent: five, usedValue: nil, limitValue: nil, nextReset: reset.addingTimeInterval(shift)),
                week: .init(usedPercent: week, usedValue: nil, limitValue: nil, nextReset: reset.addingTimeInterval(shift + 86400)))
        }
        update(85, 95)
        let backend = UsageAlertsControllerTests.Notifications()
        var first: UsageAlertsController? = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: store, backend: backend)
        first?.evaluate(); for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(Set(backend.messages.map(\.metric)), Set([MenuBarMetric.zhipuFiveHour.rawValue, MenuBarMetric.zhipuWeek.rawValue]))
        XCTAssertEqual(backend.messages.count, 2)
        first = nil
        let restarted = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: store, backend: backend)
        restarted.evaluate(); for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 2)
        update(95, 95); restarted.evaluate(); for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 3, "首次15%提醒之后降到5%应允许升级提醒")
        update(95, 95, shift: 7 * 86400)
        restarted.evaluate(); for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 5, "持续连接时新的额度周期低余量可以各提醒一次")
    }
    func testHealthyNewWindowDoesNotRetainPreviousWindowCooldown() {
        var latch = UsageAlertLatch()
        let now = Date.now, oldReset = now.addingTimeInterval(60), newReset = now.addingTimeInterval(3600)
        latch.seed(key: "week", severity: 2)
        latch.recordNotification(key: "week", severity: 2, at: now, resetAt: oldReset)
        XCTAssertTrue(latch.observeWindow(key: "week", resetAt: newReset))
        XCTAssertFalse(latch.observe(key: "week", severity: 0, at: now, recordNotification: false, resetAt: newReset))
        XCTAssertTrue(latch.observe(key: "week", severity: 2, at: now, recordNotification: false, resetAt: newReset))
        XCTAssertTrue(latch.canNotify(key: "week", severity: 2, at: now, resetAt: newReset))
    }
    func testOldSavedStateAdoptsCurrentWindowAndAllowsNextWindow() throws {
        let data = Data("{\"entries\":{\"week\":{\"level\":1,\"lastNotified\":1000,\"lastNotifiedLevel\":1}}}".utf8)
        var latch = try JSONDecoder().decode(UsageAlertLatch.self, from: data)
        let current = Date.now.addingTimeInterval(3600)
        XCTAssertFalse(latch.observeWindow(key: "week", resetAt: current))
        XCTAssertFalse(latch.canNotifyInitially(key: "week", severity: 1, resetAt: current))
        let future = current.addingTimeInterval(7 * 86400)
        XCTAssertTrue(latch.observeWindow(key: "week", resetAt: future))
        XCTAssertTrue(latch.canNotifyInitially(key: "week", severity: 1, resetAt: future))
        XCTAssertFalse(latch.observeWindow(key: "week", resetAt: future), "窗口首次观察后不能每轮重放")
    }
    func testInitialPolicyPersistsCycleAndIgnoresCooldownForNewWindow() throws {
        var latch = UsageAlertLatch(); let now = Date.now, reset = now.addingTimeInterval(3600)
        latch.seed(key: "week", severity: 2)
        XCTAssertTrue(latch.canNotifyInitially(key: "week", severity: 2, resetAt: reset))
        latch.recordNotification(key: "week", severity: 2, at: now, resetAt: reset)
        let data = try JSONEncoder().encode(latch)
        let restored = try JSONDecoder().decode(UsageAlertLatch.self, from: data)
        XCTAssertFalse(restored.canNotifyInitially(key: "week", severity: 2, resetAt: reset))
        XCTAssertFalse(restored.canNotifyInitially(key: "week", severity: 1, resetAt: nil))
        XCTAssertTrue(restored.canNotifyInitially(key: "week", severity: 1, resetAt: reset.addingTimeInterval(86400)))
    }
}
