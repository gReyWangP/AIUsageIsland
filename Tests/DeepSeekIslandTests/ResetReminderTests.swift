import XCTest
import UserNotifications
@testable import DeepSeekIsland

@MainActor
final class ResetReminderTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-10-02T04:00:00Z")!
    func event(ambiguous: Bool = false, shift: TimeInterval = 0) -> OfficialResetAnnouncement {
        .init(id: "2105843926221660585", resetType: "regular", phase: .scheduled,
              announcedAt: ISO8601DateFormatter().date(from: "2026-10-02T02:14:51Z")!,
              scheduledFor: ISO8601DateFormatter().date(from: "2026-10-02T17:00:00Z")!.addingTimeInterval(shift),
              text: ambiguous ? "Global reset landing tomorrow 10am PST for all paid ChatGPT accounts." : "A global reset is scheduled.",
              sourceURL: URL(string: "https://x.com/thsottiaux/status/2105843926221660585")!)
    }
    func testFutureExplicitAnnouncementOlderThan24HoursStillNotifiesOnce() {
        var e = event(); e.scheduledFor = now.addingTimeInterval(48 * 3600)
        let old = OfficialResetAnnouncement(id: e.id, resetType: e.resetType, phase: e.phase,
            announcedAt: now.addingTimeInterval(-30 * 3600), scheduledFor: e.scheduledFor, text: e.text, sourceURL: e.sourceURL)
        var ledger = OfficialResetLedger()
        XCTAssertEqual(ledger.observe([old], now: now, allowed: true).count, 1)
        XCTAssertTrue(ledger.observe([old], now: now.addingTimeInterval(3600), allowed: true).isEmpty)
    }
    func testDraftRequiresExplicitAmbiguousChoiceAndRejectsExpiredOrPastEarlyAlert() throws {
        let e = event(ambiguous: true)
        XCTAssertThrowsError(try ResetReminderPlan.make(event: e, selectedDate: nil, lead: .atTime, destination: .notification, now: now))
        let late = try XCTUnwrap(e.latestExpectedAt)
        let plan = try ResetReminderPlan.make(event: e, selectedDate: late, lead: .fifteenMinutesEarly, destination: .notification, now: now)
        XCTAssertEqual(plan.notifyAt, late.addingTimeInterval(-900))
        XCTAssertThrowsError(try ResetReminderPlan.make(event: e, selectedDate: late, lead: .fifteenMinutesEarly, destination: .notification, now: late.addingTimeInterval(-60)))
        XCTAssertThrowsError(try ResetReminderPlan.make(event: e, selectedDate: now.addingTimeInterval(300), lead: .atTime, destination: .notification, now: now))
    }
    func testNotificationSchedulesAbsoluteInstantAndDoesNotClaimRecovery() throws {
        let plan = try ResetReminderPlan.make(event: event(), selectedDate: nil, lead: .atTime, destination: .notification, now: now)
        let request = SystemResetReminderBackend.request(for: plan)
        XCTAssertEqual(request.identifier, ResetReminderAction.requestID)
        XCTAssertEqual(request.content.categoryIdentifier, ResetReminderAction.category)
        XCTAssertTrue(request.content.body.contains("请检查"))
        XCTAssertFalse(request.content.title.contains("已恢复"))
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.timeZone?.secondsFromGMT(), 0)
        XCTAssertEqual(trigger.dateComponents.hour, 17)
    }
    final class Backend: ResetReminderBackend {
        var saved: [ResetReminderPlan] = []
        var previous: [ResetReminderRecord?] = []
        var cancelled: [ResetReminderRecord] = []
        var fail = false
        func put(_ plan: ResetReminderPlan, replacing old: ResetReminderRecord?) async throws -> String? {
            if fail { throw URLError(.notConnectedToInternet) }
            saved.append(plan); previous.append(old)
            return plan.destination == .reminders ? "our-reminder-id" : nil
        }
        func cancel(_ record: ResetReminderRecord) async throws { cancelled.append(record) }
    }
    func testPersistedSingleAppointmentUpdateAndCancellation() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!, backend = Backend()
        let controller = ResetReminderController(defaults: defaults, backend: backend)
        let plan = try ResetReminderPlan.make(event: event(), selectedDate: nil, lead: .atTime, destination: .notification, now: now)
        await controller.save(plan, now: now)
        XCTAssertNotNil(controller.record)
        let restored = ResetReminderController(defaults: defaults, backend: backend)
        XCTAssertEqual(restored.record?.plan, plan)
        let later = event(shift: 3600)
        XCTAssertTrue(restored.needsUpdate(for: later, now: now))
        let next = try ResetReminderPlan.make(event: later, selectedDate: nil, lead: .fifteenMinutesEarly, destination: .reminders, now: now)
        await restored.save(next, now: now)
        XCTAssertEqual(backend.saved.count, 2)
        XCTAssertEqual(backend.previous.last??.plan, plan)
        XCTAssertEqual(restored.record?.externalID, "our-reminder-id")
        await restored.cancel()
        XCTAssertNil(restored.record)
        XCTAssertNil(ResetReminderController(defaults: defaults, backend: backend).record)
    }
    func testFailedCreationPreservesExistingAppointment() async throws {
        let backend = Backend()
        let plan = try ResetReminderPlan.make(event: event(), selectedDate: nil, lead: .atTime, destination: .notification, now: now)
        let c = ResetReminderController(defaults: UserDefaults(suiteName: UUID().uuidString)!, backend: backend)
        await c.save(plan, now: now); backend.fail = true
        let later = try ResetReminderPlan.make(event: event(shift: 3600), selectedDate: nil, lead: .atTime, destination: .reminders, now: now)
        await c.save(later, now: now)
        XCTAssertEqual(c.record?.plan, plan); XCTAssertNotNil(c.error)
    }
    func testDelayIsSuggestedEvenAfterOldAppointmentTimePassed() async throws {
        let backend = Backend()
        let c = ResetReminderController(defaults: UserDefaults(suiteName: UUID().uuidString)!, backend: backend)
        let plan = try ResetReminderPlan.make(event: event(), selectedDate: nil, lead: .atTime, destination: .notification, now: now)
        await c.save(plan, now: now)
        XCTAssertTrue(c.needsUpdate(for: event(shift: 3600), now: plan.notifyAt.addingTimeInterval(60)))
    }
    func testExpiredAfterPermissionWaitCannotBeWritten() throws {
        let plan = try ResetReminderPlan.make(event: event(), selectedDate: nil, lead: .atTime, destination: .notification, now: now)
        XCTAssertNoThrow(try SystemResetReminderBackend.validateDeadline(plan, now: now))
        XCTAssertThrowsError(try SystemResetReminderBackend.validateDeadline(plan, now: plan.notifyAt.addingTimeInterval(60)))
    }
    final class WaitingBackend: ResetReminderBackend {
        var writes = 0
        var continuation: CheckedContinuation<Void, Never>?
        func put(_ plan: ResetReminderPlan, replacing old: ResetReminderRecord?) async throws -> String? {
            writes += 1
            await withCheckedContinuation { continuation = $0 }
            return nil
        }
        func cancel(_ record: ResetReminderRecord) async throws { XCTFail("Cannot cancel during save") }
    }
    func testRepeatedClicksAndCancelDuringSaveCannotRace() async throws {
        let backend = WaitingBackend()
        let controller = ResetReminderController(defaults: UserDefaults(suiteName: UUID().uuidString)!, backend: backend)
        let plan = try ResetReminderPlan.make(event: event(), selectedDate: nil, lead: .atTime, destination: .notification, now: now)
        let first = Task { await controller.save(plan, now: now) }
        while backend.continuation == nil { await Task.yield() }
        XCTAssertTrue(controller.busy)
        await controller.save(plan, now: now)
        await controller.cancel()
        XCTAssertEqual(backend.writes, 1)
        backend.continuation?.resume(); await first.value
        await controller.save(plan, now: now)
        XCTAssertEqual(backend.writes, 1)
        XCTAssertEqual(controller.record?.plan, plan)
    }
    func testPayloadRestoresOriginalEventForScheduleAction() throws {
        let content = SystemUsageNotifications.content(event(ambiguous: true).message)
        XCTAssertEqual(content.categoryIdentifier, OfficialResetAction.scheduledCategory)
        XCTAssertNotNil(content.userInfo["resetEventJSON"])
        XCTAssertTrue(SystemUsageNotifications.officialScheduledCategory().actions.contains { $0.identifier == OfficialResetAction.remind })
    }
}
