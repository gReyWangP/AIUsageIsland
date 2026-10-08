import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class NewControlsRenderTests: XCTestCase {
    func testScheduleAndTodayMuteRenderInBothThemes() async throws {
        let name = UUID().uuidString; let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        settings.alertsEnabled = true; settings.alertsScheduleEnabled = true
        settings.snoozeRemindersToday()
        let alerts = UsageAlertsController(model: IslandModel(), settings: settings, onOpen: {}, defaults: store, backend: UsageAlertsControllerTests.Notifications())
        for mode in [AppearanceMode.light, .dark] {
            let view = ReminderSettingsView(settings: settings, alerts: alerts).font(.system(size: 11)).toggleStyle(.checkbox)
                .padding(18).frame(width: 420, height: 250, alignment: .topLeading)
                .background(mode == .light ? Color.white : Color.black).environment(\.colorScheme, mode.colorScheme!)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 250), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = mode.nsAppearance
            window.contentView = hosting; hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 250)
            try await Task.sleep(for: .milliseconds(80)); hosting.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(hosting.fittingSize.height, 250)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/dsi-reminder-controls-\(mode.rawValue).png"))
            window.close()
        }
    }
    func testAutoIconsRenderWithStableNativeLabels() throws {
        let board = NSImage(size: NSSize(width: 250, height: 80), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 250, height: 40).fill()
            for dark in [false, true] {
                for (index, metric) in [MenuBarMetric.chatGPTFiveHour, .chatGPTWeek, .zhipuFiveHour, .zhipuWeek].enumerated() {
                    let image = MenuBarRenderer.autoImage(platform: metric.platform, data: .quota(remaining: 15, window: metric.windowLabel), dark: dark, style: index > 1 ? .waterLevel : .ring)
                    image.draw(at: NSPoint(x: 15 + index * 58, y: dark ? 10 : 50), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(board.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/dsi-auto-window-icons.png"))
    }
}
