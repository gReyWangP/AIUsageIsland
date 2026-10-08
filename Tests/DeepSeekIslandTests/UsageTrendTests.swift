import XCTest
@testable import DeepSeekIsland

@MainActor
final class UsageTrendTests: XCTestCase {
    func testNoAvailableQuotaDoesNotOverwritePersistedSamplesAtStartup() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false; model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        let runtime = model.accountRuntime(for: model.activeAccountReference(for: .chatGPT))
        let directory = runtime.store.directory.appendingPathComponent("trend-chatgpt")
        let previous = UsageTrendStore(directory: directory)
        previous.record(metric: .chatGPTWeek, value: 20, unit: "%", resetAt: nil, at: .now.addingTimeInterval(-30))
        await previous.waitUntilLoaded(); await HistoryPersistence.flushAll()
        runtime.recordQuotaTrend()
        await runtime.trend.waitUntilLoaded(); await HistoryPersistence.flushAll()
        let restored = UsageTrendStore(directory: directory)
        await restored.waitUntilLoaded()
        XCTAssertEqual(restored.points.count, 1)
    }
    func testUnlimitedWindowProducesNoQuotaSamples() throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false; model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        let runtime = model.accountRuntime(for: model.activeAccountReference(for: .chatGPT))
        runtime.chatGPTQuota = ChatGPTQuota(planType: "pro", session: nil, weekly: .init(windowSeconds: 604800, usedPercent: 20, resetAt: .now), email: nil, accountID: nil, limitReached: false)
        runtime.recordQuotaTrend()
        XCTAssertEqual(runtime.trend.points.map(\.metric), [.chatGPTWeek])
        XCTAssertEqual(runtime.trend.points.first?.value, 20)
    }
    func testSuccessfulSamplesDeduplicateAndBreakAtResetOrGap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageTrendStore(directory: directory)
        let now = Date(timeIntervalSince1970: 10000), reset = now.addingTimeInterval(3600)
        store.record(metric: .chatGPTFiveHour, value: 20, unit: "%", resetAt: reset, at: now)
        store.record(metric: .chatGPTFiveHour, value: 20, unit: "%", resetAt: reset, at: now)
        store.record(metric: .chatGPTFiveHour, value: 40, unit: "%", resetAt: reset, at: now.addingTimeInterval(300))
        store.record(metric: .chatGPTFiveHour, value: 0, unit: "%", resetAt: reset.addingTimeInterval(18000), at: now.addingTimeInterval(600))
        store.record(metric: .chatGPTFiveHour, value: 2, unit: "%", resetAt: reset.addingTimeInterval(18000), at: now.addingTimeInterval(3600))
        store.record(metric: .chatGPTFiveHour, value: .nan, unit: "%", resetAt: nil, at: now.addingTimeInterval(3900))
        XCTAssertEqual(store.points.count, 4)
        XCTAssertEqual(store.points.map(\.segment), [0, 0, 1, 2])
        await HistoryPersistence.flushAll()
        let restored = UsageTrendStore(directory: directory, at: now.addingTimeInterval(3600))
        await restored.waitUntilLoaded()
        XCTAssertEqual(restored.points.count, 4)
        store.record(metric: .chatGPTFiveHour, value: 5, unit: "%", resetAt: nil, at: now.addingTimeInterval(8 * 86400))
        XCTAssertEqual(store.points.count, 1)
        await HistoryPersistence.flushAll()
        let expired = UsageTrendStore(directory: directory, at: now.addingTimeInterval(16 * 86400))
        await expired.waitUntilLoaded()
        XCTAssertTrue(expired.points.isEmpty)
    }
}
