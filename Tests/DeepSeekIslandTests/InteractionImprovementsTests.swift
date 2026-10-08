import AppKit
import SwiftUI
import XCTest
import CoreGraphics
@testable import DeepSeekIsland

@MainActor
final class InteractionImprovementsTests: XCTestCase {
    func testCustomOrderAndMetricsPersistWithoutRemovingDetailMetrics() {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        settings.platformOrder = [.chatGPT, .deepSeek, .zhipu]
        settings.setCompactMetric("week", visible: false, for: .chatGPT, allIDs: ["session", "week"])
        settings.setCompactMetric("session", visible: false, for: .chatGPT, allIDs: ["session", "week"])
        let restored = IslandSettings(defaults: store)
        XCTAssertEqual(restored.orderedPlatforms, [.chatGPT, .deepSeek, .zhipu])
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT, .deepSeek, .zhipu])
        model.presentationSettings = restored
        XCTAssertEqual(model.snapshots.map(\.platform), restored.orderedPlatforms)
        XCTAssertEqual(model.snapshots[0].compactMetrics.map(\.id), ["session"])
        XCTAssertEqual(model.snapshots[0].rows.count, 3)
        XCTAssertTrue(restored.pausesHoverInFullscreen)
    }
    func testCountdownDoesNotClaimRecoveryFromTimeAlone() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(ResetCountdown.text(resetAt: now.addingTimeInterval(120), usedPercent: 100, fresh: true, at: now), "2分钟后")
        XCTAssertEqual(ResetCountdown.text(resetAt: now, usedPercent: 100, fresh: true, at: now), "正在确认额度")
        XCTAssertEqual(ResetCountdown.text(resetAt: now, usedPercent: 100, fresh: false, at: now), "等待更新确认")
        XCTAssertEqual(ResetCountdown.text(resetAt: nil, usedPercent: nil, fresh: false, at: now), "—")
    }
    func testFullscreenGeometryExcludesMaximizedAndOtherDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertTrue(FullscreenHoverPolicy.coversScreen(window: screen, screen: screen))
        XCTAssertFalse(FullscreenHoverPolicy.coversScreen(window: CGRect(x: 0, y: 38, width: 1512, height: 944), screen: screen))
        XCTAssertFalse(FullscreenHoverPolicy.coversScreen(window: screen.offsetBy(dx: 1512, dy: 0), screen: screen))
    }
    func testNotificationFocusRoutesActualWindowAndRemovedPlatform() {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        model.chatGPTQuota = ChatGPTQuota(planType: "team", session: .init(windowSeconds: 604800, usedPercent: 20, resetAt: nil), weekly: .init(windowSeconds: 2592000, usedPercent: 30, resetAt: nil), email: nil, accountID: nil, limitReached: false)
        model.focusNotification(.chatGPTWeek)
        XCTAssertEqual(model.detailFocus?.rowID, "hero")
        XCTAssertEqual(model.detailFocus?.platform, .chatGPT)
        model.platformAccounts = PlatformAccounts(enabled: [])
        model.focusNotification(.chatGPTWeek)
        XCTAssertNil(model.detailFocus)
    }
    func testNotificationClickKeepsMetricAndLegacyFallback() {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        var fallback = 0
        var received: MenuBarMetric?
        let controller = UsageAlertsController(model: IslandModel(), settings: IslandSettings(defaults: store),
            onOpen: { fallback += 1 }, defaults: store, backend: UsageAlertsControllerTests.Notifications())
        controller.onOpenMetric = { received = $0 }
        controller.openDetails(metric: .zhipuWeek)
        XCTAssertEqual(received, .zhipuWeek)
        XCTAssertEqual(fallback, 0)
        controller.openDetails(metric: nil)
        XCTAssertEqual(fallback, 1)
    }

    func testActualResetRowsPreserveTimeAndFreshness() {
        let model = fixtureModel()
        let row = model.snapshot(for: .chatGPT).rows[1]
        XCTAssertNotNil(row.resetAt)
        XCTAssertEqual(row.resetUsedPercent, 95)
        XCTAssertTrue(row.resetFresh)
        model.networkAvailable = false
        XCTAssertFalse(model.snapshot(for: .chatGPT).rows[1].resetFresh)
    }

    func testNewSettingsAndCountdownDetailsRenderInBothThemes() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        let model = fixtureModel()
        model.presentationSettings = settings
        model.focusNotification(.chatGPTWeek)
        for mode in [AppearanceMode.light, .dark] {
            settings.appearanceMode = mode
            let views: [(String, AnyView, CGSize)] = [
                ("settings", AnyView(FloatingContentSettings(settings: settings, model: model).padding(18)), CGSize(width: 420, height: 586)),
                ("columns", AnyView(IslandDetailColumns(snapshots: model.snapshots, focus: model.detailFocus).padding(19)), CGSize(width: 722, height: 350)),
                ("stacked", AnyView(IslandDetailStacked(snapshots: model.snapshots, focus: model.detailFocus).padding(19)), CGSize(width: 565, height: 470))
            ]
            for (name, view, size) in views {
                let content = view.frame(width: size.width, height: size.height, alignment: .top)
                    .background(mode == .dark ? Color.black : Color.white)
                    .environment(\.colorScheme, mode.colorScheme!)
                let hosting = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = mode.nsAppearance
                window.contentView = hosting
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                var contrast = 0
                for y in stride(from: 10, to: bitmap.pixelsHigh - 10, by: 4) {
                    for x in stride(from: 10, to: bitmap.pixelsWide - 10, by: 4) {
                        let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                        if mode == .dark ? color.redComponent > 0.4 : color.redComponent < 0.6 { contrast += 1 }
                    }
                }
                XCTAssertGreaterThan(contrast, 100)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/tmp/dsi-interactions-\(name)-\(mode.rawValue).png"))
                window.close()
            }
        }
    }

    private func fixtureModel() -> IslandModel {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek, .zhipu, .chatGPT])
        model.accountConnected = true; model.zhipuConnected = true; model.chatGPTConnected = true
        model.balance = 39.55; model.lastUpdated = .now; model.usageLastUpdated = .now
        model.zhipuLastUpdated = .now; model.chatGPTLastUpdated = .now
        model.zhipuQuota = ZhipuQuota(kind: .tokens, level: "Pro",
            fiveHour: .init(usedPercent: 90, usedValue: nil, limitValue: nil, nextReset: .now.addingTimeInterval(1500)),
            week: .init(usedPercent: 80, usedValue: nil, limitValue: nil, nextReset: .now.addingTimeInterval(140000)))
        model.chatGPTQuota = ChatGPTQuota(planType: "plus",
            session: .init(windowSeconds: 18000, usedPercent: 95, resetAt: .now.addingTimeInterval(120)),
            weekly: .init(windowSeconds: 604800, usedPercent: 99, resetAt: .now.addingTimeInterval(-60)),
            email: nil, accountID: nil, limitReached: false)
        return model
    }

}
