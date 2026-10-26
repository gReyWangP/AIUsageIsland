import XCTest
import SwiftUI
import AppKit
@testable import DeepSeekIsland

@MainActor final class SideDockTests: XCTestCase {
    func testModePersistsAndPreservesFloatingPlacement() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: defaults)
        XCTAssertEqual(settings.displayMode, .island)
        settings.floatingStatusPlacement = .init(edge: .left, y: 0.2)
        settings.displayMode = .sideDock
        let restored = IslandSettings(defaults: defaults)
        XCTAssertEqual(restored.displayMode, .sideDock)
        XCTAssertFalse(restored.sideDockOnLeft)
        restored.displayMode = .floating
        XCTAssertFalse(restored.sideDockEnabled)
        XCTAssertEqual(restored.floatingStatusPlacement.y, 0.2)
    }
    func testAutoHideIsIndependentOfFloatingModeAndPersists() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: defaults)
        settings.displayMode = .sideDock
        XCTAssertFalse(settings.floatingStatusAutoHides)
        settings.floatingStatusAlwaysExpanded = true
        settings.sideDockAutoHide = true
        XCTAssertTrue(settings.floatingStatusAutoHides)
        let restored = IslandSettings(defaults: defaults)
        XCTAssertTrue(restored.sideDockAutoHide)
        XCTAssertTrue(restored.floatingStatusAutoHides)
        restored.displayMode = .floating
        XCTAssertFalse(restored.floatingStatusAutoHides)
    }

    func testSideDockCollapsesRevealsAndSwitchesToFixed() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let settings = IslandSettings(defaults: defaults)
        settings.displayMode = .sideDock
        settings.sideDockAutoHide = true
        settings.floatingStatusAlwaysExpanded = true
        settings.pausesHoverInFullscreen = false
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false
        let controller = FloatingStatusController(model: model, settings: settings)
        defer { controller.stop() }
        let outside = CGPoint(x: -100000, y: -100000)
        let now = Date.now
        for left in [false, true] {
            settings.sideDockOnLeft = left
            controller.update(pointer: outside, at: now)
            controller.update(pointer: outside, at: now.addingTimeInterval(1))
            try await Task.sleep(for: .milliseconds(350))
            let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is NSHostingView<FloatingStatusView> })
            let host = try XCTUnwrap(panel.contentView as? NSHostingView<FloatingStatusView>)
            XCTAssertTrue(host.rootView.surface.collapsed)
            XCTAssertEqual(panel.frame.width, 8, accuracy: 1)
            let trigger = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            controller.update(pointer: trigger, at: now.addingTimeInterval(2))
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertFalse(host.rootView.surface.collapsed)
            XCTAssertEqual(panel.frame.width, SideDockLayout.width, accuracy: 1)
            // Switching while tucked must immediately reveal, regardless of the old floating preference.
            controller.update(pointer: outside, at: now.addingTimeInterval(3))
            controller.update(pointer: outside, at: now.addingTimeInterval(4))
            settings.sideDockAutoHide = false
            controller.update(pointer: outside, at: now.addingTimeInterval(5))
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertFalse(host.rootView.surface.collapsed)
            XCTAssertEqual(panel.frame.width, SideDockLayout.width, accuracy: 1)
            settings.sideDockAutoHide = true
        }
    }

    func testSideDockFollowsDisplayedAccountsAndClosesRemovedCard() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let settings = IslandSettings(defaults: defaults)
        settings.displayMode = .sideDock
        settings.sideDockOnLeft = false
        settings.sideDockAutoHide = false
        settings.pausesHoverInFullscreen = false
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.presentationSettings = settings
        model.networkAvailable = false
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek, .chatGPT, .zhipu])
        let controller = FloatingStatusController(model: model, settings: settings)
        defer { controller.stop() }
        let outside = CGPoint(x: -100000, y: -100000)
        controller.update(pointer: outside)
        try await Task.sleep(for: .milliseconds(400))
        let screen = try XCTUnwrap(NSScreen.main)
        let dock = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is NSHostingView<FloatingStatusView> })
        XCTAssertEqual(dock.frame.height,
                       SideDockLayout.frame(in: screen.visibleFrame, count: 3, onLeft: false).height, accuracy: 1)

        let zhipu = try XCTUnwrap(model.savedAccounts.first { $0.platform == .zhipu })
        controller.showDetails(account: zhipu)
        try await Task.sleep(for: .milliseconds(150))
        let card = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentViewController is NSHostingController<MenuBarPopoverView> })
        XCTAssertTrue(card.isVisible)

        model.setAccountVisible(zhipu, visible: false)
        controller.update(pointer: outside, at: .now.addingTimeInterval(1))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.visiblePlatforms, [.deepSeek, .chatGPT])
        XCTAssertFalse(card.isVisible)
        XCTAssertEqual(dock.frame.height,
                       SideDockLayout.frame(in: screen.visibleFrame, count: 2, onLeft: false).height, accuracy: 1)

        model.setAccountVisible(zhipu, visible: true)
        controller.update(pointer: outside, at: .now.addingTimeInterval(2))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(dock.frame.height,
                       SideDockLayout.frame(in: screen.visibleFrame, count: 3, onLeft: false).height, accuracy: 1)
    }

    func testSideDockDragsVerticallyAndPersistsPosition() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let settings = IslandSettings(defaults: defaults)
        settings.displayMode = .sideDock
        settings.sideDockOnLeft = false
        settings.sideDockAutoHide = false
        settings.pausesHoverInFullscreen = false
        let screen = try XCTUnwrap(NSScreen.screens.first)
        settings.floatingStatusPlacement = FloatingStatusPlacement(
            edge: .right, x: 0.5, y: 0.5, displayID: ScreenTarget.displayID(of: screen))
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.presentationSettings = settings
        model.networkAvailable = false
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek, .chatGPT, .zhipu])
        let controller = FloatingStatusController(model: model, settings: settings)
        defer { controller.stop() }
        let outside = CGPoint(x: -100000, y: -100000)
        controller.update(pointer: outside)
        try await Task.sleep(for: .milliseconds(400))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is NSHostingView<FloatingStatusView> })
        let original = panel.frame
        let start = CGPoint(x: original.midX, y: original.midY)
        let end = CGPoint(x: start.x, y: start.y - 80)
        controller.drag(to: start, ended: false)
        controller.drag(to: end, ended: false)
        controller.drag(to: end, ended: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(panel.frame.minX, original.minX, accuracy: 1)
        XCTAssertEqual(panel.frame.width, original.width, accuracy: 1)
        XCTAssertLessThan(panel.frame.midY, original.midY - 60)
        XCTAssertNotEqual(settings.sideDockY, 0.5, accuracy: 0.001)

        let persisted = settings.sideDockY
        controller.update(pointer: outside, at: .now.addingTimeInterval(2))
        try await Task.sleep(for: .milliseconds(350))
        let expectedY = SideDockLayout.frame(in: screen.visibleFrame, count: 3, onLeft: false,
                                             verticalPosition: CGFloat(persisted)).midY
        XCTAssertEqual(panel.frame.midY, expectedY, accuracy: 2)

        settings.sideDockOnLeft = true
        controller.update(pointer: outside, at: .now.addingTimeInterval(3))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(panel.frame.minX, screen.visibleFrame.minX, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, expectedY, accuracy: 2)
    }

    func testCurveDepthChangesShoulderHeight() {
        let rect = CGRect(x: 0, y: 0, width: 62, height: 370)
        let shallow = SideDockShape(docked: true, onLeft: false, curveDepth: 16).path(in: rect)
        let deep = SideDockShape(docked: true, onLeft: false, curveDepth: 62).path(in: rect)
        XCTAssertTrue(shallow.contains(CGPoint(x: 20, y: 20)))
        XCTAssertFalse(deep.contains(CGPoint(x: 20, y: 20)))
    }

    func testLowCurveDepthKeepsLineStraightWhileRoundingInnerCorner() {
        let rect = CGRect(x: 0, y: 0, width: 62, height: 370)
        let corner = SideDockShape(docked: true, onLeft: false, curveDepth: 20).path(in: rect)
        XCTAssertTrue(corner.contains(CGPoint(x: 58, y: 1)))
        XCTAssertFalse(corner.contains(CGPoint(x: 58, y: -1)))
        XCTAssertTrue(corner.contains(CGPoint(x: 1, y: 12)))
        XCTAssertFalse(corner.contains(CGPoint(x: 1, y: 2)))
    }

    func testSideDockPositionAndCurvePersist() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: defaults)
        settings.sideDockY = 0.23
        settings.sideDockCurveDepth = 21
        let restored = IslandSettings(defaults: defaults)
        XCTAssertEqual(restored.sideDockY, 0.23, accuracy: 0.0001)
        XCTAssertEqual(restored.sideDockCurveDepth, 21, accuracy: 0.0001)
    }

    func testDockTouchesBothEdgesAndFitsSmallDisplays() {
        let bounds = CGRect(x: -1200, y: 40, width: 1200, height: 700)
        let right = SideDockLayout.frame(in: bounds, count: 3, onLeft: false)
        XCTAssertEqual(right.maxX, bounds.maxX)
        XCTAssertEqual(right.midY, bounds.midY)
        XCTAssertEqual(SideDockLayout.frame(in: bounds, count: 3, onLeft: true).minX, bounds.minX)
        XCTAssertTrue(bounds.contains(SideDockLayout.frame(in: bounds, count: 100, onLeft: false)))
    }
    func testContinuousShouldersAndMirroredOutline() {
        let rect = CGRect(x: 10, y: 20, width: 62, height: 370)
        let right = SideDockShape(docked: true, onLeft: false, curveDepth: 62).path(in: rect)
        let left = SideDockShape(docked: true, onLeft: true, curveDepth: 62).path(in: rect)
        // Halfway down the transition, the boundary lies halfway across the bar.
        XCTAssertFalse(right.contains(CGPoint(x: 39, y: 50)))
        XCTAssertTrue(right.contains(CGPoint(x: 43, y: 52)))
        for x in stride(from: CGFloat(1), through: 61, by: 5) {
            for y in stride(from: CGFloat(1), through: 369, by: 7) {
                XCTAssertEqual(right.contains(CGPoint(x: rect.minX + x, y: rect.minY + y)),
                               left.contains(CGPoint(x: rect.maxX - x, y: rect.minY + y)))
            }
        }
    }

    func testRenderReferenceProportions() throws {
        let size = SideDockLayout.frame(in: CGRect(x: 0, y: 0, width: 1000, height: 800), count: 3, onLeft: false).size
        let samples: [(UsagePlatform, Double)] = [(.deepSeek, 73), (.chatGPT, 21), (.zhipu, 52)]
        let view = ZStack(alignment: .trailing) {
            LinearGradient(colors: [.cyan.opacity(0.65), .blue.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
            FloatingStatusFlowLayout(itemHeight: SideDockLayout.itemHeight, progress: 0) {
                ForEach(0..<samples.count, id: \.self) { index in
                    let sample = samples[index]
                    VStack(spacing: 8) {
                        Image(nsImage: MenuBarRenderer.image(platform: sample.0, data: .quota(remaining: sample.1), dark: true,
                              thickness: .standard, style: .ring, balanceAsRing: sample.0 == .deepSeek, preserveLogoColors: true))
                            .resizable().aspectRatio(contentMode: .fit).frame(width: 40, height: 38)
                        Text(String(format: "%.0f%%", sample.1)).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    }.frame(width: 48, height: SideDockLayout.itemHeight)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, SideDockLayout.contentInset)
            .frame(width: size.width, height: size.height)
            .background(.black)
            .clipShape(SideDockShape(docked: true, onLeft: false, curveDepth: SideDockLayout.defaultCurveDepth))
        }.frame(width: 260, height: 470)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/aiusage-side-dock-refined.png"))
    }

}
