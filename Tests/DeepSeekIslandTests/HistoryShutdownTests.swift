import XCTest
@testable import DeepSeekIsland

@MainActor
final class HistoryShutdownTests: XCTestCase {
    func testNormalFlushCompletesWithoutWaitingForDeadlineAndOnlyOnce() async throws {
        let shutdown = HistoryShutdown()
        var replies = 0
        shutdown.begin(timeout: 0.08, flush: {}) { replies += 1 }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(replies, 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(replies, 1)
    }
    func testSlowFlushUsesDeadlineAndLateCompletionCannotReplyAgain() async throws {
        let shutdown = HistoryShutdown()
        var replies = 0
        shutdown.begin(timeout: 0.02, flush: { try? await Task.sleep(for: .milliseconds(100)) }) { replies += 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(replies, 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(replies, 1)
    }
}
