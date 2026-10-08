import XCTest
import UserNotifications
@testable import DeepSeekIsland

@MainActor
final class PersonalQuotaReminderTests: XCTestCase {
    final class Backend: QuotaReminderBackend {
        var saved: [QuotaReminderPlan] = []; var canceled: [MenuBarMetric] = []; var denied = false
        func put(_ plan: QuotaReminderPlan) async throws {
            if denied { throw ResetReminderError(message: "拒绝通知") }; saved.append(plan)
        }
        func cancel(_ metric: MenuBarMetric) { canceled.append(metric) }
    }
    func testIndependentAppointmentsPersistReplaceAndCancel() async throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = Backend(), controller = QuotaReminderController(defaults: defaults, backend: backend)
        let date = Date.now.addingTimeInterval(7200)
        let five = try QuotaReminderPlan.make(metric: .zhipuFiveHour, resetAt: date, lead: .atTime)
        let week = try QuotaReminderPlan.make(metric: .zhipuWeek, resetAt: date.addingTimeInterval(86400), lead: .fifteenMinutesEarly)
        await controller.save(five); await controller.save(week); await controller.save(five)
        XCTAssertEqual(backend.saved.count, 2)
        XCTAssertEqual(QuotaReminderController(defaults: defaults, backend: backend).plans.count, 2)
        let replacement = try QuotaReminderPlan.make(metric: .zhipuFiveHour, resetAt: date, lead: .fifteenMinutesEarly)
        backend.denied = true; await controller.save(replacement)
        XCTAssertEqual(controller.plans[.zhipuFiveHour], five)
        controller.cancel(.zhipuFiveHour)
        XCTAssertNil(controller.plans[.zhipuFiveHour]); XCTAssertEqual(controller.plans[.zhipuWeek], week)
        XCTAssertEqual(backend.canceled, [.zhipuFiveHour])
    }
    func testDeadlineValidationAndNotificationMeaning() throws {
        XCTAssertThrowsError(try QuotaReminderPlan.make(metric: .deepSeekBalance, resetAt: .now.addingTimeInterval(7200), lead: .atTime))
        XCTAssertThrowsError(try QuotaReminderPlan.make(metric: .chatGPTWeek, resetAt: .now.addingTimeInterval(800), lead: .fifteenMinutesEarly))
        let plan = try QuotaReminderPlan.make(metric: .chatGPTWeek, resetAt: .now.addingTimeInterval(7200), lead: .atTime)
        let request = SystemQuotaReminderBackend.request(for: plan)
        XCTAssertTrue(request.content.title.contains("预计")); XCTAssertTrue(request.content.body.contains("不代表额度已恢复"))
        XCTAssertEqual(request.content.userInfo["metric"] as? String, MenuBarMetric.chatGPTWeek.rawValue)
        XCTAssertNotEqual(request.identifier, ResetReminderAction.requestID)
        XCTAssertNotEqual(request.identifier, SystemQuotaReminderBackend.request(for: try QuotaReminderPlan.make(metric: .chatGPTFiveHour, resetAt: plan.resetAt, lead: .atTime)).identifier)
    }
    func testThresholdsPersistAndDoNotChangeIconHealth() throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: defaults)
        let custom = try AlertThresholds.make(warning: 30, critical: 5, metric: .zhipuWeek)
        settings.alertThresholds[.zhipuWeek] = custom
        XCTAssertEqual(IslandSettings(defaults: defaults).thresholds(for: .zhipuWeek), custom)
        let data = MenuBarData.quota(remaining: 25)
        XCTAssertEqual(data.health, .healthy)
        XCTAssertEqual(settings.alertSeverity(for: .zhipuWeek, data: data), 1)
        XCTAssertEqual(settings.alertSeverity(for: .zhipuFiveHour, data: data), 0)
        XCTAssertThrowsError(try AlertThresholds.make(warning: 10, critical: 20, metric: .zhipuWeek))
        XCTAssertThrowsError(try AlertThresholds.make(warning: .nan, critical: 1, metric: .deepSeekBalance))
        XCTAssertEqual(settings.alertSeverity(for: .deepSeekBalance, data: .balance(amount: 0.5, currency: "CNY")), 2)
    }
    final class WaitingBackend: QuotaReminderBackend {
        var wait = false
        var pending: CheckedContinuation<Void, Never>?
        var canceled: [MenuBarMetric] = []
        func put(_ plan: QuotaReminderPlan) async throws {
            if wait { await withCheckedContinuation { pending = $0 } }
        }
        func cancel(_ metric: MenuBarMetric) { canceled.append(metric) }
    }
    func testCancelingAnotherWindowDoesNotInvalidateWaitingAppointment() async throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = WaitingBackend(), controller = QuotaReminderController(defaults: defaults, backend: backend)
        let date = Date.now.addingTimeInterval(7200)
        let first = try QuotaReminderPlan.make(metric: .zhipuWeek, resetAt: date, lead: .atTime)
        await controller.save(first)
        let next = try QuotaReminderPlan.make(metric: .zhipuWeek, resetAt: date, lead: .fifteenMinutesEarly)
        backend.wait = true
        let saving = Task { await controller.save(next) }
        for _ in 0..<30 where backend.pending == nil { await Task.yield() }
        XCTAssertNotNil(backend.pending)
        controller.cancel(.zhipuFiveHour); controller.cancel(platform: .chatGPT)
        backend.pending?.resume(); await saving.value
        XCTAssertEqual(controller.plans[.zhipuWeek], next)
        XCTAssertFalse(backend.canceled.contains(.zhipuWeek))
        XCTAssertNil(controller.error)
    }
    func testChangedContextAfterSystemSchedulingDoesNotKeepPhantomRecord() async throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = WaitingBackend(), controller = QuotaReminderController(defaults: defaults, backend: backend)
        var current = true; controller.isCurrent = { _ in current }
        let plan = try QuotaReminderPlan.make(metric: .chatGPTWeek, resetAt: .now.addingTimeInterval(7200), lead: .atTime)
        backend.wait = true
        let saving = Task { await controller.save(plan) }
        for _ in 0..<30 where backend.pending == nil { await Task.yield() }
        current = false; backend.pending?.resume(); await saving.value
        XCTAssertNil(controller.plans[.chatGPTWeek]); XCTAssertEqual(backend.canceled, [.chatGPTWeek])
    }
    func testCustomNotificationThresholdAndSeparateAccountLatches() async throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let settings = IslandSettings(defaults: defaults)
        settings.alertsEnabled = true; settings.alertMetrics = [.zhipuWeek]
        settings.alertThresholds[.zhipuWeek] = try .make(warning: 30, critical: 5, metric: .zhipuWeek)
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.platformAccounts = PlatformAccounts(enabled: [.zhipu]); model.zhipuConnected = true; model.zhipuLastUpdated = .now
        let reset = Date.now.addingTimeInterval(3600)
        model.zhipuQuota = .init(kind: .tokens, level: nil, fiveHour: .init(usedPercent: 0, usedValue: nil, limitValue: nil, nextReset: reset), week: .init(usedPercent: 75, usedValue: nil, limitValue: nil, nextReset: reset))
        let backend = UsageAlertsControllerTests.Notifications()
        let alerts = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: defaults, backend: backend, quotaReminderBackend: Backend())
        alerts.evaluate(); for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 1); XCTAssertFalse(backend.messages[0].title.contains("严重"))
        model.zhipuQuota = .init(kind: .tokens, level: nil, fiveHour: .init(usedPercent: 0, usedValue: nil, limitValue: nil, nextReset: reset), week: .init(usedPercent: 96, usedValue: nil, limitValue: nil, nextReset: reset))
        alerts.evaluate(); for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 2); XCTAssertTrue(backend.messages[1].title.contains("严重"))
        alerts.accountContextChanged(.zhipu)
        let profile = model.accountProfiles.add(platform: .zhipu, label: "工作")
        // A newly added account must never inherit another account's quota.
        XCTAssertNil(model.zhipuQuota)
        XCTAssertFalse(model.zhipuConnected)
        model.zhipuConnected = true; model.zhipuLastUpdated = .now
        model.zhipuQuota = .init(kind: .tokens, level: nil,
            fiveHour: .init(usedPercent: 0, usedValue: nil, limitValue: nil, nextReset: reset),
            week: .init(usedPercent: 96, usedValue: nil, limitValue: nil, nextReset: reset))
        alerts.evaluate(); for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 3); XCTAssertEqual(backend.messages.last?.accountKey, profile.id.uuidString)
        alerts.accountContextChanged(.zhipu); model.accountProfiles.select(AccountProfileEntry.legacyID, for: .zhipu)
        alerts.evaluate(); for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 3, "返回已经提醒的账号不重放")
    }

    func testCustomWarningAlsoArmsActualRecovery() {
        var latch = QuotaRecoveryLatch()
        let now = Date.now, deadline = now.addingTimeInterval(60)
        latch.seed(key: "week", remaining: 25, resetAt: deadline, warning: 30)
        XCTAssertTrue(latch.observe(key: "week", remaining: 100, resetAt: deadline.addingTimeInterval(86400), at: deadline, warning: 30))
        XCTAssertFalse(latch.observe(key: "week", remaining: 100, resetAt: deadline.addingTimeInterval(86400), at: deadline, warning: 30))
    }

}
