import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class OfficialResetCardTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-10-02T04:00:00Z")!
    func testPopoverKeepsIslandVisibleAndRestoresNormalHideDelayAfterClosing() {
        var hover = IslandHoverState()
        XCTAssertFalse(hover.shouldHide(pointerInside: false, at: now))
        XCTAssertFalse(hover.shouldHide(pointerInside: false, at: now.addingTimeInterval(20), holdingPopover: true))
        XCTAssertNil(hover.outsideSince)
        XCTAssertFalse(hover.shouldHide(pointerInside: false, at: now.addingTimeInterval(21)))
        XCTAssertTrue(hover.shouldHide(pointerInside: false, at: now.addingTimeInterval(22)))
    }
    func testCardOnlyUsesEnabledValidRecentAnnouncements() {
        let event = ResetReminderTests().event()
        XCTAssertNotNil(OfficialResetCardContent.make(event, enabled: true, now: now))
        XCTAssertNil(OfficialResetCardContent.make(nil, enabled: true, now: now))
        XCTAssertNil(OfficialResetCardContent.make(event, enabled: false, now: now))
        XCTAssertNil(OfficialResetCardContent.make(event, enabled: true, now: now.addingTimeInterval(8 * 86400)))
        let invalid = OfficialResetAnnouncement(id: "1", resetType: "regular", phase: .scheduled,
            announcedAt: now, scheduledFor: now.addingTimeInterval(3600), text: "test",
            sourceURL: URL(string: "https://example.com/not-official")!)
        XCTAssertNil(OfficialResetCardContent.make(invalid, enabled: true, now: now))
    }
    func testReportsExpireAfterOneDayWhileFuturePreannouncementsRemainVisible() {
        var reported = ResetReminderTests().event()
        reported.phase = .reported
        XCTAssertNotNil(OfficialResetCardContent.make(reported, enabled: true,
            now: reported.announcedAt.addingTimeInterval(86400 - 1)))
        XCTAssertNil(OfficialResetCardContent.make(reported, enabled: true,
            now: reported.announcedAt.addingTimeInterval(86400 + 1)))
        let future = OfficialResetAnnouncement(id: reported.id, resetType: "regular", phase: .scheduled,
            announcedAt: reported.announcedAt, scheduledFor: reported.announcedAt.addingTimeInterval(2 * 86400),
            text: "A global reset is scheduled.", sourceURL: reported.sourceURL)
        XCTAssertNotNil(OfficialResetCardContent.make(future, enabled: true,
            now: future.announcedAt.addingTimeInterval(86400 + 1)))
        XCTAssertNil(OfficialResetCardContent.make(future, enabled: true,
            now: future.latestExpectedAt!.addingTimeInterval(1)))
    }
    func testPreannouncementPastDeadlineAndReportedNeverClaimAccountRecovery() throws {
        let event = ResetReminderTests().event(ambiguous: true)
        let upcoming = try XCTUnwrap(OfficialResetCardContent.make(event, enabled: true, now: now))
        XCTAssertTrue(upcoming.canReserve)
        XCTAssertTrue(upcoming.title.contains("预告"))
        XCTAssertTrue(upcoming.time.contains("北京时间"))
        let passed = try XCTUnwrap(OfficialResetCardContent.make(event, enabled: true, now: event.latestExpectedAt!.addingTimeInterval(1)))
        XCTAssertFalse(passed.canReserve)
        XCTAssertTrue(passed.detail.contains("等待确认"))
        var reported = event; reported.phase = .reported
        let result = try XCTUnwrap(OfficialResetCardContent.make(reported, enabled: true, now: now))
        XCTAssertFalse(result.canReserve)
        XCTAssertFalse(result.title.contains("已恢复"))
        XCTAssertTrue(result.detail.contains("账号"))
        let banked = OfficialResetAnnouncement(id: event.id, resetType: "banked", phase: .reported,
            announcedAt: event.announcedAt, scheduledFor: nil, text: event.text, sourceURL: event.sourceURL)
        XCTAssertTrue(try XCTUnwrap(OfficialResetCardContent.make(banked, enabled: true, now: now)).detail.contains("手动"))
    }
}
