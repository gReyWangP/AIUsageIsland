import XCTest
import AppKit
import SwiftUI
@testable import DeepSeekIsland

@MainActor
final class CompactQuotaCopyTests: XCTestCase {
    func testFloatingQuotaLabelsAndValuesDescribeRemainingWhileDetailsDescribeUsed() throws {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.zhipu, .chatGPT])
        let five = ZhipuQuota.Window(usedPercent: 74, usedValue: nil, limitValue: nil, nextReset: nil)
        let week = ZhipuQuota.Window(usedPercent: 91, usedValue: nil, limitValue: nil, nextReset: nil)
        model.zhipuQuota = ZhipuQuota(kind: .tokens, level: nil, fiveHour: five, week: week)
        model.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: 74, resetAt: nil), weekly: .init(windowSeconds: 604800, usedPercent: 91, resetAt: nil), email: nil, accountID: nil, limitReached: false)
        for snapshot in model.snapshots {
            XCTAssertEqual(snapshot.compactMetrics.map(\.label), ["5 小时剩余", "本周剩余"])
            XCTAssertEqual(snapshot.compactMetrics.map(\.value), ["26%", "9%"])
            XCTAssertEqual(snapshot.heroLabel, "5 小时已用")
            XCTAssertEqual(snapshot.heroValue, "74%")
        }
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek, .zhipu, .chatGPT])
        for layout in CompactLayout.allCases {
            let view = IslandCompactBar(snapshots: model.snapshots, layout: layout, hasNotch: true,
                horizontalWidth: 565, notchWidth: 185, bandHeight: 32)
                .environment(\.colorScheme, .dark)
                .background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/dsi-compact-remaining-\(layout.rawValue).png"))
        }
    }
    func testProWithoutFiveHourLimitDisplaysUnlimitedAndRetainsWeeklyUsage() throws {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        model.chatGPTQuota = try ChatGPTQuotaParser.parse(Data(#"{"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":null,"secondary_window":{"used_percent":42,"limit_window_seconds":604800,"reset_at":1791275163}}}"#.utf8))
        model.chatGPTConnected = true
        model.chatGPTLastUpdated = .now
        let snapshot = model.snapshots[0]
        XCTAssertEqual(snapshot.heroLabel, "5 小时额度")
        XCTAssertEqual(snapshot.heroValue, "无限制")
        XCTAssertEqual(snapshot.compactMetrics.map(\.value), ["无限制", "58%"])
        XCTAssertEqual(snapshot.rows.first?.value, "42%")
        XCTAssertEqual(snapshot.rows.first(where: { $0.id == "session-reset" })?.value, "无需重置")
        XCTAssertNil(snapshot.rows.first(where: { $0.id == "session-reset" })?.reservationMetric)
        XCTAssertEqual(model.menuBarData(for: .chatGPTFiveHour).description, "5 小时额度：无限制")
    }

    func testProOtherFiniteWindowRemainsVisibleAlongsideUnlimitedFiveHours() throws {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        model.chatGPTQuota = try ChatGPTQuotaParser.parse(Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":86400,"reset_at":1791275163},"secondary_window":{"used_percent":20,"limit_window_seconds":604800}}}"#.utf8))
        let snapshot = model.snapshots[0]
        XCTAssertEqual(snapshot.heroLabel, "今日已用")
        XCTAssertEqual(snapshot.heroValue, "100%")
        XCTAssertEqual(snapshot.compactMetrics.map(\.value), ["0%", "80%"])
        XCTAssertEqual(snapshot.rows.first(where: { $0.id == "session-reset" })?.resetAt, Date(timeIntervalSince1970: 1791275163))
        XCTAssertEqual(snapshot.rows.first(where: { $0.id == "five-hour-unlimited" })?.value, "无限制")
    }

    func testZhipuV1OnlyFiveHourQuotaShowsNoWeeklyLimit() throws {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.zhipu])
        model.zhipuQuota = try ZhipuQuotaParser.parse(Data(#"{"code":200,"data":{"level":"V1","limits":[{"type":"TOKENS_LIMIT","unit":3,"percentage":20}]}}"#.utf8))
        model.zhipuConnected = true
        model.zhipuLastUpdated = .now
        let snapshot = model.snapshots[0]
        XCTAssertEqual(snapshot.heroValue, "20%")
        XCTAssertEqual(snapshot.compactMetrics.map(\.value), ["80%", "无周限制"])
        XCTAssertEqual(snapshot.rows.first?.value, "无周限制")
        XCTAssertEqual(snapshot.rows.first(where: { $0.id == "week-reset" })?.value, "无需重置")
        XCTAssertNil(snapshot.rows.first(where: { $0.id == "week-reset" })?.reservationMetric)
        XCTAssertEqual(model.menuBarData(for: .zhipuWeek).description, "本周额度：无限制")
        XCTAssertEqual(model.jointQuotaStatus(for: .zhipu), .available(["5 小时"]))
        XCTAssertNil(AlertThresholds.defaults(for: .zhipuWeek).severity(model.menuBarData(for: .zhipuWeek)))
        model.zhipuQuota = ZhipuQuota(kind: .tokens, level: "V1", fiveHour: .init(usedPercent: 100, usedValue: nil, limitValue: nil, nextReset: nil), week: nil)
        XCTAssertEqual(model.jointQuotaStatus(for: .zhipu), .blocked(["5 小时"]))
    }

    func testMissingQuotaIsUnknownAndActualWindowNamesArePreserved() throws {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        XCTAssertEqual(model.snapshots[0].compactMetrics.map(\.value), ["—", "—"])
        model.chatGPTQuota = ChatGPTQuota(planType: "team", session: .init(windowSeconds: 604800, usedPercent: 100, resetAt: nil), weekly: .init(windowSeconds: 2592000, usedPercent: 0, resetAt: nil), email: nil, accountID: nil, limitReached: false)
        XCTAssertEqual(model.snapshots[0].compactMetrics.map(\.label), ["本周剩余", "本月剩余"])
        XCTAssertEqual(model.snapshots[0].compactMetrics.map(\.value), ["0%", "100%"])
        XCTAssertEqual(UsageFormat.remainingPercent(99.8), "<1%")
        XCTAssertEqual(UsageFormat.remainingPercent(.nan), "—")
        XCTAssertEqual(UsageFormat.remainingPercent(90.1), "9%")
    }
}
