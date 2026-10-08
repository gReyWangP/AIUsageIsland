import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class MenuBarPopoverTests: XCTestCase {
    func testStatusClickUsesCardWithCentralAndHoverOffAndOutsideClickClosesIt() async throws {
        _ = NSApplication.shared
        let suite = "MenuBarClick." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        let settings = IslandSettings(defaults: defaults)
        settings.centralHoverEnabled = false; settings.menuBarHoverEnabled = false
        settings.showsMenuBarItem = true
        var centralOpens = 0
        let controller = MenuBarStatusController(model: model, settings: settings, onOpen: { centralOpens += 1 })
        defer { settings.showsMenuBarItem = false; controller.update() }
        try await Task.sleep(for: .milliseconds(100))
        controller.togglePopover()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.isPopoverVisible)
        XCTAssertEqual(centralOpens, 0)
        controller.checkPointer(at: NSPoint(x: -10000, y: -10000), hoverSuspended: true)
        XCTAssertTrue(controller.isPopoverVisible, "Opening settings suppresses hover, not an explicitly pinned card")
        controller.dismissPopoverIfOutside(at: NSPoint(x: -10000, y: -10000))
        XCTAssertFalse(controller.isPopoverVisible)
        controller.togglePopover()
        XCTAssertTrue(controller.isPopoverVisible)
        settings.showsMenuBarItem = false; controller.update()
        XCTAssertFalse(controller.isPopoverVisible)
    }
    func testEscapeClosesNativeCardWithoutRequiringSwiftUIFocus() async throws {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(originalPolicy) }
        let suite = "MenuBarEscape." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        let settings = IslandSettings(defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 500, y: 500, width: 28, height: 24), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        window.contentView = anchor; window.orderFrontRegardless()
        let popover = MenuBarPopoverController()
        defer { popover.close(); window.close() }
        let card = MenuBarPopoverView(model: model, settings: settings, source: model.selectedRuntime(for: .chatGPT),
            canRefresh: false, onRefresh: {}, onAnalysis: {}, onSettings: {}, onClose: { [weak popover] in popover?.close() })
        popover.show(card, relativeTo: anchor, appearance: nil)
        popover.focus()
        try await Task.sleep(for: .milliseconds(100))
        let focused = try XCTUnwrap(NSApp.windows.first { $0.frame == popover.screenFrame })
        XCTAssertTrue(popover.isVisible)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: focused.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(popover.isVisible)
    }
    func testActualCardWindowUsesSharedSolidAndGlassThemeWhileOpen() async throws {
        _ = NSApplication.shared
        let suite = "MenuBarTheme." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        let settings = IslandSettings(defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 500, y: 700, width: 28, height: 24), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        window.contentView = anchor; window.orderFrontRegardless()
        let popover = MenuBarPopoverController()
        defer { popover.close(); window.close() }
        let card = MenuBarPopoverView(model: model, settings: settings, source: model.selectedRuntime(for: .chatGPT),
            canRefresh: false, onRefresh: {}, onAnalysis: {}, onSettings: {})
        func effects(in view: NSView) -> [NSVisualEffectView] {
            ((view as? NSVisualEffectView).map { [$0] } ?? []) + view.subviews.flatMap { effects(in: $0) }
        }
        for appearance in [AppearanceMode.dark, .light] {
            settings.appearanceMode = appearance
            settings.backgroundEffect = .solid
            popover.show(card, relativeTo: anchor, appearance: appearance.nsAppearance)
            try await Task.sleep(for: .milliseconds(100))
            let cardWindow = try XCTUnwrap(NSApp.windows.first { $0.frame == popover.screenFrame })
            let content = try XCTUnwrap(cardWindow.contentView)
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let background = try XCTUnwrap(bitmap.colorAt(x: 20, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(background.alphaComponent, 1, accuracy: 0.01, "Solid theme must be opaque")
            XCTAssertEqual(background.redComponent, appearance == .dark ? 0 : 0.97, accuracy: 0.02,
                "Menu card must use the same surface as the central island")
            XCTAssertTrue(effects(in: content).isEmpty, "Solid theme must not retain native popover material")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/aiusage-actual-menubar-solid-\(appearance.rawValue).png"))
            settings.backgroundEffect = .glass
            popover.update(card, appearance: appearance.nsAppearance)
            try await Task.sleep(for: .milliseconds(100))
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                XCTAssertFalse(effects(in: content).isEmpty, "Glass preference must use the shared behind-window blur")
            }
            XCTAssertTrue(popover.isVisible)
        }
    }
    func testNativePopoverStaysOnAnchorScreenAtRightEdge() async throws {
        _ = NSApplication.shared
        let suite = "MenuBarPosition." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        let settings = IslandSettings(defaults: defaults)
        let source = model.selectedRuntime(for: .chatGPT)
        let card = MenuBarPopoverView(model: model, settings: settings, source: source,
            canRefresh: false, onRefresh: {}, onAnalysis: {}, onSettings: {})
        XCTAssertFalse(NSScreen.screens.isEmpty)
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: NSRect(x: screen.frame.maxX - 32, y: screen.frame.maxY - 26, width: 28, height: 24), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.level = .statusBar
            let anchor = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
            window.contentView = anchor
            window.orderFrontRegardless()
            let popover = MenuBarPopoverController()
            defer { popover.close(); window.close() }
            popover.show(card, relativeTo: anchor, appearance: NSAppearance(named: .aqua))
            try await Task.sleep(for: .milliseconds(100))
            let frame = try XCTUnwrap(popover.screenFrame)
            XCTAssertGreaterThanOrEqual(frame.minX, screen.frame.minX - 1)
            XCTAssertLessThanOrEqual(frame.maxX, screen.frame.maxX + 1)
            XCTAssertGreaterThanOrEqual(frame.minY, screen.visibleFrame.minY - 1)
            XCTAssertLessThanOrEqual(frame.maxY, window.frame.maxY + 1)
            window.setFrameOrigin(NSPoint(x: window.frame.minX - 300, y: window.frame.minY - 100))
            popover.reposition()
            let moved = try XCTUnwrap(popover.screenFrame)
            XCTAssertLessThan(moved.minX, frame.minX, "Pinned card must remain anchored when the status item moves")
            XCTAssertLessThan(moved.maxY, frame.maxY)
            XCTAssertLessThanOrEqual(moved.maxY, window.frame.minY - 5)
        }
    }
    func testCardFitsBothThemesAndAllPlatformsWithoutStartingPolling() async throws {
        _ = NSApplication.shared
        let suite = "MenuBarPopover." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        let settings = IslandSettings(defaults: defaults)
        model.platformAccounts = PlatformAccounts(enabled: Set(UsagePlatform.allCases))
        model.networkAvailable = true
        for platform in UsagePlatform.allCases {
            let source = model.selectedRuntime(for: platform)
            source.chatGPTConnected = true
            source.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18_000, usedPercent: 28, resetAt: .now.addingTimeInterval(3600)), weekly: .init(windowSeconds: 604_800, usedPercent: 55, resetAt: .now.addingTimeInterval(86400)), email: nil, accountID: nil, limitReached: false)
            source.chatGPTLastUpdated = .now
            source.zhipuConnected = true
            source.zhipuQuota = ZhipuQuota(kind: .tokens, level: nil, fiveHour: .init(usedPercent: 28, usedValue: nil, limitValue: nil, nextReset: .now.addingTimeInterval(3600)), week: .init(usedPercent: 55, usedValue: nil, limitValue: nil, nextReset: .now.addingTimeInterval(86400)))
            source.accountConnected = true; source.balance = 39.55
            for appearance in [AppearanceMode.light, .dark] {
                settings.appearanceMode = appearance
                let content = MenuBarPopoverView(model: model, settings: settings, source: source,
                    canRefresh: false, onRefresh: {}, onAnalysis: {}, onSettings: {})
                let hosting = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 340), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance.nsAppearance
                window.contentView = hosting
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(80))
                hosting.layoutSubtreeIfNeeded()
                let size = hosting.fittingSize
                XCTAssertEqual(size.width, 360)
                XCTAssertGreaterThan(size.height, 150)
                XCTAssertLessThan(size.height, 380)
                hosting.frame = NSRect(origin: .zero, size: size)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/aiusage-menubar-card-\(platform.rawValue)-\(appearance.rawValue).png"))
                XCTAssertFalse(source.hasStartedPolling)
            }
        }
    }
}
