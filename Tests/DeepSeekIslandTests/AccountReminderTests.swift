import XCTest
@testable import DeepSeekIsland

@MainActor
final class AccountReminderTests: XCTestCase {
    private func fixture() -> (UserDefaults, IslandSettings, IslandModel, AccountReference, AccountReference) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = IslandSettings(defaults: defaults)
        let store = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = IslandModel(defaults: defaults, sessionRoot: store)
        model.presentationSettings = settings
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        let second = model.accountProfiles.add(platform: .chatGPT, label: "个人")
        model.accountProfiles.select(AccountProfileEntry.legacyID, for: .chatGPT)
        return (defaults, settings, model, model.activeAccountReference(for: .chatGPT), AccountReference(platform: .chatGPT, profileID: second.id))
    }
    private func policy(enabled: Bool = true) -> AccountAlertPolicy {
        var value = AccountAlertPolicy.defaults(for: .chatGPT)
        value.enabled = enabled; value.metrics = [.chatGPTFiveHour]
        return value
    }
    private func quota(_ source: AccountRuntime, used: Double, reset: Date) {
        source.chatGPTConnected = true; source.chatGPTLastUpdated = .now
        source.chatGPTQuota = .init(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: used, resetAt: reset),
            weekly: .init(windowSeconds: 604800, usedPercent: 0, resetAt: reset.addingTimeInterval(86400)), email: nil, accountID: nil, limitReached: false)
    }
    func testMigrationKeepsOldReminderTargetAndNewAccountsDefaultOff() {
        let (_, settings, model, first, second) = fixture()
        settings.alertsEnabled = true; settings.alertMetrics = [.chatGPTWeek]
        settings.alertThresholds[.chatGPTWeek] = .init(warning: 30, critical: 5)
        settings.migrateAccountReminders(model)
        XCTAssertTrue(settings.reminderPolicy(for: first, model: model).enabled)
        XCTAssertEqual(settings.reminderPolicy(for: first, model: model).metrics, [.chatGPTWeek])
        XCTAssertEqual(settings.reminderPolicy(for: first, model: model).thresholds(for: .chatGPTWeek).warning, 30)
        XCTAssertFalse(settings.reminderPolicy(for: second, model: model).enabled)
        model.accountProfiles.select(second.profileID, for: .chatGPT)
        settings.migrateAccountReminders(model)
        XCTAssertFalse(settings.reminderPolicy(for: second, model: model).enabled)
    }
    func testRenameAndRestartPreserveAccountSettingsAndDoNotTransferThem() {
        let (defaults, settings, model, first, second) = fixture()
        settings.setReminderPolicy(policy(), for: first)
        settings.setReminderPolicy(policy(enabled: false), for: second)
        model.renameAccount(first.profileID, platform: .chatGPT, label: "新名字")
        let restored = IslandSettings(defaults: defaults)
        XCTAssertTrue(restored.reminderPolicy(for: first, model: model).enabled)
        XCTAssertFalse(restored.reminderPolicy(for: second, model: model).enabled)
    }
    func testHiddenReminderAccountIsMonitoredButDisabledAccountIsNot() {
        let (_, settings, model, _, second) = fixture()
        settings.alertsEnabled = true
        settings.setReminderPolicy(policy(), for: second)
        XCTAssertFalse(model.visibleAccounts.contains(second))
        XCTAssertTrue(model.monitoredAccounts.contains(second))
        settings.setReminderPolicy(policy(enabled: false), for: second)
        XCTAssertFalse(model.monitoredAccounts.contains(second))
    }
    func testSameWindowLowAlertsForTwoAccountsAreBothDeliveredAndDeduplicated() async {
        let (defaults, settings, model, first, second) = fixture()
        settings.alertsEnabled = true
        settings.setReminderPolicy(policy(), for: first); settings.setReminderPolicy(policy(), for: second)
        let reset = Date.now.addingTimeInterval(3600)
        quota(model.selectedRuntime(for: .chatGPT), used: 90, reset: reset)
        quota(model.accountRuntime(for: second), used: 95, reset: reset)
        let backend = UsageAlertsControllerTests.Notifications()
        let alerts = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: defaults, backend: backend)
        alerts.evaluate(); for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 2)
        XCTAssertEqual(Set(backend.messages.compactMap(\.accountKey)), ["legacy", second.profileID.uuidString])
        alerts.evaluate(); for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 2)
    }
    func testDisabledAccountDoesNotBorrowAnotherAccountsThresholdOrSendAlerts() async {
        let (defaults, settings, model, first, second) = fixture()
        settings.alertsEnabled = true
        settings.setReminderPolicy(policy(enabled: false), for: first)
        var selected = policy(); selected.thresholds[.chatGPTFiveHour] = .init(warning: 30, critical: 5)
        settings.setReminderPolicy(selected, for: second)
        let reset = Date.now.addingTimeInterval(3600)
        quota(model.selectedRuntime(for: .chatGPT), used: 99, reset: reset); quota(model.accountRuntime(for: second), used: 75, reset: reset)
        let backend = UsageAlertsControllerTests.Notifications()
        let alerts = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: defaults, backend: backend)
        alerts.evaluate(); for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 1)
        XCTAssertEqual(backend.messages.first?.accountKey, second.profileID.uuidString)
        XCTAssertFalse(backend.messages.first?.title.contains("严重") ?? true)
    }
    func testAppointmentsForSameWindowDoNotReplaceAnotherAccount() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let backend = PersonalQuotaReminderTests.Backend()
        let controller = QuotaReminderController(defaults: defaults, backend: backend)
        let reset = Date.now.addingTimeInterval(3600)
        let first = try QuotaReminderPlan.make(metric: .chatGPTFiveHour, resetAt: reset, lead: .atTime, accountKey: "account-a", accountLabel: "甲")
        let second = try QuotaReminderPlan.make(metric: .chatGPTFiveHour, resetAt: reset, lead: .atTime, accountKey: "account-b", accountLabel: "乙")
        await controller.save(first); await controller.save(second)
        let restored = QuotaReminderController(defaults: defaults, backend: backend)
        XCTAssertEqual(restored.accountPlans.count, 2)
        restored.cancel(second)
        XCTAssertEqual(restored.plan(for: .chatGPTFiveHour, accountKey: "account-a"), first)
        XCTAssertNil(restored.plan(for: .chatGPTFiveHour, accountKey: "account-b"))
        XCTAssertNotEqual(SystemQuotaReminderBackend.request(for: first).identifier, SystemQuotaReminderBackend.request(for: second).identifier)
    }
    func testEnablingReminderWhileRefreshingWaitsForFreshDataThenAlerts() async {
        let (defaults, settings, model, first, second) = fixture()
        settings.alertsEnabled = true
        settings.setReminderPolicy(policy(enabled: false), for: first)
        settings.setReminderPolicy(policy(enabled: false), for: second)
        quota(model.selectedRuntime(for: .chatGPT), used: 90, reset: .now.addingTimeInterval(3600))
        let backend = UsageAlertsControllerTests.Notifications()
        let alerts = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: defaults, backend: backend)
        alerts.evaluate()
        model.chatGPTLoading = true
        settings.setReminderPolicy(policy(), for: first)
        alerts.evaluate(); for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(backend.messages.isEmpty)
        model.chatGPTLoading = false
        alerts.evaluate(); for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 1)
        XCTAssertEqual(backend.messages.first?.accountKey, first.notificationKey)
    }
    final class SuspendedNotifications: UsageNotificationBackend {
        var waiting: CheckedContinuation<Void, Never>?
        var messages: [UsageAlertMessage] = []
        var shouldWait = true
        func authorize() async throws -> Bool { true }
        func permissionText() async -> String { "允许" }
        func deliver(_ message: UsageAlertMessage) async throws {
            if shouldWait { shouldWait = false; await withCheckedContinuation { waiting = $0 } }
            messages.append(message)
        }
        func discard(metric: String, accountKey: String?) {
            messages.removeAll { $0.metric == metric && $0.accountKey == accountKey }
        }
    }
    func testSwitchingActiveAccountDoesNotDiscardAnotherAccountsInFlightAlert() async {
        let (defaults, settings, model, first, second) = fixture()
        settings.alertsEnabled = true
        var recoveryOnly = policy(); recoveryOnly.lowEnabled = false
        settings.setReminderPolicy(recoveryOnly, for: first); settings.setReminderPolicy(policy(enabled: false), for: second)
        let reset = Date.now.addingTimeInterval(3600)
        quota(model.selectedRuntime(for: .chatGPT), used: 100, reset: reset)
        let backend = SuspendedNotifications()
        let alerts = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: defaults, backend: backend)
        model.onAccountContextChanged = { alerts.accountContextChanged($0) }
        alerts.evaluate(); quota(model.selectedRuntime(for: .chatGPT), used: 0, reset: reset); alerts.evaluate()
        for _ in 0..<100 where backend.waiting == nil { await Task.yield() }
        XCTAssertNotNil(backend.waiting)
        await model.selectAccount(second.profileID, platform: .chatGPT)
        backend.waiting?.resume(); backend.waiting = nil
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 1)
        XCTAssertEqual(backend.messages.first?.accountKey, "legacy")
    }
    func testDisablingAccountDuringDeliveryKeepsOtherAccountsQueuedAlert() async {
        let (defaults, settings, model, first, second) = fixture()
        settings.alertsEnabled = true
        settings.setReminderPolicy(policy(), for: first); settings.setReminderPolicy(policy(), for: second)
        let reset = Date.now.addingTimeInterval(3600)
        quota(model.selectedRuntime(for: .chatGPT), used: 90, reset: reset); quota(model.accountRuntime(for: second), used: 90, reset: reset)
        let backend = SuspendedNotifications()
        let alerts = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: defaults, backend: backend)
        alerts.evaluate(); for _ in 0..<100 where backend.waiting == nil { await Task.yield() }
        settings.setReminderPolicy(policy(enabled: false), for: first)
        alerts.evaluate()
        backend.waiting?.resume(); backend.waiting = nil
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 1)
        XCTAssertEqual(backend.messages.first?.accountKey, second.notificationKey)
    }
    func testOldAppointmentWithoutAccountFieldsIsRestoredAndMigrated() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let data = Data("[\"chatGPTFiveHour\",{\"metric\":\"chatGPTFiveHour\",\"resetAt\":900000000,\"lead\":0}]".utf8)
        defaults.set(data, forKey: "personalQuotaAppointmentsV1")
        let controller = QuotaReminderController(defaults: defaults, backend: PersonalQuotaReminderTests.Backend())
        XCTAssertEqual(controller.accountPlans.count, 1)
        XCTAssertEqual(controller.plan(for: .chatGPTFiveHour, accountKey: "legacy")?.accountLabel, "")
        XCTAssertNotNil(defaults.data(forKey: "personalQuotaAppointmentsV2"))
    }
    func testNotificationTargetsHiddenAccountWithoutChangingDisplayOrActiveAccount() {
        let (_, _, model, first, second) = fixture()
        quota(model.accountRuntime(for: second), used: 95, reset: .now.addingTimeInterval(3600))
        model.focusNotification(.chatGPTFiveHour, account: second)
        XCTAssertEqual(model.activeAccountReference(for: .chatGPT), first)
        XCTAssertFalse(model.visibleAccounts.contains(second))
        XCTAssertEqual(model.detailSnapshots.first?.id, second.id)
        model.detailFocus = nil
        XCTAssertEqual(model.detailSnapshots.first?.id, second.id, "高亮结束后仍保留这次打开的账号详情")
        model.notificationDetailAccount = nil
        XCTAssertEqual(model.detailSnapshots.first?.id, first.id)
    }
    func testRemovingAccountClearsOnlyItsPoliciesAndAppointments() async throws {
        let (defaults, settings, model, first, second) = fixture()
        settings.setReminderPolicy(policy(), for: first); settings.setReminderPolicy(policy(), for: second)
        let alerts = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: defaults,
            backend: UsageAlertsControllerTests.Notifications(), quotaReminderBackend: PersonalQuotaReminderTests.Backend())
        let reset = Date.now.addingTimeInterval(3600)
        let a = try QuotaReminderPlan.make(metric: .chatGPTFiveHour, resetAt: reset, lead: .atTime, accountKey: first.notificationKey)
        let b = try QuotaReminderPlan.make(metric: .chatGPTFiveHour, resetAt: reset, lead: .atTime, accountKey: second.notificationKey)
        await alerts.quotaReminders.save(a); await alerts.quotaReminders.save(b)
        alerts.accountRemoved(second)
        XCTAssertNil(settings.accountReminderPolicies[second.id])
        XCTAssertTrue(settings.reminderPolicy(for: first, model: model).enabled)
        XCTAssertEqual(alerts.quotaReminders.plan(for: .chatGPTFiveHour, accountKey: first.notificationKey), a)
        XCTAssertNil(alerts.quotaReminders.plan(for: .chatGPTFiveHour, accountKey: second.notificationKey))
    }

    func testRemovingLastNonLegacyAccountCleansItsActualReminderIdentity() async throws {
        let (defaults, settings, model, first, second) = fixture()
        model.networkAvailable = false
        model.accountProfiles.remove(first.profileID, platform: .chatGPT)
        model.persistProfiles()
        settings.setReminderPolicy(policy(), for: second)
        let alerts = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: defaults,
            backend: UsageAlertsControllerTests.Notifications(), quotaReminderBackend: PersonalQuotaReminderTests.Backend())
        let plan = try QuotaReminderPlan.make(metric: .chatGPTFiveHour,
            resetAt: .now.addingTimeInterval(3600), lead: .atTime,
            accountKey: second.notificationKey, accountLabel: "工作")
        await alerts.quotaReminders.save(plan)

        await model.removeAccount(second)

        XCTAssertFalse(model.savedAccounts.contains(second))
        XCTAssertNil(settings.accountReminderPolicies[second.id], "删除事件必须携带实际 UUID，而不是重置后的 legacy ID")
        XCTAssertNil(alerts.quotaReminders.plan(for: .chatGPTFiveHour, accountKey: second.notificationKey))
    }

}
