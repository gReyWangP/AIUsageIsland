import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class DeepSeekDailyUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_108_800) // 2026-10-16 00:00 UTC

    private func summary(_ bucket: DailyUsageBucket?, timezone: String = "Asia/Shanghai",
                         cached: Bool = false, at date: Date? = nil) -> DeepSeekDailyUsageSummary {
        let date = date ?? now
        let snapshot = bucket.map {
            UsageAnalysisSnapshot(source: .deepSeek, buckets: [$0], updatedAt: now, currency: "CNY", timezone: timezone)
        }
        return DeepSeekDailyUsageSummary(snapshot: snapshot, officialUsage: nil, usageUpdatedAt: nil,
            currency: "CNY", freshness: .init(phase: cached ? .failed : .fresh, lastSuccess: now), now: date)
    }

    func testUsesChineseUnitsForTotalAndEveryCategoryAndInputOnlyCacheRate() throws {
        let value = summary(.init(day: UsageAnalysisMath.day(now), tokens: 2_400_000,
            cachedInput: 1_540_000, uncachedInput: 560_000, output: 300_000, cost: Decimal(string: "2.36")))
        XCTAssertEqual(value.tokensText, "240万")
        XCTAssertEqual(value.cachedInputText, "154万")
        XCTAssertEqual(value.uncachedInputText, "56万")
        XCTAssertEqual(value.outputText, "30万")
        XCTAssertEqual(value.costText, "¥2.36")
        XCTAssertEqual(try XCTUnwrap(value.cacheRate), 73.3333333, accuracy: 0.0001)
        XCTAssertEqual(value.cacheRateText, "73.3%")
        XCTAssertEqual(value.note, "今日仍在统计 · 按北京时间累计")
        let large = summary(.init(day: UsageAnalysisMath.day(now), tokens: 123_456_789))
        XCTAssertEqual(large.tokensText, "1.23亿")
    }

    func testMissingDataAndZeroInputDoNotInventUsageOrCacheRate() {
        let missing = summary(nil)
        XCTAssertEqual(missing.tokensText, "—")
        XCTAssertEqual(missing.costText, "—")
        XCTAssertEqual(missing.cachedInputText, "—")
        XCTAssertNil(missing.cacheRate)
        XCTAssertEqual(missing.note, "暂无今日官方用量")
        let zero = summary(.init(day: UsageAnalysisMath.day(now), tokens: 0,
            cachedInput: 0, uncachedInput: 0, output: 0, cost: .zero))
        XCTAssertEqual(zero.tokensText, "0万")
        XCTAssertEqual(zero.costText, "¥0.00")
        XCTAssertNil(zero.cacheRate)
        let miss = summary(.init(day: UsageAnalysisMath.day(now), tokens: 100,
            cachedInput: 0, uncachedInput: 100, output: 0))
        XCTAssertEqual(miss.cacheRateText, "0.0%")
    }

    func testTodayFollowsSnapshotTimezoneAndClearsAfterMidnight() {
        let day = UsageAnalysisMath.day(now, timezone: "UTC")
        let bucket = DailyUsageBucket(day: day, tokens: 100_000, cost: 1)
        let current = summary(bucket, timezone: "UTC")
        XCTAssertEqual(current.tokensText, "10万")
        XCTAssertTrue(current.note.contains("UTC"))
        let nextDay = summary(bucket, timezone: "UTC", at: now.addingTimeInterval(86400))
        XCTAssertEqual(nextDay.tokensText, "—")
        XCTAssertEqual(nextDay.costText, "—")
        // At 16:00 UTC Shanghai has crossed midnight while the UTC bucket is still today.
        let utcEvening = now.addingTimeInterval(16 * 3600)
        XCTAssertEqual(summary(bucket, timezone: "UTC", at: utcEvening).tokensText, "10万")
        XCTAssertEqual(summary(bucket, at: utcEvening).tokensText, "—")
    }

    func testCurrentOfficialSummaryCanEstablishZeroButOldSummaryCannot() {
        let official = OfficialUsageSummary(amount: [:], cost: [:], ranges: UsageRanges(now: now, calendar: .current))
        let fresh = DataFreshness(phase: .fresh, lastSuccess: now)
        let zero = DeepSeekDailyUsageSummary(snapshot: nil, officialUsage: official, usageUpdatedAt: now,
            currency: "USD", freshness: fresh, now: now)
        XCTAssertEqual(zero.costText, "$0.00")
        XCTAssertEqual(zero.tokensText, "0万")
        XCTAssertNil(zero.cacheRate)
        let old = DeepSeekDailyUsageSummary(snapshot: nil, officialUsage: official,
            usageUpdatedAt: now.addingTimeInterval(-86400), currency: "USD", freshness: fresh, now: now)
        XCTAssertEqual(old.tokensText, "—")
        XCTAssertEqual(old.costText, "—")
    }

    func testMarksFailedRefreshAndPersistedTodayAsCached() {
        var bucket = DailyUsageBucket(day: UsageAnalysisMath.day(now), tokens: 100_000)
        XCTAssertTrue(summary(bucket, cached: true).note.contains("缓存"))
        bucket.isCached = true
        XCTAssertTrue(summary(bucket).isCached)
        XCTAssertEqual(summary(bucket).tokensText, "10万")
    }

    func testActualCardRendersChineseUnitsInBothThemesWithoutStartingPolling() async throws {
        _ = NSApplication.shared
        let suite = "DeepSeekDailyUsage." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek])
        let source = model.selectedRuntime(for: .deepSeek)
        source.accountConnected = true
        source.balance = Decimal(string: "47.68")!
        source.lastUpdated = .now
        source.usageLastUpdated = .now
        let day = UsageAnalysisMath.day(.now)
        source.analysis.accept(.init(source: .deepSeek, buckets: [.init(day: day, tokens: 2_400_000,
            cachedInput: 1_540_000, uncachedInput: 560_000, output: 300_000, cost: Decimal(string: "2.36"))], currency: "CNY"))
        let settings = IslandSettings(defaults: defaults)
        settings.backgroundEffect = .solid
        for appearance in [AppearanceMode.dark, .light] {
            settings.appearanceMode = appearance
            let view = MenuBarPopoverView(model: model, settings: settings, source: source,
                canRefresh: true, onRefresh: {}, onAnalysis: {}, onSettings: {})
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 360),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance.nsAppearance
            window.contentView = host
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, 360)
            XCTAssertGreaterThan(host.fittingSize.height, 300)
            XCTAssertLessThan(host.fittingSize.height, 380)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/aiusage-deepseek-daily-\(appearance.rawValue).png"))
        }
        XCTAssertFalse(source.hasStartedPolling)
    }
}
