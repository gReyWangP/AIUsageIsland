import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

/// 使用真实 NSHostingView 验证动画完成回调，不依赖固定等待时间收拢窗口。
@MainActor
final class IslandAnimationIntegrationTests: XCTestCase {
    func testRemovingPlatformRecomputesWidthEvenWhenMeasuredHeightDoesNotChange() {
        for removeWhileHidden in [false, true] {
            let presentation = IslandPresentation()
            let settings = IslandSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            settings.detailLayout = .columns
            let model = IslandModel()
            model.platformAccounts = PlatformAccounts(enabled: [.zhipu, .chatGPT])
            model.zhipuConnected = true; model.chatGPTConnected = true
            model.errorMessage = nil; model.chatGPTError = nil
            let host = NSHostingView(rootView: IslandView(model: model, presentation: presentation, settings: settings))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.alphaValue = 0; window.orderFront(nil)
            presentation.mode = .expanded
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(presentation.detailSize.width, 565)
            let height = presentation.detailHeights[DetailLayout.columns.rawValue]
            if removeWhileHidden { presentation.mode = .compact }
            model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            presentation.mode = .expanded
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(presentation.detailHeights[DetailLayout.columns.rawValue], height)
            XCTAssertEqual(presentation.detailSize.width, 360, "删除平台后即使行高没变，背景也必须收回单平台宽度")
            window.close()
        }
    }

    func testSurfaceCompletionArrivesAfterRapidReversal() {
        let presentation = IslandPresentation()
        let settings = IslandSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [])
        let view = NSHostingView(rootView: IslandView(model: model, presentation: presentation,
                                                     settings: settings))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let settled = expectation(description: "反向操作的最新动画完成")
        var latestCompleted = false
        presentation.onSurfaceSettled = { revision in
            if revision == 2 && !latestCompleted {
                latestCompleted = true
                settled.fulfill()
            }
        }
        presentation.surfaceTransition = IslandSurfaceTransition(
            revision: 1, size: CGSize(width: 565, height: 350), mode: .expanded, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            presentation.surfaceTransition = IslandSurfaceTransition(
                revision: 2, size: CGSize(width: 200, height: 55), mode: .compact, animated: true)
        }
        wait(for: [settled], timeout: 3)
        XCTAssertTrue(latestCompleted)
    }

    func testScreenGeometryUpdatesCompactSizeWithoutChangingCardHeights() {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek, .zhipu])
        var reported = CGSize.zero
        let capture: (CompactLayout, CGSize) -> Void = { _, size in reported = size }
        let host = NSHostingView(rootView: IslandCompactBar(
            snapshots: model.snapshots, layout: .vertical, hasNotch: false,
            horizontalWidth: 565, notchWidth: 0, bandHeight: 0,
            onContentSizeChange: capture))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(reported, CGSize(width: 200, height: 110))
        host.rootView = IslandCompactBar(
            snapshots: model.snapshots, layout: .vertical, hasNotch: true,
            horizontalWidth: 565, notchWidth: 185, bandHeight: 32,
            onContentSizeChange: capture)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(reported, CGSize(width: 185, height: 142),
                       "自然卡片高度不变时也应报告新屏幕的宽度和刘海占位")
    }

    func testImmediateSurfaceUpdateStillReportsCompletion() {
        let presentation = IslandPresentation()
        let settings = IslandSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [])
        let view = NSHostingView(rootView: IslandView(model: model, presentation: presentation,
                                                     settings: settings))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let settled = expectation(description: "无空间动画时也能收拢窗口")
        var completed = false
        presentation.onSurfaceSettled = { revision in
            if revision == 1 && !completed {
                completed = true
                settled.fulfill()
            }
        }
        presentation.surfaceTransition = IslandSurfaceTransition(
            revision: 1, size: CGSize(width: 565, height: 350), mode: .expanded, animated: false)
        wait(for: [settled], timeout: 3)
        XCTAssertTrue(completed)
    }
}
