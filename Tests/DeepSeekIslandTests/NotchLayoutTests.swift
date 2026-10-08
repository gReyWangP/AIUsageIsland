import AppKit
import XCTest
@testable import DeepSeekIsland

/// `NotchLayout` 现在只负责**锚点与触发**，不再计算面板尺寸——
/// 尺寸由 IslandView 实测后上报。这里验证锚点、触发区与判定区的正确性。
final class NotchLayoutTests: XCTestCase {

    /// 14″ 内建屏：1512×982，刘海 185 宽、32 高。
    private var notched: NotchLayout {
        NotchLayout(
            frame: NSRect(x: 2560, y: 0, width: 1512, height: 982),
            topLeft: NSRect(x: 2560, y: 950, width: 663.5, height: 32),
            topRight: NSRect(x: 3408.5, y: 950, width: 663.5, height: 32)
        )
    }

    /// 外接 27″：2560×1440，无刘海。
    private var external: NotchLayout {
        NotchLayout(
            frame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
            topLeft: nil,
            topRight: nil
        )
    }

    // MARK: - 锚点

    func testNotchedAnchorAndTrigger() {
        let layout = notched
        XCTAssertTrue(layout.hasNotch)
        XCTAssertEqual(layout.triggerRect, NSRect(x: 3223.5, y: 950, width: 185, height: 32))
        XCTAssertEqual(layout.notchWidth, 185)
        XCTAssertEqual(layout.bandHeight, 32)
        XCTAssertEqual(layout.anchorCenterX, 3316)
        XCTAssertEqual(layout.topInset, 41, "刘海屏要让开摄像头")
        XCTAssertEqual(layout.screenTop, 982)
    }

    func testExternalAnchorAndTrigger() {
        let layout = external
        XCTAssertFalse(layout.hasNotch)
        XCTAssertEqual(layout.notchWidth, 0)
        XCTAssertEqual(layout.bandHeight, 38)
        XCTAssertEqual(layout.anchorCenterX, 1280)
        XCTAssertEqual(layout.topInset, 14, "外接屏不需要让开摄像头")
        XCTAssertEqual(layout.triggerRect.width, NotchLayout.externalBarWidth)
        XCTAssertEqual(layout.triggerRect.midX, 1280)
    }

    func testHorizontalBarWidthFollowsNotch() {
        XCTAssertEqual(notched.horizontalBarWidth, 185 + 2 * notched.wingWidth)
        XCTAssertEqual(external.horizontalBarWidth, NotchLayout.externalBarWidth)
    }

    // MARK: - 面板矩形

    /// 面板水平居中、贴着屏幕顶边；尺寸完全由传入的实测值决定。
    func testFramesAreCenteredAndTopAnchored() {
        for layout in [notched, external] {
            let compact = CGSize(width: 565, height: 87)
            let detail = CGSize(width: 722, height: 440)

            let compactFrame = layout.compactFrame(size: compact)
            XCTAssertEqual(compactFrame.width, compact.width)
            XCTAssertEqual(compactFrame.height, compact.height)
            XCTAssertEqual(compactFrame.midX, layout.anchorCenterX)
            XCTAssertEqual(compactFrame.maxY, layout.screenTop, "应贴住屏幕顶边")

            let detailFrame = layout.detailFrame(size: detail)
            XCTAssertEqual(detailFrame.width, detail.width)
            XCTAssertEqual(detailFrame.height, detail.height)
            XCTAssertEqual(detailFrame.midX, layout.anchorCenterX)
            XCTAssertEqual(detailFrame.maxY, layout.screenTop)
        }
    }

    /// 换排版、加平台都会改变实测尺寸——面板必须跟着走，而不是被写死的常量卡住。
    func testFramesFollowMeasuredSize() {
        let layout = notched
        let small = layout.detailFrame(size: CGSize(width: 565, height: 300))
        let large = layout.detailFrame(size: CGSize(width: 722, height: 500))
        XCTAssertEqual(large.height - small.height, 200)
        XCTAssertEqual(large.width - small.width, 157)
        XCTAssertEqual(small.maxY, large.maxY, "顶部始终对齐屏幕顶边")
    }

    // MARK: - 判定区

