import XCTest
@testable import DeepSeekIsland

@MainActor
final class JointQuotaTests: XCTestCase {
    func testRecoveryDoesNotPromiseUseWhenOtherWindowIsExhausted() {
        let model = model(five: 0, week: 100)
        XCTAssertEqual(model.jointQuotaStatus(for: .chatGPT), .blocked(["本周"]))
        XCTAssertTrue(model.quotaRecoveryContext(for: .chatGPTFiveHour).contains("仍受本周额度限制"))
        XCTAssertFalse(model.quotaRecoveryContext(for: .chatGPTFiveHour).contains("可继续使用"))
        XCTAssertTrue(model.snapshot(for: .chatGPT).warning!.contains("本周"))
    }
    func testMissingStaleAndNonfiniteDataCannotConfirmAllWindows() {
        let model = model(five: 0, week: nil)
        XCTAssertEqual(model.jointQuotaStatus(for: .chatGPT), .unknown)
        XCTAssertTrue(model.quotaRecoveryContext(for: .chatGPTFiveHour).contains("未确认"))
        model.chatGPTQuota = quota(five: 0, week: .nan)
        XCTAssertEqual(model.jointQuotaStatus(for: .chatGPT), .unknown)
        model.chatGPTQuota = quota(five: 0, week: 0)
        model.networkAvailable = false
        XCTAssertEqual(model.jointQuotaStatus(for: .chatGPT), .unknown)
    }
    func testTwoPositiveWindowsAndActualTeamNames() {
        let model = model(five: 99, week: 98)
        XCTAssertEqual(model.jointQuotaStatus(for: .chatGPT), .available(["5 小时", "本周"]))
        model.chatGPTQuota = ChatGPTQuota(planType: "team", session: .init(windowSeconds: 604800, usedPercent: 10, resetAt: nil), weekly: .init(windowSeconds: 2592000, usedPercent: 100, resetAt: nil), email: nil, accountID: nil, limitReached: false)
        XCTAssertEqual(model.jointQuotaStatus(for: .chatGPT), .blocked(["本月"]))
    }
    func testDeliveredRecoveryIncludesOtherWindowRestriction() async {
        let name = UUID().uuidString; let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let s = IslandSettings(defaults: store); s.alertsEnabled = true; s.alertMetrics = [.chatGPTFiveHour]
        let m = model(five: 100, week: 100)
        let backend = UsageAlertsControllerTests.Notifications()
        let c = UsageAlertsController(model: m, settings: s, onOpen: {}, defaults: store, backend: backend)
        c.evaluate(); m.chatGPTQuota = quota(five: 0, week: 100); c.evaluate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 1)
        XCTAssertTrue(backend.messages[0].recovered)
        XCTAssertTrue(backend.messages[0].body.contains("仍受本周额度限制"))
        XCTAssertFalse(backend.messages[0].body.contains("可继续使用"))
        m.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: 0, resetAt: nil), weekly: .init(windowSeconds: 604800, usedPercent: 0, resetAt: nil), email: nil, accountID: nil, limitReached: true)
        XCTAssertEqual(m.jointQuotaStatus(for: .chatGPT), .restricted)
    }
    private func model(five: Double, week: Double?) -> IslandModel {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        model.chatGPTConnected = true; model.chatGPTLastUpdated = .now
        model.chatGPTQuota = quota(five: five, week: week)
        return model
    }
    private func quota(five: Double, week: Double?) -> ChatGPTQuota {
        ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: five, resetAt: nil), weekly: week.map { .init(windowSeconds: 604800, usedPercent: $0, resetAt: nil) }, email: nil, accountID: nil, limitReached: false)
    }
}
