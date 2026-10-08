import XCTest
@testable import DeepSeekIsland

final class ResetRefreshScheduleTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 10000)
    private func observation(_ metric: MenuBarMetric = .chatGPTFiveHour, remaining: Double = 0, deadline: Date? = nil, fresh: Bool = true) -> ResetQuotaObservation {
        ResetQuotaObservation(metric: metric, remaining: remaining, resetAt: deadline ?? reset, fresh: fresh)
    }
    func testChecksAtResetAndRetriesOnlyThreeTimes() {
        var schedule = ResetRefreshSchedule()
        schedule.reconcile([observation()], at: reset.addingTimeInterval(-60))
        XCTAssertTrue(schedule.duePlatforms(at: reset.addingTimeInterval(-1)).isEmpty)
        XCTAssertEqual(schedule.duePlatforms(at: reset), [.chatGPT])
        schedule.recordAttempt(for: .chatGPT, at: reset)
        XCTAssertTrue(schedule.duePlatforms(at: reset.addingTimeInterval(59)).isEmpty)
        XCTAssertEqual(schedule.duePlatforms(at: reset.addingTimeInterval(60)), [.chatGPT])
        schedule.recordAttempt(for: .chatGPT, at: reset.addingTimeInterval(60))
        XCTAssertTrue(schedule.duePlatforms(at: reset.addingTimeInterval(179)).isEmpty)
        XCTAssertEqual(schedule.duePlatforms(at: reset.addingTimeInterval(180)), [.chatGPT])
        schedule.recordAttempt(for: .chatGPT, at: reset.addingTimeInterval(180))
        XCTAssertTrue(schedule.duePlatforms(at: reset.addingTimeInterval(300)).isEmpty)
    }
    func testSamePlatformWindowsMergeAndFreshRecoveryStopsRetrying() {
        var schedule = ResetRefreshSchedule()
        schedule.reconcile([observation(), observation(.chatGPTWeek)], at: reset)
        XCTAssertEqual(schedule.duePlatforms(at: reset), [.chatGPT])
        schedule.recordAttempt(for: .chatGPT, at: reset)
        schedule.reconcile([observation(remaining: 80), observation(.chatGPTWeek, remaining: 90)], at: reset.addingTimeInterval(1))
        XCTAssertTrue(schedule.duePlatforms(at: reset.addingTimeInterval(60)).isEmpty)
    }
    func testRolledDeadlineAndFailureCacheDoNotCancelWaiting() {
        var schedule = ResetRefreshSchedule()
        schedule.reconcile([observation(remaining: 5)], at: reset)
        schedule.recordAttempt(for: .chatGPT, at: reset)
        schedule.reconcile([observation(remaining: 5, deadline: reset.addingTimeInterval(18000))], at: reset.addingTimeInterval(1))
        XCTAssertEqual(schedule.duePlatforms(at: reset.addingTimeInterval(60)), [.chatGPT])
        schedule.reconcile([observation(remaining: 100, fresh: false)], at: reset.addingTimeInterval(2))
        XCTAssertEqual(schedule.duePlatforms(at: reset.addingTimeInterval(60)), [.chatGPT])
        schedule.reconcile([], at: reset.addingTimeInterval(3))
        XCTAssertTrue(schedule.duePlatforms(at: reset.addingTimeInterval(60)).isEmpty)
    }
    func testHealthyAndVeryOldDeadlinesDoNotScheduleAndNewWindowCanSchedule() {
        var schedule = ResetRefreshSchedule()
        schedule.reconcile([observation(remaining: 80)], at: reset)
        XCTAssertTrue(schedule.duePlatforms(at: reset).isEmpty)
        schedule.reconcile([observation()], at: reset.addingTimeInterval(600))
        XCTAssertTrue(schedule.duePlatforms(at: reset.addingTimeInterval(600)).isEmpty)
        let next = reset.addingTimeInterval(18000)
        schedule.reconcile([observation(.zhipuWeek, deadline: next)], at: next.addingTimeInterval(-10))
        XCTAssertEqual(schedule.duePlatforms(at: next), [.zhipu])
    }
}
