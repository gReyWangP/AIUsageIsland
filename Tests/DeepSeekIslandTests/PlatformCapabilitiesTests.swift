import XCTest
@testable import DeepSeekIsland

@MainActor
final class PlatformCapabilitiesTests: XCTestCase {
    func testUnlimitedWindowsRemainSelectableButCannotAlertOrReserve() throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.platformAccounts = PlatformAccounts(enabled: [.zhipu, .chatGPT])
        let zhipu = model.accountRuntime(for: model.activeAccountReference(for: .zhipu))
        zhipu.zhipuQuota = ZhipuQuota(kind: .tokens, level: "V1", fiveHour: .init(usedPercent: 20, usedValue: nil, limitValue: nil, nextReset: nil), week: nil)
        let week = zhipu.capabilities.metric(.zhipuWeek)
        XCTAssertTrue(week.canSelect)
        XCTAssertFalse(week.canConfigureAlerts)
        XCTAssertFalse(week.canReserve)
        let gpt = model.accountRuntime(for: model.activeAccountReference(for: .chatGPT))
        XCTAssertTrue(gpt.capabilities.metric(.chatGPTFiveHour).canConfigureAlerts)
        gpt.chatGPTQuota = ChatGPTQuota(planType: "pro", session: nil, weekly: .init(windowSeconds: 604800, usedPercent: 20, resetAt: .now), email: nil, accountID: nil, limitReached: false)
        XCTAssertTrue(gpt.capabilities.metric(.chatGPTFiveHour).canSelect)
        XCTAssertFalse(gpt.capabilities.metric(.chatGPTFiveHour).canConfigureAlerts)
        XCTAssertTrue(gpt.capabilities.metric(.chatGPTWeek).canReserve)
        XCTAssertEqual(gpt.capabilities.alertMetric(preferred: .chatGPTFiveHour), .chatGPTWeek)
        XCTAssertEqual(zhipu.capabilities.alertMetric(preferred: .zhipuWeek), .zhipuFiveHour)
        XCTAssertFalse(gpt.capabilities.metric(.zhipuWeek).canSelect)
    }
}
