import AppKit
import XCTest
@testable import DeepSeekIsland

final class StatusItemHoverTests: XCTestCase {
    func testStatusItemDoesNotRevealIslandEvenInsideOriginalTrigger() {
        let layout = NotchLayout(frame: NSRect(x: 0, y: 0, width: 1512, height: 982), topLeft: nil, topRight: nil)
        let item = NSRect(x: 700, y: 958, width: 28, height: 24)
        let pointer = NSPoint(x: 714, y: 970)
        XCTAssertTrue(layout.shouldShow(pointer: pointer, visible: false, expanded: false, pinned: false, compactSize: CGSize(width: 565, height: 55), detailSize: CGSize(width: 565, height: 400)))
        XCTAssertFalse(layout.shouldShow(pointer: pointer, visible: false, expanded: false, pinned: false, compactSize: CGSize(width: 565, height: 55), detailSize: CGSize(width: 565, height: 400), excluding: item))
        // 先触发刘海，再移到状态图标：展开和收起动画期间均不能保留或重新触发。
        for expanded in [false, true] {
            XCTAssertFalse(layout.shouldShow(pointer: pointer, visible: true, expanded: expanded, pinned: false, compactSize: CGSize(width: 565, height: 55), detailSize: CGSize(width: 565, height: 400), excluding: item))
        }
        XCTAssertTrue(layout.shouldShow(pointer: NSPoint(x: 756, y: 970), visible: false, expanded: false, pinned: false, compactSize: CGSize(width: 565, height: 55), detailSize: CGSize(width: 565, height: 400), excluding: item))
    }
    func testPinnedIslandStaysVisibleWhenPointerCrossesStatusItem() {
        let layout = NotchLayout(frame: NSRect(x: 0, y: 0, width: 1512, height: 982), topLeft: nil, topRight: nil)
        XCTAssertTrue(layout.shouldShow(pointer: NSPoint(x: 714, y: 970), visible: true, expanded: true, pinned: true, compactSize: CGSize(width: 565, height: 55), detailSize: CGSize(width: 565, height: 400), excluding: NSRect(x: 700, y: 958, width: 28, height: 24)))
    }
}
