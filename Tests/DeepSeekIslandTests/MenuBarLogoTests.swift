import AppKit
import XCTest
@testable import DeepSeekIsland

@MainActor
final class MenuBarLogoTests: XCTestCase {
    func testDualQuotaMetricsMapOnlyQuotaPlatforms() {
        XCTAssertEqual(UsageMetric.dualQuotaMetrics(for: .chatGPT)?.fiveHour, .chatGPTFiveHour)
        XCTAssertEqual(UsageMetric.dualQuotaMetrics(for: .chatGPT)?.week, .chatGPTWeek)
        XCTAssertEqual(UsageMetric.dualQuotaMetrics(for: .zhipu)?.fiveHour, .zhipuFiveHour)
        XCTAssertEqual(UsageMetric.dualQuotaMetrics(for: .zhipu)?.week, .zhipuWeek)
        XCTAssertNil(UsageMetric.dualQuotaMetrics(for: .deepSeek))
    }

    func testSplitQuotaSideDockIconUsesSquareCanvasAndBothReadings() throws {
        let full = MenuBarRenderer.splitQuotaImage(platform: .chatGPT,
            fiveHour: .quota(remaining: 100), week: .quota(remaining: 63, window: "本周"),
            dark: true, thickness: .standard, preserveLogoColors: true)
        XCTAssertEqual(full.size, NSSize(width: 40, height: 40))
        let low = MenuBarRenderer.splitQuotaImage(platform: .chatGPT,
            fiveHour: .quota(remaining: 8), week: .quota(remaining: 63, window: "本周"),
            dark: true, thickness: .standard, preserveLogoColors: true)
        XCTAssertNotEqual(try XCTUnwrap(full.tiffRepresentation), try XCTUnwrap(low.tiffRepresentation))
    }