    /// 判定区必须覆盖整块面板。
    ///
    /// 旧版用「是否都已登录」决定判定区、却用「是否已启用两个平台」决定卡片尺寸，
    /// 两者不一致时卡片四角会被判为"已离开"。现在判定区就是面板 frame。
    func testHitAreaCoversWholePanel() {
        let layout = notched
        let detail = CGSize(width: 722, height: 440)
        let frame = layout.detailFrame(size: detail)

        for point in [NSPoint(x: frame.minX + 2, y: frame.minY + 2),
                      NSPoint(x: frame.maxX - 2, y: frame.minY + 2),
                      NSPoint(x: frame.minX + 2, y: frame.maxY - 2),
                      NSPoint(x: frame.maxX - 2, y: frame.maxY - 2),
                      NSPoint(x: frame.midX, y: frame.midY)] {
            XCTAssertTrue(layout.shouldShow(pointer: point, visible: true, expanded: true,
                                            pinned: false,
                                            compactSize: CGSize(width: 565, height: 87),
                                            detailSize: detail),
                          "\(point) 在面板内却被判为离开")
        }
    }

    func testHitAreaFollowsCompactAndDetailSizes() {
        let layout = notched
        let compact = CGSize(width: 565, height: 87)
        let detail = CGSize(width: 722, height: 440)
        let compactFrame = layout.compactFrame(size: compact)
        let wings = NSPoint(x: compactFrame.minX + 8, y: compactFrame.midY)

        // 只在悬浮条内：compact 可见时保持，expanded 时也保持（悬浮条仍属面板）
        XCTAssertTrue(layout.shouldShow(pointer: wings, visible: true, expanded: false,
                                        pinned: false, compactSize: compact, detailSize: detail))
        XCTAssertFalse(layout.shouldShow(pointer: wings, visible: false, expanded: false,
                                         pinned: false, compactSize: compact, detailSize: detail),
                       "完全隐藏时不该被悬浮条区域触发")
    }

    func testNotchRegionTriggersEvenWhenHidden() {
        let layout = notched
        let compact = CGSize(width: 565, height: 87)
        let detail = CGSize(width: 722, height: 440)
        XCTAssertTrue(layout.shouldShow(pointer: NSPoint(x: 3316, y: 965),
                                        visible: false, expanded: false, pinned: false,
                                        compactSize: compact, detailSize: detail))
        // 屏幕顶边内仍触发，边距不能越界触发另一块屏幕
        XCTAssertTrue(layout.shouldShow(pointer: NSPoint(x: 3316, y: 981),
                                        visible: false, expanded: false, pinned: false,
                                        compactSize: compact, detailSize: detail))
    }

    func testPinKeepsVisibleAnywhere() {
        let layout = notched
        XCTAssertTrue(layout.shouldShow(pointer: NSPoint(x: 100, y: 100),
                                        visible: true, expanded: true, pinned: true,
                                        compactSize: .zero, detailSize: .zero))
    }

    func testExternalTopEdgeTriggers() {
        let layout = external
        let compact = CGSize(width: 565, height: 55)
        XCTAssertTrue(layout.shouldShow(pointer: NSPoint(x: 1280, y: 1438),
                                        visible: false, expanded: false, pinned: false,
                                        compactSize: compact, detailSize: .zero))
        XCTAssertFalse(layout.shouldShow(pointer: NSPoint(x: 1280, y: 1300),
                                         visible: false, expanded: false, pinned: false,
                                         compactSize: compact, detailSize: .zero))
    }

    func testCameraGapIsClickTargetAcrossItsWholeWidth() {
        let layout = notched
        XCTAssertTrue(layout.acceptsCameraClick(NSPoint(x: layout.triggerRect.minX + 1, y: 965)))
        XCTAssertTrue(layout.acceptsCameraClick(NSPoint(x: layout.triggerRect.midX, y: 965)))
        XCTAssertTrue(layout.acceptsCameraClick(NSPoint(x: layout.triggerRect.maxX - 1, y: 965)))
        XCTAssertFalse(layout.acceptsCameraClick(NSPoint(x: layout.triggerRect.minX - 1, y: 965)))
        XCTAssertFalse(external.acceptsCameraClick(NSPoint(x: 1280, y: 1430)))
    }
}
