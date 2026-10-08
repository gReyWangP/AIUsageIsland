import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

private actor AnalysisEntryService: ChatGPTServing {
    private var quotaCalls = 0
    func fetchQuota(grant: ChatGPTGrant) async throws -> ChatGPTQuota {
        quotaCalls += 1
        return .init(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: 10, resetAt: nil), weekly: nil, email: nil, accountID: nil, limitReached: false)
    }
    func refresh(_ grant: ChatGPTGrant) async throws -> ChatGPTGrant { grant }
    func count() -> Int { quotaCalls }
}

@MainActor
final class AnalysisEntryTests: XCTestCase {
    func testPresentingCachedStatisticsDoesNotRefreshEvenWhenCacheIsOld() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        root.saveChatGPTGrant(.init(accessToken: "fixture", refreshToken: "fixture-refresh", accountID: "fixture-id", savedAt: .now))
        let service = AnalysisEntryService()
        let model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTClient: service)
        let runtime = model.selectedRuntime(for: .chatGPT)
        defer { runtime.disposeAccountRuntime() }
        runtime.analysis.accept(.init(source: .chatGPT, buckets: [.init(day: "2026-10-01", tokens: 123)], updatedAt: .now.addingTimeInterval(-3600)))
        for _ in 0..<2 {
            let host = NSHostingView(rootView: UsageAnalysisAccountView(runtime: runtime).frame(width: 780, height: 600))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            window.close()
        }
        let calls = await service.count()
        XCTAssertEqual(calls, 0, "切换到已有缓存的统计页不应额外请求；刷新由用户明确操作")
    }
}
