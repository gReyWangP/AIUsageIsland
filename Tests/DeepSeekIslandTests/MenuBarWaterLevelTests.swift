import AppKit
import XCTest
@testable import DeepSeekIsland

@MainActor
final class MenuBarWaterLevelTests: XCTestCase {
    func testStyleDefaultsToRingAndPersistsWaterLevel() throws {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        XCTAssertEqual(settings.menuBarProgressStyle, .ring)
        settings.menuBarProgressStyle = .waterLevel
        XCTAssertEqual(IslandSettings(defaults: store).menuBarProgressStyle, .waterLevel)
        store.set("invalid", forKey: "menuBarProgressStyle")
        XCTAssertEqual(IslandSettings(defaults: store).menuBarProgressStyle, .ring)
        let balance = MenuBarData.balance(amount: 39, currency: "CNY")
        let ring = MenuBarRenderer.image(platform: .deepSeek, data: balance, dark: false, style: .ring)
        let water = MenuBarRenderer.image(platform: .deepSeek, data: balance, dark: false, style: .waterLevel)
        XCTAssertEqual(try XCTUnwrap(ring.tiffRepresentation), try XCTUnwrap(water.tiffRepresentation), "套餐进度样式不能改变余额图标")
    }

    func testWaterFillDoesNotWashOutAgainstWallpaper() throws {
        for dark in [false, true] {
            for remaining in [15.0, 50, 100] {
                let image = MenuBarRenderer.image(platform: .chatGPT, data: .quota(remaining: remaining), dark: dark, style: .waterLevel)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                let sx = CGFloat(bitmap.pixelsWide) / 20, sy = CGFloat(bitmap.pixelsHigh) / 18
                let fill = try XCTUnwrap(bitmap.colorAt(x: Int(10*sx), y: Int(15.5*sy)))
                XCTAssertGreaterThan(fill.alphaComponent, 0.95, "水位内部不能依赖壁纸颜色，避免看起来像空容器")
            }
        }
    }

    func testWaterFillsFromBottomAndGrowsWithRemainingQuota() throws {
        for dark in [false, true] {
            var counts: [Int] = []
            for remaining in [50.0, 83.0, 100.0] {
                let image = MenuBarRenderer.image(platform: .chatGPT, data: .quota(remaining: remaining), dark: dark, style: .waterLevel)
                XCTAssertEqual(image.size, NSSize(width: 20, height: 18))
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                var top = 0, bottom = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if c.alphaComponent > 0.2 && c.greenComponent > c.redComponent + 0.12 {
                            if y < bitmap.pixelsHigh / 2 { top += 1 } else { bottom += 1 }
                        }
                    }
                }
                counts.append(top + bottom)
                if remaining == 50 { XCTAssertGreaterThan(bottom, top * 2, "半满时填充应在底部，不能填反或显示扇形") }
            }
            XCTAssertLessThan(counts[0], counts[1])
            XCTAssertLessThan(counts[1], counts[2])
        }
        try renderComparison()
    }

    func testLogoRemainsVisibleAtAllLevelsAndUnknownIsNeutral() throws {
        for platform in [UsagePlatform.chatGPT, .zhipu] {
            for dark in [false, true] {
                for data in [MenuBarData.quota(remaining: 0), .quota(remaining: 5), .quota(remaining: 15), .quota(remaining: 50), .quota(remaining: 100), .unavailable("离线")] {
                    let image = MenuBarRenderer.image(platform: platform, data: data, dark: dark, style: .waterLevel)
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                    let sx = CGFloat(bitmap.pixelsWide) / 20, sy = CGFloat(bitmap.pixelsHigh) / 18
                    var glyph = 0, colored = 0
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            let high = max(c.redComponent, c.greenComponent, c.blueComponent)
                            let low = min(c.redComponent, c.greenComponent, c.blueComponent)
                            if c.alphaComponent > 0.2 && high - low > 0.15 { colored += 1 }
                            if x >= Int(6*sx), x < Int(14*sx), y >= Int(5*sy), y < Int(13*sy), c.alphaComponent > 0.3,
                               data.health == .unknown ? high - low < 0.1 : (dark ? low > 0.6 : high < 0.4) { glyph += 1 }
                        }
                    }
                    XCTAssertGreaterThan(glyph, 8, "水位不能遮住平台 Logo: \(platform) dark=\(dark) \(data.description)")
                    if data.health == .unknown { XCTAssertEqual(colored, 0, "未知数据不能伪装成剩余量") }
                }
            }
        }
    }
    private func renderComparison() throws {
        let board = NSImage(size: NSSize(width: 450, height: 210), flipped: false) { rect in
            NSColor(white: 0.96, alpha: 1).setFill(); rect.fill()
            NSColor(white: 0.10, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 450, height: 92).fill()
            for dark in [false, true] {
                let color = dark ? NSColor.white : NSColor.black
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color]
                for (row, style) in MenuBarProgressStyle.allCases.enumerated() {
                    let y = (dark ? 56 : 148) - row * 34
                    (style.title as NSString).draw(at: NSPoint(x: 12, y: y+3), withAttributes: attrs)
                    for (column, remaining) in [100.0, 83, 50, 15, 5, 0].enumerated() {
                        if row == 0 {
                            ("\(Int(remaining))%" as NSString).draw(at: NSPoint(x: 68 + column * 63, y: y+30), withAttributes: attrs)
                        }
                        for (offset, platform) in [UsagePlatform.chatGPT, .zhipu].enumerated() {
                            MenuBarRenderer.image(platform: platform, data: .quota(remaining: remaining), dark: dark, style: style)
                                .draw(at: NSPoint(x: 66 + column * 63 + offset * 23, y: y), from: .zero, operation: .sourceOver, fraction: 1)
                        }
                    }
                }
            }
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(board.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/dsi-water-level-preview.png"))
    }

}
