import XCTest
@testable import DeepSeekIsland

final class IslandWindowTransitionTests: XCTestCase {
    private let wide = CGRect(x: 200, y: 600, width: 600, height: 200)
    private let narrow = CGRect(x: 400, y: 700, width: 200, height: 100)

    func testShrinkingKeepsOutgoingContentUntilCompletion() {
        var transition = IslandWindowTransition()
        let envelope = transition.begin(from: wide, to: narrow, animated: true)
        XCTAssertEqual(envelope, wide)
        XCTAssertEqual(transition.complete(revision: transition.revision), narrow)
    }

    func testReverseTransitionRejectsPreviousCompletion() {
        var transition = IslandWindowTransition()
        let shrinking = transition.begin(from: wide, to: narrow, animated: true)
        let oldRevision = transition.revision
        _ = transition.begin(from: shrinking, to: wide, animated: true)
        XCTAssertNil(transition.complete(revision: oldRevision))
        XCTAssertEqual(transition.complete(revision: transition.revision), wide)
    }

    func testImmediateScreenMoveInvalidatesPreviousAnimation() {
        var transition = IslandWindowTransition()
        _ = transition.begin(from: wide, to: narrow, animated: true)
        let oldRevision = transition.revision
        let otherScreen = CGRect(x: 1600, y: 900, width: 200, height: 100)
        XCTAssertEqual(transition.begin(from: wide, to: otherScreen, animated: false), otherScreen)
        XCTAssertNil(transition.complete(revision: oldRevision))
    }

    func testCompletionCanOnlySettleOnce() {
        var transition = IslandWindowTransition()
        _ = transition.begin(from: wide, to: narrow, animated: true)
        let revision = transition.revision
        XCTAssertEqual(transition.complete(revision: revision), narrow)
        XCTAssertNil(transition.complete(revision: revision))
    }
}
