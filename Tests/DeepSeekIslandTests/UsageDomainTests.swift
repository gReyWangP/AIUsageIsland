import XCTest
@testable import DeepSeekIsland

@MainActor
final class UsageDomainTests: XCTestCase {
    private func fixture() -> (IslandModel, AccountRuntime) {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        let runtime = model.selectedRuntime(for: .chatGPT)
        runtime.chatGPTConnected = true; runtime.chatGPTLastUpdated = .now
        return (model, runtime)
    }
    private func quota(_ used: Double, reset: Date?, plan: String = "plus") -> ChatGPTQuota {
        .init(planType: plan, session: .init(windowSeconds: 18000, usedPercent: used, resetAt: reset),
            weekly: .init(windowSeconds: 604800, usedPercent: 90, resetAt: Date(timeIntervalSince1970: 2000000000)),
            email: nil, accountID: nil, limitReached: false)
    }
    func testInvalidPercentCannotProduceHealthyReadingOrResetReservation() {
        let (model, runtime) = fixture()
        withExtendedLifetime(model) {
            for used in [-1, Double.nan, Double.infinity] {
                runtime.chatGPTQuota = quota(used, reset: Date(timeIntervalSince1970: 2000000000))
                guard case .unavailable = runtime.localMenuBarData(for: .chatGPTFiveHour) else {
                    XCTFail("Invalid percent must be unknown, not full allowance"); continue
                }
                XCTAssertNil(runtime.quotaResetDate(for: .chatGPTFiveHour))
                XCTAssertFalse(runtime.resetQuotaObservations().contains { $0.metric == .chatGPTFiveHour })
            }
        }
    }
    func testNonFiniteResetDateIsNotScheduledButFiniteUsageRemainsVisible() {
        let (model, runtime) = fixture()
        withExtendedLifetime(model) {
            for seconds in [Double.infinity, -Double.infinity, Double.nan] {
                runtime.chatGPTQuota = quota(95, reset: Date(timeIntervalSince1970: seconds))
                XCTAssertNil(runtime.quotaResetDate(for: .chatGPTFiveHour))
                XCTAssertFalse(runtime.resetQuotaObservations().contains { $0.metric == .chatGPTFiveHour })
                guard case .quota(let remaining, _) = runtime.localMenuBarData(for: .chatGPTFiveHour) else { return XCTFail("Valid usage is still useful") }
                XCTAssertEqual(remaining, 5)
            }
        }
    }
    func testBalanceHasNoQuotaWindowDuration() {
        XCTAssertNil(MenuBarMetric.deepSeekBalance.windowSeconds)
        XCTAssertEqual(MenuBarMetric.chatGPTFiveHour.windowSeconds, 18000)
        XCTAssertEqual(MenuBarMetric.chatGPTWeek.windowSeconds, 604800)
    }
    func testOverQuotaUsagePreservesDetailWhileRemainingIsZero() {
        let (model, _) = fixture()
        withExtendedLifetime(model) {
            model.platformAccounts = PlatformAccounts(enabled: [.zhipu])
            let runtime = model.selectedRuntime(for: .zhipu)
            runtime.zhipuConnected = true
            runtime.zhipuLastUpdated = .now
            let window = ZhipuQuota.Window(usedPercent: 120, usedValue: nil, limitValue: nil, nextReset: nil)
            runtime.zhipuQuota = .init(kind: .tokens, level: nil, fiveHour: window, week: window)
            XCTAssertEqual(runtime.snapshot(for: .zhipu).heroValue, "120%")
            guard case .quota(let remaining, _) = runtime.usageReading(for: .zhipuFiveHour) else {
                return XCTFail("Over-quota usage remains a finite reading")
            }
            XCTAssertEqual(remaining, 0)
        }
    }
    func testExistingReminderPolicyAndReservationJSONRemainCompatible() throws {
        let policyJSON = Data(#"{"enabled":true,"lowEnabled":true,"recoveryEnabled":false,"metrics":["chatGPTFiveHour"],"thresholds":["chatGPTFiveHour",{"warning":25,"critical":7}]}"#.utf8)
        let policy = try JSONDecoder().decode(AccountAlertPolicy.self, from: policyJSON)
        XCTAssertEqual(policy.metrics, [.chatGPTFiveHour])
        XCTAssertEqual(policy.thresholds[.chatGPTFiveHour]?.warning, 25)
        let reencoded = try JSONEncoder().encode(policy)
        XCTAssertEqual(try JSONDecoder().decode(AccountAlertPolicy.self, from: reencoded), policy)
        let planJSON = Data(#"{"metric":"chatGPTWeek","resetAt":800000000,"lead":0,"accountKey":"legacy","accountLabel":"工作"}"#.utf8)
        let plan = try JSONDecoder().decode(QuotaReminderPlan.self, from: planJSON)
        XCTAssertEqual(plan.metric, .chatGPTWeek)
        XCTAssertEqual(plan.accountKey, "legacy")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        XCTAssertEqual(object["metric"] as? String, "chatGPTWeek")
        XCTAssertEqual(object["accountKey"] as? String, "legacy")
    }
    func testProUnlimitedAndFiniteWeekStayDistinctAcrossConsumers() throws {
        let (model, runtime) = fixture()
        withExtendedLifetime(model) {
            runtime.chatGPTQuota = .init(planType: "pro", session: nil,
                weekly: .init(windowSeconds: 604800, usedPercent: 100, resetAt: Date(timeIntervalSince1970: 2000000000)),
                email: nil, accountID: nil, limitReached: true)
            guard case .unlimited = runtime.localMenuBarData(for: .chatGPTFiveHour) else { return XCTFail("Pro unlimited must survive refactor") }
            XCTAssertNil(AlertThresholds.defaults(for: .chatGPTFiveHour).severity(runtime.localMenuBarData(for: .chatGPTFiveHour)))
            XCTAssertNil(runtime.quotaResetDate(for: .chatGPTFiveHour))
            XCTAssertEqual(runtime.resetQuotaObservations().map(\.metric), [.chatGPTWeek])
            XCTAssertEqual(runtime.jointQuotaStatus(for: .chatGPT), .blocked(["本周"]))
            runtime.chatGPTQuota = quota(95, reset: Date(timeIntervalSince1970: 2000000000), plan: "pro")
            guard case .quota(let remaining, _) = runtime.localMenuBarData(for: .chatGPTFiveHour) else { return XCTFail("Explicit finite window takes priority") }
            XCTAssertEqual(remaining, 5)
        }
    }
    func testSnapshotUsesTheSameValidatedPercentageAndResetDate() {
        let (model, runtime) = fixture()
        withExtendedLifetime(model) {
            runtime.chatGPTQuota = quota(95, reset: Date(timeIntervalSince1970: .infinity))
            let validUsage = runtime.snapshot(for: .chatGPT)
            XCTAssertNil(validUsage.rows.first { $0.id == "session-reset" }?.resetAt)
            XCTAssertNil(validUsage.compactMetrics.first?.resetAt)
            XCTAssertEqual(validUsage.heroValue, "95%")
            runtime.chatGPTQuota = quota(-1, reset: Date(timeIntervalSince1970: 2000000000))
            let invalidUsage = runtime.snapshot(for: .chatGPT)
            XCTAssertEqual(invalidUsage.heroValue, "—")
            XCTAssertNil(invalidUsage.rows.first { $0.id == "session-reset" }?.resetAt)
        }
    }

}
