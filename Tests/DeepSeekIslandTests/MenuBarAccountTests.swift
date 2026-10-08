import AppKit
import Combine
import XCTest
@testable import DeepSeekIsland

@MainActor
final class MenuBarAccountTests: XCTestCase {
    func testStatusRedrawDoesNotRepublishUnchangedAccountProfiles() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        var profiles = AccountProfiles()
        let work = profiles.add(platform: .chatGPT, label: "工作")
        profiles.select(AccountProfileEntry.legacyID, for: .chatGPT)
        defaults.set(try JSONEncoder().encode(profiles), forKey: "accountProfilesV1")
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        let ref = AccountReference(platform: .chatGPT, profileID: work.id)
        _ = model.accountRuntime(for: ref)
        let settings = IslandSettings(defaults: defaults)
        settings.menuBarAccount = ref
        let controller = MenuBarStatusController(model: model, settings: settings, onOpen: {})
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        for _ in 0..<5 { controller.update() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(changes, 0, "状态栏重绘不能重新发布未改变的资料，形成无限反馈循环")
        model.renameAccount(work.id, platform: .chatGPT, label: "新名称")
        XCTAssertGreaterThan(changes, 0, "真实账号变更仍需通知界面")
    }
    func testLegacyPlatformPreferenceMigratesToAuthorizedAccountBeforeFirstRefresh() throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        var profiles = AccountProfiles()
        _ = profiles.add(platform: .chatGPT, label: "尚未验证")
        defaults.set(try JSONEncoder().encode(profiles), forKey: "accountProfilesV1")
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "test", refreshToken: "test-refresh", accountID: "test", savedAt: .now)))
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        let settings = IslandSettings(defaults: defaults)
        settings.menuBarMetric = .chatGPTFiveHour
        let controller = MenuBarStatusController(model: model, settings: settings, onOpen: {})
        XCTAssertEqual(settings.menuBarAccount?.profileID, AccountProfileEntry.legacyID)
        XCTAssertEqual(controller.data(for: .chatGPTFiveHour).health, .unknown)
    }
    func testExplicitMenuAccountPersistsAndReadsOnlyTheNamedAccount() throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        var profiles = AccountProfiles()
        let work = profiles.add(platform: .chatGPT, label: "工作账号")
        profiles.select(AccountProfileEntry.legacyID, for: .chatGPT)
        defaults.set(try JSONEncoder().encode(profiles), forKey: "accountProfilesV1")
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        let ref = AccountReference(platform: .chatGPT, profileID: work.id)
        let worker = model.accountRuntime(for: ref)
        worker.chatGPTConnected = true; worker.chatGPTLastUpdated = .now
        worker.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: 30, resetAt: nil), weekly: nil, email: nil, accountID: "work", limitReached: false)
        model.chatGPTConnected = true; model.chatGPTLastUpdated = .now
        model.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: 100, resetAt: nil), weekly: nil, email: nil, accountID: "personal", limitReached: true)
        let settings = IslandSettings(defaults: defaults)
        settings.menuBarAccount = ref
        XCTAssertEqual(settings.menuBarMetric, .chatGPTFiveHour)
        XCTAssertEqual(IslandSettings(defaults: defaults).menuBarAccount, ref)
        let controller = MenuBarStatusController(model: model, settings: settings, onOpen: {})
        XCTAssertTrue(controller.makeQuickMenu().items[0].title.contains("工作账号"))
        if case .quota(let remaining, _) = controller.data(for: .chatGPTFiveHour) { XCTAssertEqual(remaining, 70) }
        else { XCTFail("必须读取明确选择的账号") }
        model.renameAccount(work.id, platform: .chatGPT, label: "新的名称")
        XCTAssertTrue(controller.makeQuickMenu().items[0].title.contains("新的名称"))
        worker.chatGPTConnected = false
        XCTAssertEqual(controller.data(for: .chatGPTFiveHour).health, .unknown)
        XCTAssertTrue(controller.makeQuickMenu().items[0].title.contains("新的名称"))
        settings.menuBarAutoFocusEnabled = true; controller.update()
        XCTAssertEqual(controller.displayedMetric, .chatGPTFiveHour)
        XCTAssertEqual(controller.data(for: controller.displayedMetric).health, .unknown)
        model.presentationSettings = settings
        settings.showsMenuBarItem = true
        defer { settings.showsMenuBarItem = false; controller.update() }
        controller.update()
        let button = try XCTUnwrap(controller.statusButton)
        XCTAssertTrue(model.monitoredAccounts.contains(ref), "隐藏悬浮卡片仍刷新选定的状态栏账号")
        settings.menuBarAccount = model.activeAccountReference(for: .chatGPT)
        controller.update()
        XCTAssertTrue(controller.statusButton === button, "切换账号复用同一个状态栏图标")
    }
    func testPendingAccountDoesNotReplaceAuthorizedAccountsQuotaInStatusBar() throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        var profiles = AccountProfiles()
        let pending = profiles.add(platform: .chatGPT, label: "待验证")
        defaults.set(try JSONEncoder().encode(profiles), forKey: "accountProfilesV1")
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "test", refreshToken: "test-refresh", accountID: "test-id", savedAt: .now)))
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        let original = AccountReference(platform: .chatGPT, profileID: AccountProfileEntry.legacyID)
        let worker = model.accountRuntime(for: original)
        worker.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: 50, resetAt: nil), weekly: .init(windowSeconds: 604800, usedPercent: 80, resetAt: nil), email: nil, accountID: "test-id", limitReached: false)
        worker.chatGPTConnected = true; worker.chatGPTLastUpdated = .now
        XCTAssertFalse(model.chatGPTConnected)
        XCTAssertEqual(model.accountProfiles.active(for: .chatGPT).id, pending.id)
        if case .quota(let remaining, _) = model.menuBarData(for: .chatGPTFiveHour) {
            XCTAssertEqual(remaining, 50)
        } else { XCTFail("待验证账号不能挤掉已授权账号的数据") }
        let settings = IslandSettings(defaults: defaults)
        settings.menuBarMetric = .chatGPTFiveHour; settings.menuBarAutoFocusEnabled = true
        let controller = MenuBarStatusController(model: model, settings: settings, onOpen: {})
        controller.update()
        XCTAssertEqual(controller.displayedMetric, .chatGPTFiveHour)
        XCTAssertTrue(controller.canRefreshDisplayed)
        let menu = controller.makeQuickMenu()
        XCTAssertTrue(menu.items[0].title.contains("ChatGPT"))
        XCTAssertFalse(menu.items[0].title.contains("待验证"))
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "选择账号" }?.submenu)
        let waiting = try XCTUnwrap(submenu.items.first { $0.title.contains("待验证") })
        XCTAssertFalse(waiting.isEnabled)
        XCTAssertEqual(submenu.items.first { $0.title == "ChatGPT · ChatGPT" }?.state, .on)
        // A saved grant without a successful first quota response is still pending.
        model.chatGPTConnected = true
        let pendingMenu = try XCTUnwrap(controller.makeQuickMenu().items.first { $0.title == "选择账号" }?.submenu)
        XCTAssertFalse(try XCTUnwrap(pendingMenu.items.first { $0.title.contains("等待首次更新") }).isEnabled)
        if case .quota(let remaining, _) = model.menuBarData(for: .chatGPTFiveHour) {
            XCTAssertEqual(remaining, 50)
        } else { XCTFail("首次额度验证未完成也不能替换已有数据") }
        model.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: 100, resetAt: nil), weekly: nil, email: nil, accountID: "work-id", limitReached: true)
        model.chatGPTLastUpdated = .now
        if case .quota(let remaining, _) = model.menuBarData(for: .chatGPTFiveHour) {
            XCTAssertEqual(remaining, 0)
        } else { XCTFail("真正耗尽不能被其他账号余量覆盖") }
        XCTAssertEqual(model.menuBarTitle(for: .chatGPTFiveHour), "待验证 · 5 小时剩余额度")
        model.chatGPTUsageError = "暂时更新失败"
        XCTAssertEqual(model.menuBarData(for: .chatGPTFiveHour).health, .unknown,
                       "已经取得过额度的账号更新失败时，不能借用另一账号余量")
    }
}
