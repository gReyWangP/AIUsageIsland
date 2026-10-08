import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class AppearanceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "AppearanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testExistingInstallKeepsDarkSolidAppearance() {
        let settings = IslandSettings(defaults: defaults())
        XCTAssertEqual(settings.appearanceMode, .dark)
        XCTAssertEqual(settings.backgroundEffect, .solid)
    }

    func testAppearanceChoicesPersistAcrossInstances() {
        let store = defaults()
        let settings = IslandSettings(defaults: store)
        settings.appearanceMode = .system
        settings.backgroundEffect = .glass
        let restored = IslandSettings(defaults: store)
        XCTAssertEqual(restored.appearanceMode, .system)
        XCTAssertEqual(restored.backgroundEffect, .glass)
    }

    func testSystemModeDoesNotForceColorScheme() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
    }

    func testReduceTransparencyOverridesGlassWithoutChangingPreference() {
        XCTAssertEqual(BackgroundEffect.glass.resolved(reduceTransparency: true), .solid)
        XCTAssertEqual(BackgroundEffect.glass.resolved(reduceTransparency: false), .glass)
        XCTAssertEqual(BackgroundEffect.solid.resolved(reduceTransparency: false), .solid)
    }

    func testGlassUsesBackdropFromBehindWindowEvenWhenInactive() {
        let effect = IslandVisualEffect.makeEffectView(colorScheme: .light)
        XCTAssertEqual(effect.blendingMode, .behindWindow)
        XCTAssertEqual(effect.state, .active)
    }
    func testSettingsOptionsRenderInsideBoundedScrollableWindow() throws {
        let settings = IslandSettings(defaults: defaults())
        let view = IslandSettingsView(settings: settings, model: IslandModel())
            .padding(18).frame(width: 680, height: 680)
        let image = try XCTUnwrap(ImageRenderer(content: view).cgImage)
        let delegate = AppDelegate()
        let window = delegate.makeSettingsWindow()
        defer { window.close() }
        XCTAssertEqual(image.width, 680)
        XCTAssertEqual(image.height, 680)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height, CGFloat(image.height))
    }

    func testSolidBackgroundActuallyChangesBetweenLightAndDark() throws {
        for (scheme, bright) in [(ColorScheme.light, true), (.dark, false)] {
            let image = try XCTUnwrap(ImageRenderer(content:
                IslandBackground(effect: .solid).frame(width: 20, height: 20)
                    .environment(\.colorScheme, scheme)).cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let color = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01)
            if bright { XCTAssertGreaterThan(color.redComponent, 0.9) }
            else { XCTAssertLessThan(color.redComponent, 0.05) }
        }
    }

    func testSettingsRenderInBothThemesAtSameSize() async throws {
        _ = NSApplication.shared
        let previousVersion = IslandBrand.versionOverride
        IslandBrand.versionOverride = "1.12.0"
        defer { IslandBrand.versionOverride = previousVersion }
        let settings = IslandSettings(defaults: defaults())
        settings.showsMenuBarItem = true
        settings.menuBarMetric = .chatGPTFiveHour
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        for mode in [AppearanceMode.light, .dark] {
          for style in MenuBarProgressStyle.allCases {
            settings.menuBarProgressStyle = style
            settings.appearanceMode = mode
            let view = IslandSettingsView(settings: settings, model: model)
                .padding(18).frame(width: 420)
                .background(IslandPalette(scheme: mode.colorScheme!).settings)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 756), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = mode.nsAppearance
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 756)
            try await Task.sleep(for: .milliseconds(80))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let corner = try XCTUnwrap(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
            if mode == .light { XCTAssertGreaterThan(corner.redComponent, 0.9) }
            else { XCTAssertLessThan(corner.redComponent, 0.15) }
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/dsi-appearance-\(mode.rawValue)-\(style.rawValue).png"))
            window.close()
          }
        }
    }
}
