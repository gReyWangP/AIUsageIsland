import AppKit
import XCTest
@testable import DeepSeekIsland

@MainActor
final class MenuBarLogoTests: XCTestCase {
    func testOfficialLogoResourcesAreBundled() throws {
        for (name, ext) in [("DeepSeekLogo", "svg"), ("ChatGPTLogo", "png"), ("CodingPlanLogo", "png")] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext))
            XCTAssertNotNil(NSImage(contentsOf: url))
        }
    }
    func testQuotaLogoContainsVisiblePixelsAtMenuBarSize() throws {
        for platform in [UsagePlatform.chatGPT, .zhipu] {
            let image = MenuBarRenderer.image(platform: platform, data: .quota(remaining: 83), dark: false)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let sx = CGFloat(rep.pixelsWide) / image.size.width
            let sy = CGFloat(rep.pixelsHigh) / image.size.height
            var opaque = 0
            for y in Int(5 * sy)..<Int(13 * sy) {
                for x in Int(6 * sx)..<Int(14 * sx) {
                    if rep.colorAt(x: x, y: y)!.alphaComponent > 0.25 { opaque += 1 }
                }
            }
            XCTAssertGreaterThan(opaque, 8, "Logo 中心不能是空白")
        }
    }

    func testDarkMenuBarUsesWhiteLogo() throws {
        for platform in [UsagePlatform.chatGPT, .zhipu, .deepSeek] {
            let data: MenuBarData = platform == .deepSeek ? .balance(amount: 39, currency: "CNY") : .quota(remaining: 83)
            let image = MenuBarRenderer.image(platform: platform, data: data, dark: true)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let sx = CGFloat(rep.pixelsWide) / image.size.width
            let sy = CGFloat(rep.pixelsHigh) / image.size.height
            var white = 0
            for y in Int(5 * sy)..<Int(13 * sy) {
                for x in Int(6 * sx)..<Int(14 * sx) {
                    let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if c.alphaComponent > 0.5 && min(c.redComponent, c.greenComponent, c.blueComponent) > 0.8 { white += 1 }
                }
            }
            XCTAssertGreaterThan(white, 8, "深色菜单栏 Logo 应使用白色")
        }
    }

    func testBalanceReservesRoomForLogoAndAmountWithinCompactWidth() {
        let image = MenuBarRenderer.image(platform: .deepSeek, data: .balance(amount: Decimal(string: "39.55")!, currency: "CNY"), dark: false)
        XCTAssertGreaterThanOrEqual(image.size.width, 42)
        XCTAssertLessThanOrEqual(image.size.width, 48)
        XCTAssertEqual(image.size.height, 18)
    }
}
