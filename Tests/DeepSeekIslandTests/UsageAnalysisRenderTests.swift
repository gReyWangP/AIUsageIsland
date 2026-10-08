import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland
@MainActor
final class UsageAnalysisRenderTests: XCTestCase {
    private func overflowScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView,
           let document = scroll.documentView,
           document.bounds.height > scroll.contentView.bounds.height + 1 { return scroll }
        for child in view.subviews {
            if let scroll = overflowScrollView(in: child) { return scroll }
        }
        return nil
    }
    func testAnalysisWindowUsesNormalDesktopBehaviorAndFitsSmallScreenHeight() {
        let window=UsageAnalysisWindowController.makeWindow()
        defer {window.close()}
        let content=window.contentRect(forFrameRect:NSRect(origin:.zero,size:window.minSize))
        XCTAssertGreaterThanOrEqual(content.width,780)
        XCTAssertLessThanOrEqual(window.minSize.height,600,"小屏幕仍能访问窗口控制")
        XCTAssertGreaterThanOrEqual(content.height,480)
        XCTAssertEqual(window.level,.normal)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
    }
    func testUnconstrainedHostingDoesNotExpandAnalysisWindowBeyondRequestedSize() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString, defaults = UserDefaults(suiteName:name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName:name); try? FileManager.default.removeItem(at:root.directory) }
        let model = IslandModel(defaults:defaults,sessionRoot:root); model.networkAvailable = false
        model.platformAccounts = PlatformAccounts(enabled:Set(UsagePlatform.allCases))
        for account in model.savedAccounts {
            let runtime = model.accountRuntime(for:account)
            runtime.analysis.accept(.init(source:account.platform == .deepSeek ? .deepSeek : account.platform == .chatGPT ? .chatGPT : .zhipu,
                buckets:(0..<7).map { offset in
                    .init(day:UsageAnalysisMath.day(Date.now.addingTimeInterval(-Double(offset)*86400)),tokens:230_000_000,
                          cachedInput:220_000_000,uncachedInput:5_000_000,output:5_000_000,cost:Decimal(10))
                },currency:"CNY"))
            let window = UsageAnalysisWindowController.makeWindow()
            window.contentView = UsageAnalysisWindowController.makeContentView(model:model,account:account)
            window.orderFront(nil)
            try await Task.sleep(for:.milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
            let content = window.contentRect(forFrameRect:window.frame)
            XCTAssertEqual(content.height,700,accuracy:1,"真实打开流程不能由图表理想高度撑大窗口：\(account.platform)")
            XCTAssertEqual(content.width,840,accuracy:1)
            let hosting = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds))
            hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:"/tmp/aiusage-analysis-window-\(account.platform.rawValue).png"))
            window.setContentSize(NSSize(width:780,height:660))
            try await Task.sleep(for:.milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.bounds.height,660,accuracy:1,"手动缩放后仍使用窗口提供的空间")
            window.setContentSize(NSSize(width:780,height:480))
            try await Task.sleep(for:.milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.bounds.height,480,accuracy:1,"小屏窗口保持可滚动的内容尺寸")
            let small = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds))
            hosting.cacheDisplay(in:hosting.bounds,to:small)
            try XCTUnwrap(small.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:"/tmp/aiusage-analysis-small-\(account.platform.rawValue).png"))
            let scroll = try XCTUnwrap(overflowScrollView(in: hosting), "小屏内容必须能够滚动到日期和来源说明")
            let document = try XCTUnwrap(scroll.documentView)
            scroll.contentView.scroll(to:NSPoint(x:0,y:document.bounds.maxY-scroll.contentView.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for:.milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y,0)
            let bottom = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds))
            hosting.cacheDisplay(in:hosting.bounds,to:bottom)
            try XCTUnwrap(bottom.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:"/tmp/aiusage-analysis-small-bottom-\(account.platform.rawValue).png"))
            window.close()
        }
    }

    func testAnalysisRendersAllPlatformsAtMinimumSizeInBothThemes() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString, defaults = UserDefaults(suiteName:name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName:name); try? FileManager.default.removeItem(at:root.directory) }
        let model = IslandModel(defaults:defaults,sessionRoot:root); model.networkAvailable = false
        model.platformAccounts = PlatformAccounts(enabled:Set(UsagePlatform.allCases))
        for account in model.savedAccounts {
            let buckets = (0..<30).map { offset -> DailyUsageBucket in
                let date = Date.now.addingTimeInterval(-Double(29-offset)*86400)
                let tokens = Int64((offset%6+1)*8_000_000)
                return .init(day:UsageAnalysisMath.day(date),tokens:tokens,cachedInput:tokens*7/10,uncachedInput:tokens/10,output:tokens*2/10,cost:Decimal(string:"1.23"),isPartial:offset == 29)
            }
            model.accountRuntime(for:account).analysis.accept(.init(source:account.platform == .deepSeek ? .deepSeek : account.platform == .chatGPT ? .chatGPT : .zhipu,buckets:buckets,currency:"CNY"))
            for scheme in [ColorScheme.dark,.light] {
                let view = UsageAnalysisView(model:model,initialAccount:account).environment(\.colorScheme,scheme).frame(width:780,height:660)
                let hosting = NSHostingView(rootView:view)
                let window = NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:660),styleMask:[.borderless],backing:.buffered,defer:false)
                window.isReleasedWhenClosed = false;window.contentView=hosting
                hosting.frame=NSRect(x:0,y:0,width:780,height:660);hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for:.milliseconds(100));hosting.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(hosting.fittingSize.width,780);XCTAssertLessThanOrEqual(hosting.fittingSize.height,660)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds)); hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:"/tmp/aiusage-analysis-\(account.platform.rawValue)-\(scheme == .dark ? "dark" : "light").png"))
                window.close()
            }
        }
    }
}
