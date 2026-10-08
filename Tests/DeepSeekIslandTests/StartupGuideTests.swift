import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class StartupGuideTests: XCTestCase {
    func testStartupGuideDefaultsToVisibleAndOptOutPersists() {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        XCTAssertFalse(settings.hidesStartupGuide)
        settings.hidesStartupGuide = true
        XCTAssertTrue(IslandSettings(defaults: store).hidesStartupGuide)
        settings.hidesStartupGuide = false
        XCTAssertFalse(IslandSettings(defaults: store).hidesStartupGuide)
    }

    func testSinglePageGuideFitsSmallerWindowAndRendersInBothThemes() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        for mode in [AppearanceMode.light, .dark] {
            settings.appearanceMode = mode
            let view = IslandGuideView(settings: settings, onFinish: {})
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = mode.nsAppearance
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 500)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.fittingSize.width, 560)
            XCTAssertEqual(hosting.fittingSize.height, 500)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            // 固定视口底部必须仍有清晰控件，避免精简布局挤掉复选框和完成按钮。
            var footerInk = 0
            for y in (bitmap.pixelsHigh - 80)..<(bitmap.pixelsHigh - 25) {
                for x in stride(from: 40, to: bitmap.pixelsWide - 40, by: 4) {
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if mode == .dark ? color.redComponent > 0.5 : color.redComponent < 0.5 { footerInk += 1 }
                }
            }
            XCTAssertGreaterThan(footerInk, 100, "应保留底部引导控件")
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/dsi-startup-guide-\(mode.rawValue).png"))
            window.close()
        }
    }
}
