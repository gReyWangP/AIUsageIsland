import AppKit
import SwiftUI
import Combine
import XCTest
@testable import DeepSeekIsland

@MainActor
final class StackedUsageRenderTests: XCTestCase {
    func testMultipleAccountsRenderAndPublishIndependentUpdates() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.platformAccounts = PlatformAccounts(enabled: Set(UsagePlatform.allCases))
        model.accountProfiles.rename(AccountProfileEntry.legacyID, platform: .deepSeek, label: "个人")
        model.accountProfiles.add(platform: .deepSeek, label: "工作")
        for (index, account) in model.savedAccounts.enumerated() {
            let runtime = model.accountRuntime(for: account)
            runtime.accountConnected = true; runtime.chatGPTConnected = true; runtime.zhipuConnected = true
            let source: UsageAnalysisSource = account.platform == .deepSeek ? .deepSeek : account.platform == .chatGPT ? .chatGPT : .zhipu
            let buckets: [DailyUsageBucket] = (0..<7).map { (offset: Int) -> DailyUsageBucket in
                let date = Date.now.addingTimeInterval(-Double(6 - offset) * 86400)
                let count = Int64(index + 1) * Int64(offset % 3 + 2) * 130_000
                return DailyUsageBucket(day: UsageAnalysisMath.day(date), tokens: count, isPartial: offset == 6)
            }
            runtime.analysis.accept(.init(source: source, buckets: buckets))
        }
        let runtimes = model.savedAccounts.map { model.accountRuntime(for: $0) }
        let observer = StackedUsageHistory(runtimes: runtimes)
        var updates = 0
        let token = observer.objectWillChange.sink { updates += 1 }
        defer { token.cancel() }
        let first = runtimes[0]
        await first.analysis.waitUntilLoaded()
        first.analysis.accept(.init(source: .deepSeek, buckets: [.init(day: UsageAnalysisMath.day(.now), tokens: 123_000)]))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(updates, 0)
        let period = StackedUsagePeriod(inputs: observer.inputs, days: 7)
        XCTAssertEqual(period.buckets.last?.segments.count, 4)
        XCTAssertEqual(period.buckets.last?.segments.first { $0.account == first.account }?.tokens, 123_000)
        for scheme in [ColorScheme.light, .dark] {
            let content = UsageAnalysisView(model: model, initialAccount: first.account).environment(\.colorScheme, scheme).frame(width: 840, height: 740)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 740), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.close() }
            host.frame = NSRect(x: 0, y: 0, width: 840, height: 740)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, 840)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/aiusage-stacked-accounts-\(scheme == .dark ? "dark" : "light").png"))
        }
        XCTAssertTrue(runtimes.allSatisfy { !$0.hasStartedPolling })
    }
}
