import AppKit
import XCTest
@testable import DeepSeekIsland

@MainActor
final class AccountLoginWindowTests: XCTestCase {
    private func window(level: NSWindow.Level) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = level
        return window
    }
    func testCodingPlanLoginStaysAboveSettingsAndIsland() {
        let settings = AppDelegate().makeSettingsWindow()
        let login = ZhipuWebSession.makeLoginWindow(content: NSView(frame: NSRect(x: 0, y: 0, width: 850, height: 660)))
        defer { settings.close(); login.close() }
        XCTAssertGreaterThan(login.level.rawValue, settings.level.rawValue)
        XCTAssertGreaterThan(login.level.rawValue, NSWindow.Level.statusBar.rawValue)
        XCTAssertTrue(login.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(login.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(login.styleMask.contains(.closable))
    }
    func testBrowserAuthorizationTemporarilyLowersAppWindowsAndRestoresTheirLevels() {
        let settings = window(level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        let island = window(level: .statusBar)
        defer { settings.close(); island.close() }
        let state = BrowserAuthorizationWindowLevels()
        state.update(active: true, windows: [settings, island])
        XCTAssertEqual(settings.level, .normal)
        XCTAssertEqual(island.level, .normal)
        XCTAssertTrue(state.isActive)
        // Repeated published events must not overwrite the original levels with .normal.
        state.update(active: true, windows: [settings, island])
        state.update(active: false, windows: [settings, island])
        XCTAssertEqual(settings.level.rawValue, NSWindow.Level.statusBar.rawValue + 1)
        XCTAssertEqual(island.level, .statusBar)
        XCTAssertFalse(state.isActive)
    }
    func testBrowserAuthorizationDoesNotRevealPreviouslyHiddenWindows() {
        let settings = window(level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        defer { settings.close() }
        XCTAssertFalse(settings.isVisible)
        let state = BrowserAuthorizationWindowLevels()
        state.update(active: true, windows: [settings])
        state.update(active: false, windows: [settings])
        XCTAssertFalse(settings.isVisible)
    }
    func testSettingsCreatedDuringBrowserAuthorizationAreLoweredAndRestored() {
        let island = window(level: .statusBar)
        let state = BrowserAuthorizationWindowLevels()
        state.update(active: true, windows: [island])
        let settings = window(level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        defer { settings.close(); island.close() }
        state.update(active: true, windows: [settings, island])
        XCTAssertEqual(settings.level, .normal)
        state.update(active: false, windows: [settings, island])
        XCTAssertEqual(settings.level.rawValue, NSWindow.Level.statusBar.rawValue + 1)
        XCTAssertEqual(island.level, .statusBar)
    }
    func testNativeOrderingKeepsLoginInFrontWhenSettingsAndIslandAreRaisedAgain() throws {
        let settings = window(level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        let island = window(level: .statusBar)
        let login = ZhipuWebSession.makeLoginWindow(content: NSView(frame: NSRect(x: 0, y: 0, width: 850, height: 660)))
        defer { login.close(); settings.close(); island.close() }
        login.orderFrontRegardless()
        settings.orderFrontRegardless()
        island.orderFrontRegardless()
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.05))
        let order = NSApplication.shared.orderedWindows
        let loginIndex = try XCTUnwrap(order.firstIndex { $0 === login })
        let settingsIndex = try XCTUnwrap(order.firstIndex { $0 === settings })
        let islandIndex = try XCTUnwrap(order.firstIndex { $0 === island })
        XCTAssertLessThan(loginIndex, settingsIndex)
        XCTAssertLessThan(settingsIndex, islandIndex)
    }
}
