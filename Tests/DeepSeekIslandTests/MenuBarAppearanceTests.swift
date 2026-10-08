import AppKit
import XCTest
@testable import DeepSeekIsland

@MainActor
final class MenuBarAppearanceTests: XCTestCase {
    func testAdaptiveImageSurvivesDisablingAndReenablingIcon() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: defaults)
        settings.showsMenuBarItem = true
        let controller = MenuBarStatusController(model: IslandModel(), settings: settings, onOpen: {})
        defer { settings.showsMenuBarItem = false; controller.update() }
        let removedButton = try XCTUnwrap(controller.statusButton)
        settings.showsMenuBarItem = false
        controller.update()
        XCTAssertNil(controller.statusButton)
        settings.showsMenuBarItem = true
        controller.update()
        let button = try XCTUnwrap(controller.statusButton)
        XCTAssertFalse(button === removedButton)
        button.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(80))
        let oldImage = try XCTUnwrap(button.image)
        removedButton.appearance = NSAppearance(named: .aqua)
        button.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(oldImage === button.image, "重新开启后应在绘制时适配外观，不替换图标")
    }
    func testMenuBarAppearanceChangesWithoutAppAppearanceOrDataChanges() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: defaults)
        settings.showsMenuBarItem = true
        settings.menuBarMetric = .chatGPTFiveHour
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        model.chatGPTConnected = true
        model.chatGPTLastUpdated = .now
        model.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18_000, usedPercent: 15, resetAt: nil), weekly: nil, email: nil, accountID: nil, limitReached: false)
        let controller = MenuBarStatusController(model: model, settings: settings, onOpen: {})
        defer { settings.showsMenuBarItem = false; controller.update() }
        let button = try XCTUnwrap(controller.statusButton)
        let appAppearance = NSApplication.shared.effectiveAppearance
        button.appearance = NSAppearance(named: .darkAqua)
        controller.update()
        for dark in [false, true, false] {
            let oldImage = try XCTUnwrap(button.image)
            button.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(80))
            let newImage = try XCTUnwrap(button.image)
            XCTAssertTrue(oldImage === newImage, "菜单栏绘制外观变化不能替换图标并触发复制重绘循环")
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(newImage.size.width * 2), pixelsHigh: Int(newImage.size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                newImage.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh),
                    from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            let sx = CGFloat(rep.pixelsWide) / newImage.size.width
            let sy = CGFloat(rep.pixelsHigh) / newImage.size.height
            var visibleLogoPixels = 0
            for y in Int(5 * sy)..<Int(13 * sy) {
                for x in Int(6 * sx)..<Int(14 * sx) {
                    let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    if color.alphaComponent > 0.3 && (dark ? brightness > 0.6 : brightness < 0.5) {
                        visibleLogoPixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(visibleLogoPixels, 8, "中心 Logo 应与当前菜单栏背景保持对比")
        }
        XCTAssertEqual(NSApplication.shared.effectiveAppearance, appAppearance)
    }
}
