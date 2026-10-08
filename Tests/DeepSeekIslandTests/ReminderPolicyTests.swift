import UserNotifications
import XCTest
@testable import DeepSeekIsland

@MainActor
final class ReminderPolicyTests: XCTestCase {
    private func settings() -> IslandSettings { IslandSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!) }
    func testWindowBoundariesAndOvernightAndEqualMeansAllDay() {
        let s = settings(); s.alertsScheduleEnabled = true
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        func date(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: hour, minute: minute))!
        }
        s.alertStartMinute = 9 * 60; s.alertEndMinute = 18 * 60
        XCTAssertFalse(s.allowsReminder(at: date(8,59), calendar: calendar))
        XCTAssertTrue(s.allowsReminder(at: date(9), calendar: calendar))
        XCTAssertFalse(s.allowsReminder(at: date(18), calendar: calendar))
        s.alertStartMinute = 22 * 60; s.alertEndMinute = 7 * 60
        XCTAssertTrue(s.allowsReminder(at: date(23), calendar: calendar))
        XCTAssertTrue(s.allowsReminder(at: date(6), calendar: calendar))
        XCTAssertFalse(s.allowsReminder(at: date(12), calendar: calendar))
        s.alertEndMinute = s.alertStartMinute
        XCTAssertTrue(s.allowsReminder(at: date(12), calendar: calendar))
    }
    func testTodayMutePersistsAndEndsAtLocalMidnight() {
        let name = UUID().uuidString; let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let s = IslandSettings(defaults: store)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
        s.snoozeRemindersToday(at: noon, calendar: calendar)
        let restored = IslandSettings(defaults: store)
        XCTAssertFalse(restored.allowsReminder(at: noon, calendar: calendar))
        XCTAssertEqual(calendar.component(.hour, from: restored.alertsSnoozedUntil!), 0)
        XCTAssertTrue(restored.allowsReminder(at: restored.alertsSnoozedUntil!, calendar: calendar))
        restored.alertsSnoozedUntil = nil
        XCTAssertTrue(restored.allowsReminder(at: noon, calendar: calendar))
        XCTAssertTrue(restored.lowAlertsEnabled); XCTAssertTrue(restored.recoveryAlertsEnabled)
        XCTAssertFalse(restored.alertsScheduleEnabled)
    }
    func testMutedCrossingDoesNotConsumeLowAlertCooldown() {
        var latch = UsageAlertLatch()
        let now = Date.now
        latch.seed(key: "x", severity: 0)
        XCTAssertFalse(latch.observe(key: "x", severity: 1, at: now, canNotify: false))
        XCTAssertFalse(latch.observe(key: "x", severity: 1, at: now, canNotify: true), "不补发")
        XCTAssertFalse(latch.observe(key: "x", severity: 0, at: now))
        XCTAssertTrue(latch.observe(key: "x", severity: 1, at: now.addingTimeInterval(1)))
    }
    final class DelayedNotifications: UsageNotificationBackend {
        var delayNext = true
        var started = false
        var release: CheckedContinuation<Void, Never>?
        var delivered = Set<String>()
        var attempts = 0
        func authorize() async throws -> Bool { true }
        func permissionText() async -> String { "已允许" }
        func deliver(_ message: UsageAlertMessage) async throws {
            started = true; attempts += 1
            if delayNext {
                delayNext = false
                await withCheckedContinuation { release = $0 }
            }
            delivered.insert(message.metric)
        }
        func clearNotifications() { delivered.removeAll() }
        func discard(metric: String) { delivered.remove(metric) }
    }
    func testSnoozeDuringDeliveryDiscardsLateArrivalAndDoesNotConsumeCooldown() async {
        await checkSnoozeRace(suspended: true)
    }
    func testSnoozeBeforeQueuedDeliveryDoesNotConsumeCooldown() async {
        await checkSnoozeRace(suspended: false)
    }
    func testOppositeEventSwitchKeepsInFlightNotification() async {
        for recovered in [false, true] {
            let name = UUID().uuidString; let store = UserDefaults(suiteName: name)!
            defer { store.removePersistentDomain(forName: name) }
            let s = IslandSettings(defaults: store); s.alertsEnabled = true; s.alertMetrics = [.chatGPTFiveHour]
            let m = IslandModel(); m.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
            m.chatGPTConnected = true; m.chatGPTLastUpdated = .now
            func quota(_ used: Double) {
                m.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: used, resetAt: nil), weekly: .init(windowSeconds: 604800, usedPercent: 0, resetAt: nil), email: nil, accountID: nil, limitReached: false)
            }
            quota(recovered ? 100 : 0)
            let backend = DelayedNotifications()
            let c = UsageAlertsController(model: m, settings: s, onOpen: {}, defaults: store, backend: backend)
            c.evaluate(); quota(recovered ? 0 : 85); c.evaluate()
            for _ in 0..<100 where !backend.started { await Task.yield() }
            XCTAssertTrue(backend.started)
            if recovered { s.lowAlertsEnabled = false } else { s.recoveryAlertsEnabled = false }
            backend.release?.resume(); backend.release = nil
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(backend.delivered, [MenuBarMetric.chatGPTFiveHour.rawValue], "另一类提醒开关不能丢弃当前通知")
        }
    }
    private func checkSnoozeRace(suspended: Bool) async {
        let name = UUID().uuidString; let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let s = IslandSettings(defaults: store); s.alertsEnabled = true; s.alertMetrics = [.chatGPTFiveHour]
        let m = IslandModel(); m.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        m.chatGPTConnected = true; m.chatGPTLastUpdated = .now
        func quota(_ used: Double) {
            m.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: used, resetAt: nil), weekly: .init(windowSeconds: 604800, usedPercent: 0, resetAt: nil), email: nil, accountID: nil, limitReached: false)
        }
        quota(0)
        let backend = DelayedNotifications(); backend.delayNext = suspended
        let c = UsageAlertsController(model: m, settings: s, onOpen: {}, defaults: store, backend: backend)
        c.evaluate(); quota(85); c.evaluate()
        if suspended {
            for _ in 0..<100 where !backend.started { await Task.yield() }
            XCTAssertTrue(backend.started)
        }
        c.handleNotificationAction(UsageNotificationAction.snoozeToday, metric: nil)
        s.alertsSnoozedUntil = nil
        backend.release?.resume(); backend.release = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(backend.delivered.isEmpty, "静默期间迟到的系统发送结果必须撤销")
        quota(0); c.evaluate(); quota(85); c.evaluate()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(backend.delivered, [MenuBarMetric.chatGPTFiveHour.rawValue])
        XCTAssertEqual(backend.attempts, suspended ? 2 : 1, "被丢弃的通知不消耗30分钟冷却")
    }
    func testNotificationPayloadAndActionsRetainMetricAndEventKind() {
        let category = SystemUsageNotifications.category()
        XCTAssertEqual(category.actions.map(\.identifier), [UsageNotificationAction.view, UsageNotificationAction.snoozeToday])
        XCTAssertTrue(category.actions[0].options.contains(.foreground))
        XCTAssertFalse(category.actions[1].options.contains(.foreground))
        let message = UsageAlertMessage(metric: MenuBarMetric.zhipuWeek.rawValue, title: "恢复", body: "该窗口已恢复", recovered: true)
        let content = SystemUsageNotifications.content(message)
        XCTAssertEqual(content.categoryIdentifier, category.identifier)
        XCTAssertEqual(content.userInfo["metric"] as? String, message.metric)
        XCTAssertEqual(content.userInfo["recovered"] as? Bool, true)
    }
    func testLowAndRecoverySwitchesAndSnoozeActionDoNotOpenDetails() async {
        let name = UUID().uuidString; let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let s = IslandSettings(defaults: store); s.alertsEnabled = true
        let m = IslandModel(); m.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        m.chatGPTConnected = true; m.chatGPTLastUpdated = .now
        func quota(_ used: Double) {
            m.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: used, resetAt: nil), weekly: .init(windowSeconds: 604800, usedPercent: 0, resetAt: nil), email: nil, accountID: nil, limitReached: false)
        }
        quota(0)
        let backend = UsageAlertsControllerTests.Notifications()
        var opened = 0
        let c = UsageAlertsController(model: m, settings: s, onOpen: { opened += 1 }, defaults: store, backend: backend)
        c.evaluate()
        s.lowAlertsEnabled = false; quota(100); c.evaluate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(backend.messages.isEmpty)
        quota(0); c.evaluate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 1)
        c.handleNotificationAction(UsageNotificationAction.snoozeToday, metric: .chatGPTFiveHour)
        XCTAssertEqual(opened, 0); XCTAssertNotNil(s.alertsSnoozedUntil)
        s.lowAlertsEnabled = true; quota(100); c.evaluate(); quota(0); c.evaluate()
        s.alertsSnoozedUntil = nil; c.evaluate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(backend.messages.count, 1, "恢复提醒后不补发静默期间事件")
        c.handleNotificationAction("unknown", metric: nil)
        XCTAssertEqual(opened, 0)
    }
}
