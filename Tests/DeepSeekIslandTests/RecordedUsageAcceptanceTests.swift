import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class RecordedUsageAcceptanceTests: XCTestCase {
    func testRecordedStatisticsAndNativeAnalysisWhenExplicitlyProvided() async throws {
        guard let path=ProcessInfo.processInfo.environment["AI_USAGE_ACCEPTANCE_FIXTURES"] else {
            throw XCTSkip("只在显式提供匿名日统计缓存时执行真实数据验收")
        }
        let directory=URL(fileURLWithPath:path)
        let fixtures=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).sorted {$0.path < $1.path}
        XCTAssertFalse(fixtures.isEmpty)
        _ = NSApplication.shared
        for (index,fixture) in fixtures.enumerated() {
            let store=UsageAnalysisStore(directory:fixture)
            await store.waitUntilLoaded()
            let snapshot=try XCTUnwrap(store.snapshot)
            XCTAssertTrue(UsageAnalysisMath.validate(snapshot.buckets))
            let started=ContinuousClock.now
            for i in 0..<100 {
                let prepared=store.period(days:i.isMultiple(of:2) ? 7 : 30)
                XCTAssertEqual(prepared.totalTokens,prepared.buckets.isEmpty ? nil : UsageAnalysisMath.sum(prepared.buckets.map(\.tokens)))
                _ = store.overview(platform:snapshot.source == .chatGPT ? .chatGPT : snapshot.source == .deepSeek ? .deepSeek : .zhipu)
            }
            print("ACCEPTANCE anonymous \(index+1) \(snapshot.source.rawValue): cached range/overview x100 \(started.duration(to:.now))")
            XCTAssertLessThan(started.duration(to:.now),.milliseconds(250))
            let suite=UUID().uuidString, defaults=UserDefaults(suiteName:suite)!
            let root=SessionStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            defer {defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root.directory)}
            let platform: UsagePlatform=snapshot.source == .chatGPT ? .chatGPT : snapshot.source == .deepSeek ? .deepSeek : .zhipu
            let model=IslandModel(defaults:defaults,sessionRoot:root);model.networkAvailable=false
            model.platformAccounts=PlatformAccounts(enabled:[platform])
            let account=try XCTUnwrap(model.orderedSavedAccounts.first)
            model.accountRuntime(for:account).analysis.accept(snapshot)
            let window=UsageAnalysisWindowController.makeWindow()
            let hosting=UsageAnalysisWindowController.makeContentView(model:model,account:account)
            let mounted=ContinuousClock.now
            window.contentView=hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for:.milliseconds(50))
            hosting.layoutSubtreeIfNeeded()
            let bitmap=try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds))
            hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
            print("ACCEPTANCE anonymous \(index+1): native window layout and bitmap incl 50ms runloop \(mounted.duration(to:.now))")
            XCTAssertEqual(hosting.bounds.height,700,accuracy:1)
            XCTAssertEqual(hosting.bounds.width,840,accuracy:1)
            window.close()
        }
    }
}
