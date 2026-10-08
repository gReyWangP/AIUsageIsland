import AppKit
import XCTest
@testable import DeepSeekIsland

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testSmallScreenSettingsFitBelowDetailPreview() {
        let frame = AppDelegate.settingsWindowFrame(visible: NSRect(x: 0, y: 40, width: 1366, height: 704),
            screenTop: 768, previewHeight: 384, titlebarHeight: 28)
        XCTAssertGreaterThanOrEqual(frame.minY, 40)
        XCTAssertLessThanOrEqual(frame.maxY, 768 - 384 - 16)
        XCTAssertEqual(frame.width, 680)
        let window = AppDelegate().makeSettingsWindow()
        defer { window.close() }
        window.setFrame(frame, display: true)
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.05))
        XCTAssertLessThan(window.contentLayoutRect.height, 360)
        XCTAssertLessThanOrEqual(window.frame.maxY, 768 - 384 - 16)
    }
    func testSettingsHaveBoundedContentSizeWithoutRoomForFullDetailCards() {
        let window = AppDelegate().makeSettingsWindow()
        defer { window.close() }
        XCTAssertEqual(window.contentLayoutRect.width, 680, accuracy: 1)
        XCTAssertEqual(window.contentLayoutRect.height, 680, accuracy: 1)
    }
    func testSettingsStayAboveIslandWhenWindowsOverlap() {
        let delegate = AppDelegate()
        let window = delegate.makeSettingsWindow()
        defer { window.close() }

        // 内屏居中后会与顶部详情重叠；预览会再次把 statusBar 面板置前。
        // 设置必须处于更高层级，不能仅靠打开时的 orderFront 保证可操作。
        XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.statusBar.rawValue)
    }
    func testTitlebarHasAnOpaqueBackground() throws {
        let delegate = AppDelegate()
        let window = delegate.makeSettingsWindow()
        defer { window.close() }
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertEqual(try XCTUnwrap(window.backgroundColor.usingColorSpace(.deviceRGB)).alphaComponent,
                       1, accuracy: 0.01)
    }

}