    func testSplitQuotaSideDockIconUsesShorterFiveHourArcAtSameRadius() throws {
        let image = MenuBarRenderer.splitQuotaImage(platform: .chatGPT,
            fiveHour: .quota(remaining: 100), week: .quota(remaining: 100),
            dark: true, thickness: .standard, preserveLogoColors: true)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        let center = NSPoint(x: CGFloat(rep.pixelsWide) / 2, y: CGFloat(rep.pixelsHigh) / 2)
        var fiveHourAngles: [CGFloat] = []
        var weekAngles: [CGFloat] = []
        var fiveHourRadii: [CGFloat] = []
        var weekRadii: [CGFloat] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.6 else { continue }
                let dx = CGFloat(x) + 0.5 - center.x
                let dy = CGFloat(y) + 0.5 - center.y
                let angle = (atan2(-dy, dx) * 180 / .pi).truncatingRemainder(dividingBy: 360)
                let radius = hypot(dx, dy) / scale
                if color.greenComponent > 0.45,
                   color.greenComponent > color.redComponent * 1.4,
                   color.greenComponent > color.blueComponent * 1.15 {
                    fiveHourAngles.append(angle < 0 ? angle + 360 : angle)
                    fiveHourRadii.append(radius)
                } else if color.blueComponent > 0.55,
                          color.blueComponent > color.redComponent * 1.4,
                          color.blueComponent > color.greenComponent * 1.15 {
                    weekAngles.append(angle < 0 ? angle + 360 : angle)
                    weekRadii.append(radius)
                }
            }
        }
        func span(_ angles: [CGFloat]) throws -> CGFloat {
            let sorted = angles.sorted()
            var gaps: [CGFloat] = []
            for index in sorted.indices {
                var gap = sorted[(index + 1) % sorted.count] - sorted[index]
                if gap < 0 { gap += 360 }
                gaps.append(gap)
            }
            let largestGap = try XCTUnwrap(gaps.max())
            return 360 - largestGap
        }
        let fiveHourRadius = try XCTUnwrap(fiveHourRadii.sorted().dropFirst(fiveHourRadii.count / 2).first)
        let weekRadius = try XCTUnwrap(weekRadii.sorted().dropFirst(weekRadii.count / 2).first)
        let fiveHourSpan = try span(fiveHourAngles)
        let weekSpan = try span(weekAngles)
        XCTAssertLessThan(abs(fiveHourRadius - weekRadius), 1.5, "两段弧应共用同一半径")
        XCTAssertGreaterThan(weekSpan - fiveHourSpan, 60, "周额度弧应明显长于 5 小时弧")
        XCTAssertEqual(fiveHourSpan, 120, accuracy: 15, "5 小时弧含圆头应约 120°")
        XCTAssertEqual(weekSpan, 216, accuracy: 15, "周额度弧含圆头应约 216°")
    }

    func testSplitQuotaArcsShrinkFromRightToLeft() throws {
        let image = MenuBarRenderer.splitQuotaImage(platform: .chatGPT,
            fiveHour: .quota(remaining: 50), week: .quota(remaining: 50),
            dark: true, thickness: .standard, preserveLogoColors: true)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        let centerX = CGFloat(rep.pixelsWide) / 2
        var fiveHourX: [CGFloat] = []
        var weekX: [CGFloat] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.6 else { continue }
                let offset = (CGFloat(x) + 0.5 - centerX) / scale
                if color.greenComponent > 0.45,
                   color.greenComponent > color.redComponent * 1.4,
                   color.greenComponent > color.blueComponent * 1.15 {
                    fiveHourX.append(offset)
                } else if color.blueComponent > 0.55,
                          color.blueComponent > color.redComponent * 1.4,
                          color.blueComponent > color.greenComponent * 1.15 {
                    weekX.append(offset)
                }
            }
        }
        XCTAssertGreaterThan(fiveHourX.count, 10)
        XCTAssertGreaterThan(weekX.count, 10)
        XCTAssertLessThan(fiveHourX.reduce(0, +) / CGFloat(fiveHourX.count), -2, "5 小时弧应固定在左侧并从右往左收缩")
        XCTAssertLessThan(weekX.reduce(0, +) / CGFloat(weekX.count), -2, "周额度弧应同样从右往左收缩")
    }

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

    func testFloatingLogosKeepOriginalColorsInBothThemes() throws {
        for dark in [false, true] {
            for platform in UsagePlatform.allCases {
                let data: UsageReading = platform == .deepSeek ? .balance(amount: 47, currency: "CNY") : .quota(remaining: 74)
                let image = MenuBarRenderer.image(platform: platform, data: data, dark: dark,
                    balanceAsRing: platform == .deepSeek, preserveLogoColors: true)
                let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                let sx = CGFloat(rep.pixelsWide) / image.size.width
                let sy = CGFloat(rep.pixelsHigh) / image.size.height
                var original = 0
                for y in Int(5 * sy)..<Int(13 * sy) {
                    for x in Int(6 * sx)..<Int(14 * sx) {
                        let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        guard c.alphaComponent > 0.8 else { continue }
                        switch platform {
                        case .deepSeek:
                            if c.blueComponent > 0.7 && c.redComponent < 0.5 && c.greenComponent < 0.65 { original += 1 }
                        case .chatGPT:
                            if max(c.redComponent, c.greenComponent, c.blueComponent) < 0.65 { original += 1 }
                        case .zhipu:
                            if min(c.redComponent, c.greenComponent, c.blueComponent) > 0.85 { original += 1 }
                        }
                    }
                }
                XCTAssertGreaterThan(original, 3, "悬浮图标不能被主题统一染色：\(platform), dark=\(dark)")
            }
        }
    }

    func testBalanceReservesRoomForLogoAndAmountWithinCompactWidth() {
        let image = MenuBarRenderer.image(platform: .deepSeek, data: .balance(amount: Decimal(string: "39.55")!, currency: "CNY"), dark: false)
        XCTAssertGreaterThanOrEqual(image.size.width, 42)
        XCTAssertLessThanOrEqual(image.size.width, 48)
        XCTAssertEqual(image.size.height, 18)
    }
}
