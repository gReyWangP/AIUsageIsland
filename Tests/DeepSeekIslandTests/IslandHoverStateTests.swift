import AppKit
import XCTest
@testable import DeepSeekIsland

final class IslandHoverStateTests: XCTestCase {
    private let layout = NotchLayout(frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
        topLeft: NSRect(x: 0, y: 950, width: 663.5, height: 32),
        topRight: NSRect(x: 848.5, y: 950, width: 663.5, height: 32))
    private let compact = CGSize(width: 565, height: 87)
    private let detail = CGSize(width: 722, height: 466)
    private func inside(_ state: IslandHoverState, _ point: NSPoint, mode: IslandPresentation.Mode = .compact, pinned: Bool = false) -> Bool {
        state.shouldShow(in: layout, pointer: point, mode: mode, pinned: pinned,
                         compactSize: compact, detailSize: detail, excluding: nil)
    }

    @MainActor
    func testReturningToWingWithinHalfSecondDoesNotCancelHide() {
        var state = IslandHoverState()
        let start = Date(timeIntervalSince1970: 0)
        let wing = NSPoint(x: 920, y: 970)
        // 初次从刘海移向两侧仍能查看。
        XCTAssertTrue(inside(state, NSPoint(x: 756, y: 970)))
        XCTAssertTrue(inside(state, wing))
        XCTAssertFalse(state.shouldHide(pointerInside: false, at: start))
        // 0.1 秒后回到两侧，不应重新激活，也不重置原来的 0.5 秒收起时间。
        XCTAssertFalse(inside(state, wing))
        XCTAssertFalse(state.shouldHide(pointerInside: inside(state, wing), at: start.addingTimeInterval(0.1)))
        XCTAssertTrue(state.shouldHide(pointerInside: inside(state, wing), at: start.addingTimeInterval(0.51)))
        // 收起动画期间即使 NSPanel 仍可见，逻辑隐藏态也不能由两侧触发。
        XCTAssertFalse(inside(state, wing, mode: .hidden))
        XCTAssertTrue(inside(state, NSPoint(x: 756, y: 970), mode: .hidden))
    }

    @MainActor
    func testReturningToNotchResetsExitAndAllowsWingsAgain() {
        var state = IslandHoverState()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(state.shouldHide(pointerInside: false, at: start))
        XCTAssertTrue(inside(state, NSPoint(x: 756, y: 970)))
        XCTAssertFalse(state.shouldHide(pointerInside: true, at: start.addingTimeInterval(0.1)))
        XCTAssertTrue(inside(state, NSPoint(x: 920, y: 970)))
    }

    @MainActor
    func testDetailControlsAndPinStillRetainIsland() {
        var state = IslandHoverState()
        XCTAssertFalse(state.shouldHide(pointerInside: false, at: Date()))
        XCTAssertTrue(inside(state, NSPoint(x: 920, y: 700), mode: .expanded))
        XCTAssertTrue(inside(state, NSPoint(x: 10, y: 10), pinned: true))
    }
}
