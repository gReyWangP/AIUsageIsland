import XCTest
@testable import DeepSeekIsland

final class RefreshPolicyTests: XCTestCase {
    func testBackoffCancellationSuccessAndServerDeadline() {
        let now = Date(timeIntervalSince1970: 1000)
        var policy = RefreshPolicy()
        policy.record(.http(503), at: now)
        XCTAssertFalse(policy.canAttempt(at: now.addingTimeInterval(59)))
        XCTAssertTrue(policy.canAttempt(at: now.addingTimeInterval(60)))
        policy.record(.cancelled, at: now)
        XCTAssertEqual(policy.failures, 1)
        policy.record(.rateLimited(until: now.addingTimeInterval(600)), at: now)
        XCTAssertFalse(policy.canAttempt(at: now.addingTimeInterval(599), manual: true))
        policy.record(nil, at: now)
        XCTAssertTrue(policy.canAttempt(at: now))
        policy.record(.authorization, at: now)
        XCTAssertFalse(policy.canAttempt(at: now.addingTimeInterval(100000)))
        XCTAssertTrue(policy.canAttempt(at: now, manual: true))
    }
    func testAuxiliaryUsageAuthorizationDoesNotStopSuccessfulBalance() {
        XCTAssertNil(RefreshPolicy.balanceFailure(primary: nil, auxiliary: .authorization))
        XCTAssertNil(RefreshPolicy.balanceFailure(primary: nil, auxiliary: .noQuota))
        XCTAssertEqual(RefreshPolicy.balanceFailure(primary: .authorization, auxiliary: nil), .authorization)
        XCTAssertEqual(RefreshPolicy.balanceFailure(primary: nil, auxiliary: .http(429)), .http(429))
    }
    func testPlatformConcurrencyAndRelease() async {
        let limiter = PlatformRequestLimiter(limit: 2)
        let first = await limiter.acquire(.chatGPT), second = await limiter.acquire(.chatGPT)
        let third = await limiter.acquire(.chatGPT), other = await limiter.acquire(.deepSeek)
        XCTAssertTrue(first && second && other)
        XCTAssertFalse(third)
        await limiter.release(.chatGPT)
        let next = await limiter.acquire(.chatGPT)
        XCTAssertTrue(next)
    }
}
