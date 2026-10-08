import XCTest
@testable import DeepSeekIsland

private actor LifecycleQuotaService: ChatGPTServing {
    private(set) var requests = 0
    func fetchQuota(grant: ChatGPTGrant) async throws -> ChatGPTQuota {
        requests += 1
        return ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: 37,
            resetAt: .now.addingTimeInterval(3600)), weekly: nil, email: nil, accountID: grant.accountID, limitReached: false)
    }
    func refresh(_ grant: ChatGPTGrant) async throws -> ChatGPTGrant { grant }
}

private actor PausedLifecycleService: ChatGPTServing {
    private(set) var requests = 0
    private var pending: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { pending != nil }
    func fetchQuota(grant: ChatGPTGrant) async throws -> ChatGPTQuota {
        requests += 1
        if requests == 1 { await withCheckedContinuation { pending = $0 } }
        return ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: 95,
            resetAt: .now.addingTimeInterval(-1)), weekly: nil, email: nil, accountID: grant.accountID, limitReached: false)
    }
    func refresh(_ grant: ChatGPTGrant) async throws -> ChatGPTGrant { grant }
    func complete() { pending?.resume(); pending = nil }
}

@MainActor
final class AccountRuntimeLifecycleTests: XCTestCase {
    func testSelectingAccountPreservesRuntimeAndDoesNotFetchAgain() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        var profiles = AccountProfiles()
        let work = profiles.add(platform: .chatGPT, label: "工作")
        XCTAssertTrue(profiles.store(for: .chatGPT, root: root).saveChatGPTGrant(
            .init(accessToken: "work", refreshToken: "work-r", accountID: "work", savedAt: .now)))
        profiles.select(AccountProfileEntry.legacyID, for: .chatGPT)
        defaults.set(try JSONEncoder().encode(profiles), forKey: "accountProfilesV1")
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        let service = LifecycleQuotaService()
        let model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTClient: service)
        let reference = AccountReference(platform: .chatGPT, profileID: work.id)
        let runtime = model.accountRuntime(for: reference)
        await model.refreshAccount(id: reference.id)
        await model.selectAccount(work.id, platform: .chatGPT)
        XCTAssertTrue(model.accountRuntime(for: reference) === runtime)
        XCTAssertEqual(runtime.chatGPTQuota?.session?.usedPercent, 37)
        let requests = await service.requests
        XCTAssertEqual(requests, 1, "选择账号不应带来额外网络请求")
        await model.selectAccount(AccountProfileEntry.legacyID, platform: .chatGPT)
        XCTAssertTrue(model.accountRuntime(for: reference) === runtime)
        XCTAssertEqual(runtime.chatGPTQuota?.session?.usedPercent, 37)
    }

    func testHiddenReminderAccountIsRecoveredAfterNetworkReturns() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        var profiles = AccountProfiles()
        let work = profiles.add(platform: .chatGPT, label: "工作")
        XCTAssertTrue(profiles.store(for: .chatGPT, root: root).saveChatGPTGrant(
            .init(accessToken: "work", refreshToken: "work-r", accountID: "work", savedAt: .now)))
        profiles.select(AccountProfileEntry.legacyID, for: .chatGPT)
        defaults.set(try JSONEncoder().encode(profiles), forKey: "accountProfilesV1")
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        let service = LifecycleQuotaService(), settings = IslandSettings(defaults: defaults)
        let model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTClient: service)
        model.presentationSettings = settings
        let reference = AccountReference(platform: .chatGPT, profileID: work.id)
        var policy = AccountAlertPolicy.defaults(for: .chatGPT); policy.enabled = true
        settings.setReminderPolicy(policy, for: reference); settings.alertsEnabled = true
        XCTAssertFalse(model.visibleAccounts.contains(reference))
        model.networkAvailable = false; model.networkAvailable = true
        await model.recoverDataIfNeeded()
        XCTAssertEqual(model.accountRuntime(for: reference).chatGPTQuota?.session?.usedPercent, 37)
        let requests = await service.requests
        XCTAssertEqual(requests, 1)
    }

    func testHiddenUnusedActiveAccountDoesNotStartPolling() async {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "a", refreshToken: "r", accountID: "a", savedAt: .now)))
        let service = LifecycleQuotaService()
        let model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTClient: service)
        model.setAccountVisible(model.activeAccountReference(for: .chatGPT), visible: false)
        model.startPolling()
        defer { model.pauseAccountPolling() }
        // Let the immediately scheduled startup poll run; no wall-clock network is involved.
        for _ in 0..<100 { await Task.yield() }
        let requests = await service.requests
        XCTAssertEqual(requests, 0)
    }
    func testFailedRemovalKeepsAccountRuntimeAndExplainsFailure() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false
        let account = model.activeAccountReference(for: .chatGPT)
        let runtime = model.accountRuntime(for: account)
        runtime.chatGPTConnected = true
        // unlink must fail for a directory, without requiring permission tricks or real credentials.
        try FileManager.default.createDirectory(at: root.directory.appendingPathComponent("chatgpt-grant"), withIntermediateDirectories: true)
        await model.removeAccount(account)
        XCTAssertTrue(model.savedAccounts.contains(account))
        XCTAssertTrue(model.accountRuntime(for: account) === runtime)
        XCTAssertTrue(runtime.chatGPTConnected)
        XCTAssertNotNil(model.accountManagementError)
    }

    func testReminderSettingsDriveMonitoringWithoutMenuBarController() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        let settings = IslandSettings(defaults: defaults), model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false; model.presentationSettings = settings
        let account = model.activeAccountReference(for: .chatGPT)
        model.setAccountVisible(account, visible: false)
        model.startPolling()
        defer { model.pauseAccountPolling() }
        let runtime = model.accountRuntime(for: account)
        XCTAssertFalse(runtime.hasStartedPolling)
        var policy = AccountAlertPolicy.defaults(for: .chatGPT); policy.enabled = true
        settings.setReminderPolicy(policy, for: account); settings.alertsEnabled = true
        // Settings publishers are delivered after didSet on the main run loop.
        for _ in 0..<10 where !runtime.hasStartedPolling { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(runtime.hasStartedPolling)
        settings.alertsEnabled = false
        for _ in 0..<10 where runtime.hasStartedPolling { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(runtime.hasStartedPolling)
    }

    func testRemovedRuntimeCannotFetchForReaddedLegacyAccount() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        let service = LifecycleQuotaService()
        let model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTClient: service)
        let old = model.selectedRuntime(for: .chatGPT)
        model.disconnect(.chatGPT)
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "new", refreshToken: "new-r", accountID: "new", savedAt: .now)))
        await old.refresh(.chatGPT)
        let requests = await service.requests
        XCTAssertEqual(requests, 0, "移除的实例不能因 legacy ID 被重新使用而复活")
        XCTAssertNil(old.chatGPTQuota)
        XCTAssertFalse(model.selectedRuntime(for: .chatGPT) === old)
    }

    func testHidingBeforeQueuedStartupProfileFetchPreventsRequest() async {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        XCTAssertTrue(root.savePlatformToken("test-token"))
        var requests = 0
        let model = IslandModel(defaults: defaults, sessionRoot: root, deepSeekProfileFetcher: { _ in
            requests += 1
            return AccountProfile(displayName: "test", identity: "user:test")
        })
        model.startPolling()
        model.setAccountVisible(model.activeAccountReference(for: .deepSeek), visible: false)
        defer { model.pauseAccountPolling() }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(requests, 0)
    }

    func testHidingDuringSlowPollPreventsSubsequentResetRequest() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "a", refreshToken: "r", accountID: "a", savedAt: .now)))
        let service = PausedLifecycleService()
        let model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTClient: service)
        let account = model.activeAccountReference(for: .chatGPT)
        let runtime = model.accountRuntime(for: account)
        model.startPolling()
        defer { model.pauseAccountPolling() }
        for _ in 0..<500 {
            if await service.isWaiting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let waiting = await service.isWaiting
        XCTAssertTrue(waiting)
        model.setAccountVisible(account, visible: false)
        // Simulate the request exceeding the debounce, without a 30-second test delay.
        runtime.noteRefreshAttempt(.chatGPT, at: .now.addingTimeInterval(-60))
        await service.complete()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(runtime.chatGPTQuota?.session?.usedPercent, 95, "在途结果仍可保存")
        let requests = await service.requests
        XCTAssertEqual(requests, 1, "隐藏后不再进入重置补查")
    }

}
