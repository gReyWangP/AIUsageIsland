import AppKit
import XCTest
@testable import DeepSeekIsland

@MainActor
final class MenuBarRingTests: XCTestCase {
    func testStandardDefaultAndThicknessPersists() {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        XCTAssertEqual(settings.menuBarRingThickness, .standard)
        settings.menuBarRingThickness = .thick
        XCTAssertEqual(IslandSettings(defaults: store).menuBarRingThickness, .thick)
        store.set("unknown", forKey: "menuBarRingThickness")
        XCTAssertEqual(IslandSettings(defaults: store).menuBarRingThickness, .standard)
    }

    func testThickerRingsIncreaseVisibleCoverageWithoutGrowingIconOrCoveringLogo() throws {
        for dark in [false, true] {
            var counts: [Int] = []
            for thickness in MenuBarRingThickness.allCases {
                let image = MenuBarRenderer.image(platform: .chatGPT, data: .quota(remaining: 100), dark: dark, thickness: thickness)
                XCTAssertEqual(image.size, NSSize(width: 20, height: 18))
                let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                let sx = CGFloat(rep.pixelsWide) / image.size.width
                let sy = CGFloat(rep.pixelsHigh) / image.size.height
                var green = 0
                var logo = 0
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if c.alphaComponent > 0.4 && c.greenComponent > c.redComponent + 0.12 { green += 1 }
                        if x >= Int(6 * sx), x < Int(14 * sx), y >= Int(5 * sy), y < Int(13 * sy),
                           c.alphaComponent > 0.5, abs(c.greenComponent - c.redComponent) < 0.1 {
                            logo += 1
                        }
                    }
                }
                XCTAssertGreaterThan(logo, 8, "粗圆环也必须保留可辨认的中心 Logo")
                counts.append(green)
            }
            XCTAssertLessThan(counts[0], counts[1])
            XCTAssertLessThan(counts[1], counts[2])
        }
        let board = NSImage(size: NSSize(width: 330, height: 210), flipped: false) { rect in
            NSColor(white: 0.96, alpha: 1).setFill(); rect.fill()
            NSColor(white: 0.10, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 330, height: 90).fill()
            for (column, thickness) in MenuBarRingThickness.allCases.enumerated() {
                (thickness.title as NSString).draw(at: NSPoint(x: 40 + column * 105, y: 188), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
                for dark in [false, true] {
                    for (row, remaining) in [83.0, 15.0, 5.0].enumerated() {
                        for (offset, platform) in [UsagePlatform.chatGPT, .zhipu].enumerated() {
                            let image = MenuBarRenderer.image(platform: platform, data: .quota(remaining: remaining), dark: dark, thickness: thickness)
                            image.draw(at: NSPoint(x: 33 + column * 105 + offset * 28, y: (dark ? 63 : 153) - row * 25), from: .zero, operation: .sourceOver, fraction: 1)
                        }
                    }
                }
            }
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(board.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/dsi-ring-thickness.png"))
    }
}
