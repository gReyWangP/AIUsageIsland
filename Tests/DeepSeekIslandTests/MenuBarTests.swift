import AppKit
import XCTest
@testable import DeepSeekIsland

@MainActor
final class MenuBarTests: XCTestCase {
    func testQuotaThresholdsUseRemainingPercent() {
        for (remaining, expected) in [(100.0, MenuBarHealth.healthy), (20, .healthy), (19.99, .warning), (10, .warning), (9.99, .critical), (0, .critical)] {
            XCTAssertEqual(MenuBarData.quota(remaining: remaining).health, expected)
        }
    }
    func testBalanceFormattingNeverRoundsUpAcrossThresholds() {
        for (raw, text, health) in [("39.55", "¥39", MenuBarHealth.healthy), ("5", "¥5", .healthy), ("4.99", "¥4", .warning), ("1", "¥1", .warning), ("0.869", "¥0.86", .critical), ("0.999", "¥0.99", .critical), ("0.001", "<¥0.01", .critical), ("0", "¥0.00", .critical)] {
            let data = MenuBarData.balance(amount: Decimal(string: raw)!, currency: "CNY")
            XCTAssertEqual(data.balanceText, text)
            XCTAssertEqual(data.health, health)
        }
    }
    func testMissingDataIsNeutral() {
        XCTAssertEqual(MenuBarData.unavailable("未登录").health, .unknown)
    }
    func testMenuBarSettingsPersist() {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        XCTAssertTrue(settings.showsMenuBarItem)
        settings.showsMenuBarItem = true
        settings.menuBarPlatform = .zhipu
        let restored = IslandSettings(defaults: store)
        XCTAssertTrue(restored.showsMenuBarItem)
        XCTAssertEqual(restored.menuBarPlatform, .zhipu)
    }
    func testChatGPTDoesNotSubstituteWeeklyQuotaForFiveHours() {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        model.chatGPTConnected = true
        model.chatGPTQuota = ChatGPTQuota(planType: "team", session: .init(windowSeconds: 604800, usedPercent: 10, resetAt: nil), weekly: nil, email: nil, accountID: nil, limitReached: false)
        XCTAssertEqual(model.menuBarData(for: .chatGPT).health, .unknown)
    }
    func testQuotaImageFitsSingleIconSpace() {
        let image = MenuBarRenderer.image(platform: .chatGPT, data: .quota(remaining: 83), dark: false)
        XCTAssertEqual(image.size.height, 18)
        XCTAssertLessThanOrEqual(image.size.width, 22)
    }
    func testBothQuotaPlatformsUseRemainingRatherThanUsed() {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT, .zhipu])
        model.chatGPTConnected = true
        model.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18_000, usedPercent: 91, resetAt: nil), weekly: nil, email: nil, accountID: nil, limitReached: false)
        if case .quota(let remaining, _) = model.menuBarData(for: .chatGPT) { XCTAssertEqual(remaining, 9) }
        else { XCTFail("应有5小时剩余额度") }
        model.zhipuConnected = true
        let window = ZhipuQuota.Window(usedPercent: 85, usedValue: nil, limitValue: nil, nextReset: nil)
        model.zhipuQuota = ZhipuQuota(kind: .tokens, level: nil, fiveHour: window, week: window)
        XCTAssertEqual(model.menuBarData(for: .zhipu).health, .warning)
        model.zhipuUsageError = "请求失败"
        XCTAssertEqual(model.menuBarData(for: .zhipu).health, .unknown)
    }

    func testRenderNativeSizedExamples() throws {
        let examples: [(UsagePlatform, MenuBarData)] = [
            (.chatGPT, .quota(remaining: 83)), (.chatGPT, .quota(remaining: 15)),
            (.zhipu, .quota(remaining: 9)), (.chatGPT, .quota(remaining: 0)),
            (.deepSeek, .balance(amount: Decimal(string: "39.55")!, currency: "CNY")),
            (.deepSeek, .balance(amount: Decimal(string: "4.99")!, currency: "CNY")),
            (.deepSeek, .balance(amount: Decimal(string: "0.869")!, currency: "CNY")),
            (.deepSeek, .unavailable("未登录"))]
        let board = NSImage(size: NSSize(width: 440, height: 100), flipped: false) { rect in
            NSColor(white: 0.96, alpha: 1).setFill(); rect.fill()
            NSColor(white: 0.10, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 440, height: 50).fill()
            for dark in [false, true] {
                for (index, example) in examples.enumerated() {
                    let image = MenuBarRenderer.image(platform: example.0, data: example.1, dark: dark)
                    image.draw(at: NSPoint(x: 10 + index * 54, y: dark ? 16 : 66), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            return true
        }
        let data = try XCTUnwrap(board.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/dsi-menubar-examples.png"))
    }

}

@MainActor
final class MenuBarMetricTests: XCTestCase {
    func testWeekAndFiveHourUseDifferentData() {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.zhipu, .chatGPT])
        model.zhipuConnected = true
        let five = ZhipuQuota.Window(usedPercent: 15, usedValue: nil, limitValue: nil, nextReset: nil)
        let week = ZhipuQuota.Window(usedPercent: 95, usedValue: nil, limitValue: nil, nextReset: nil)
        model.zhipuQuota = ZhipuQuota(kind: .tokens, level: nil, fiveHour: five, week: week)
        XCTAssertEqual(model.menuBarData(for: MenuBarMetric.zhipuFiveHour).health, .healthy)
        XCTAssertEqual(model.menuBarData(for: MenuBarMetric.zhipuWeek).health, .critical)
        XCTAssertTrue(model.menuBarData(for: MenuBarMetric.zhipuWeek).description.contains("本周"))
        model.chatGPTConnected = true
        model.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18_000, usedPercent: 15, resetAt: nil), weekly: .init(windowSeconds: 604_800, usedPercent: 95, resetAt: nil), email: nil, accountID: nil, limitReached: false)
        XCTAssertEqual(model.menuBarData(for: MenuBarMetric.chatGPTFiveHour).health, .healthy)
        XCTAssertEqual(model.menuBarData(for: MenuBarMetric.chatGPTWeek).health, .critical)
    }
    func testMetricSelectionPersistsAndMigratesPreviousPlatform() {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        store.set("zhipu", forKey: "menuBarPlatform")
        let settings = IslandSettings(defaults: store)
        XCTAssertEqual(settings.menuBarMetric, .zhipuFiveHour)
        settings.menuBarMetric = .zhipuWeek
        XCTAssertEqual(IslandSettings(defaults: store).menuBarMetric, .zhipuWeek)
    }
}
