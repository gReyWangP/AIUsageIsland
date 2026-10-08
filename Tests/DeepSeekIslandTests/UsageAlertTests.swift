import XCTest
@testable import DeepSeekIsland

final class UsageAlertTests: XCTestCase {
    func testOnlyCrossingsNotifyAndEscalationIsImmediate() {
        var latch = UsageAlertLatch()
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(latch.observe(key: "g5", severity: 0, at: now))
        XCTAssertTrue(latch.observe(key: "g5", severity: 1, at: now.addingTimeInterval(1)))
        XCTAssertFalse(latch.observe(key: "g5", severity: 1, at: now.addingTimeInterval(2)))
        XCTAssertTrue(latch.observe(key: "g5", severity: 2, at: now.addingTimeInterval(3)))
        XCTAssertFalse(latch.observe(key: "g5", severity: 2, at: now.addingTimeInterval(4)))
        XCTAssertFalse(latch.observe(key: "g5", severity: 0, at: now.addingTimeInterval(5)))
        XCTAssertFalse(latch.observe(key: "g5", severity: 1, at: now.addingTimeInterval(6)))
        XCTAssertFalse(latch.observe(key: "g5", severity: 0, at: now.addingTimeInterval(1900)))
        XCTAssertTrue(latch.observe(key: "g5", severity: 1, at: now.addingTimeInterval(1901)))
    }
    func testStartupLowValueIsBaselineAndStateSurvivesRestart() throws {
        var latch = UsageAlertLatch()
        XCTAssertFalse(latch.observe(key: "d", severity: 2, at: Date()))
        let restored = try JSONDecoder().decode(UsageAlertLatch.self, from: JSONEncoder().encode(latch))
        var next = restored
        XCTAssertFalse(next.observe(key: "d", severity: 2, at: Date()))
    }
}

@MainActor
final class UsageAlertsControllerTests: XCTestCase {
    final class Notifications: UsageNotificationBackend {
        var allowed = true
        var requested = 0
        var messages: [UsageAlertMessage] = []
        func authorize() async throws -> Bool { requested += 1; return allowed }
        func permissionText() async -> String { allowed ? "系统通知已允许" : "系统通知已关闭" }
        func deliver(_ message: UsageAlertMessage) async throws { messages.append(message) }
    }
    func testDeniedPermissionKeepsAlertsDisabled() async {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        let backend = Notifications(); backend.allowed = false
        let controller = UsageAlertsController(model: IslandModel(), settings: settings, onOpen: {}, defaults: store, backend: backend)
        XCTAssertEqual(backend.requested, 0)
        await controller.setEnabled(true)
        XCTAssertFalse(settings.alertsEnabled)
        XCTAssertNotNil(controller.lastError)
    }
    func testControllerIgnoresCacheAndDeliversOnlyFreshCrossing() async {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        settings.alertsEnabled = true
        settings.alertMetrics = [.deepSeekBalance]
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek])
        model.accountConnected = true; model.balance = 10; model.lastUpdated = .now
        let backend = Notifications()
        let controller = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: store, backend: backend)
        controller.evaluate()
        model.balance = 4; model.errorMessage = "连接失败"
        controller.evaluate()
        await Task.yield()
        XCTAssertTrue(backend.messages.isEmpty)
        model.errorMessage = nil; model.lastUpdated = .now
        controller.evaluate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 1)
        controller.evaluate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 1)
    }
}

@MainActor
final class AlertBaselineBoundaryTests: XCTestCase {
    func testEnablingDuringRefreshWaitsForFreshValueThenNotifiesInitialLow() async {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        settings.alertMetrics = [.deepSeekBalance]
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek])
        model.accountConnected = true; model.lastUpdated = .now; model.balance = 10
        let backend = UsageAlertsControllerTests.Notifications()
        let controller = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: store, backend: backend)
        controller.evaluate()
        model.isLoading = true
        await controller.setEnabled(true)
        controller.evaluate()
        model.balance = 4; model.isLoading = false; model.lastUpdated = .now
        controller.evaluate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 1)
        model.balance = 0.5
        controller.evaluate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 2)
    }
}
