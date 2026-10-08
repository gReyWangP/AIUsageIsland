import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class ProductImprovementsRenderTests: XCTestCase {
    func testToolsAndTrendRenderAtTheirActualWidths() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root), settings = IslandSettings(defaults: defaults)
        model.networkAvailable = false; model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        let runtime = model.accountRuntime(for: model.activeAccountReference(for: .chatGPT))
        let now = Date.now, reset = now.addingTimeInterval(3600)
        for index in 0..<12 {
            runtime.trend.record(metric: .chatGPTFiveHour, value: Double(index * 3), unit: "%", resetAt: reset, at: now.addingTimeInterval(Double(index - 12) * 300))
        }
        let views: [(String, AnyView, NSSize)] = [
            ("tools", AnyView(ProductToolsSettingsView(model: model, settings: settings).padding(22).frame(width: 480, height: 260)), NSSize(width: 480, height: 260)),
            ("trend", AnyView(UsageTrendView(runtime: runtime, accountName: "ChatGPT")), NSSize(width: 620, height: 440))
        ]
        for (name, content, size) in views {
            let hosting = NSHostingView(rootView: content.environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua); window.contentView = hosting
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.fittingSize.width, size.width)
            XCTAssertEqual(hosting.fittingSize.height, size.height)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/aiusage-product-\(name).png"))
            window.close()
        }
    }
}
