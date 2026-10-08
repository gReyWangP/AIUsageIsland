import XCTest
@testable import DeepSeekIsland

final class QuotaRecoveryTests: XCTestCase {
    func testWaitsForResetAndActualRecoveryAndDoesNotRepeat() {
        var latch = QuotaRecoveryLatch()
        let now = Date(timeIntervalSince1970: 1000)
        let reset = now.addingTimeInterval(60)
        latch.seed(key: "5h", remaining: 5, resetAt: reset)
        XCTAssertFalse(latch.observe(key: "5h", remaining: 6, resetAt: reset, at: now))
        XCTAssertFalse(latch.observe(key: "5h", remaining: 6, resetAt: reset, at: reset))
        XCTAssertTrue(latch.observe(key: "5h", remaining: 90, resetAt: reset.addingTimeInterval(18000), at: reset.addingTimeInterval(1)))
        XCTAssertFalse(latch.observe(key: "5h", remaining: 90, resetAt: reset.addingTimeInterval(18000), at: reset.addingTimeInterval(2)))
        XCTAssertFalse(latch.observe(key: "5h", remaining: 95, resetAt: reset.addingTimeInterval(18000), at: reset.addingTimeInterval(3)))
        latch.seed(key: "lag", remaining: 5, resetAt: reset)
        XCTAssertFalse(latch.observe(key: "lag", remaining: 5, resetAt: reset.addingTimeInterval(18000), at: reset.addingTimeInterval(1)))
        XCTAssertTrue(latch.observe(key: "lag", remaining: 90, resetAt: reset.addingTimeInterval(18000), at: reset.addingTimeInterval(2)), "重置时间先滚动、额度稍后恢复时也应通知")
    }
    func testExhaustedQuotaCanRecoverWithoutResetMetadataAndPersistsDeduplication() throws {
        var latch = QuotaRecoveryLatch()
        latch.seed(key: "week", remaining: 0, resetAt: nil)
        XCTAssertFalse(latch.observe(key: "week", remaining: 0, resetAt: nil, at: .now))
        XCTAssertTrue(latch.observe(key: "week", remaining: 1, resetAt: nil, at: .now))
        var restored = try JSONDecoder().decode(QuotaRecoveryLatch.self, from: JSONEncoder().encode(latch))
        XCTAssertFalse(restored.observe(key: "week", remaining: 2, resetAt: nil, at: .now))
        XCTAssertFalse(restored.observe(key: "week", remaining: 0, resetAt: nil, at: .now))
        XCTAssertTrue(restored.observe(key: "week", remaining: 20, resetAt: nil, at: .now))
    }
    func testWindowsAreIndependentAndStartupIsQuiet() {
        var latch = QuotaRecoveryLatch()
        let reset = Date().addingTimeInterval(-10)
        XCTAssertFalse(latch.observe(key: "5h", remaining: 100, resetAt: reset, at: .now))
        latch.seed(key: "week", remaining: 0, resetAt: reset)
        latch.seed(key: "5h", remaining: 0, resetAt: reset)
        XCTAssertTrue(latch.observe(key: "5h", remaining: 100, resetAt: reset, at: .now))
        XCTAssertTrue(latch.observe(key: "week", remaining: 100, resetAt: reset, at: .now))
        XCTAssertFalse(latch.observe(key: "week", remaining: 100, resetAt: reset, at: .now))
    }
}

@MainActor
final class RecoveryNotificationTests: XCTestCase {
    func testAllFourQuotaWindowsNotifyOnlyAfterFreshRecovery() async {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        settings.alertsEnabled = true
        settings.alertMetrics = [.zhipuFiveHour, .zhipuWeek, .chatGPTFiveHour, .chatGPTWeek]
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.zhipu, .chatGPT])
        model.zhipuConnected = true; model.chatGPTConnected = true
        model.zhipuLastUpdated = .now; model.chatGPTLastUpdated = .now
        let reset = Date().addingTimeInterval(-10)
        func update(_ used: Double) {
            let window = ZhipuQuota.Window(usedPercent: used, usedValue: nil, limitValue: nil, nextReset: reset)
            model.zhipuQuota = ZhipuQuota(kind: .tokens, level: nil, fiveHour: window, week: window)
            model.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: used, resetAt: reset), weekly: .init(windowSeconds: 604800, usedPercent: used, resetAt: reset), email: nil, accountID: nil, limitReached: false)
        }
        update(100)
        let backend = UsageAlertsControllerTests.Notifications()
        let controller = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: store, backend: backend)
        controller.evaluate()
        model.networkAvailable = false
        update(0)
        controller.evaluate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(backend.messages.isEmpty)
        model.networkAvailable = true
        controller.evaluate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 4)
        XCTAssertTrue(backend.messages.allSatisfy { $0.title.contains("额度已恢复") })
        XCTAssertEqual(Set(backend.messages.map(\.metric)).count, 4)
        controller.evaluate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 4)
    }
}
