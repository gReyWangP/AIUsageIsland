import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class IslandCenteredAnimationTests: XCTestCase {
    func testCompactPortraitToLandscapeRemainsCenteredWhileHeightShrinks() {
        checkTransition(from: CGSize(width: 200, height: 110),
                        to: CGSize(width: 565, height: 55), mode: .compact,
                        platforms: [.deepSeek, .zhipu], reverse: false)
    }

    func testCompactLandscapeToPortraitRemainsCenteredWhileHeightGrows() {
        checkTransition(from: CGSize(width: 565, height: 55),
                        to: CGSize(width: 200, height: 110), mode: .compact,
                        platforms: [.deepSeek, .zhipu], reverse: true)
    }

    func testNotchedSinglePlatformExpandsFromVerticalToBothWings() {
        checkTransition(from: CGSize(width: 185, height: 87),
                        to: CGSize(width: 565, height: 32), mode: .compact,
                        platforms: [.deepSeek], reverse: false, hasNotch: true)
    }

    func testNotchedSinglePlatformCollapsesFromBothWingsToVertical() {
        checkTransition(from: CGSize(width: 565, height: 32),
                        to: CGSize(width: 185, height: 87), mode: .compact,
                        platforms: [.deepSeek], reverse: true, hasNotch: true)
    }

    func testDetailBecomesWiderAndShorterAroundSameCenter() {
        checkTransition(from: CGSize(width: 360, height: 396),
                        to: CGSize(width: 565, height: 203), mode: .expanded,
                        platforms: [.deepSeek], reverse: false)
    }

    func testDetailBecomesNarrowerAndTallerAroundSameCenter() {
        checkTransition(from: CGSize(width: 565, height: 203),
                        to: CGSize(width: 360, height: 396), mode: .expanded,
                        platforms: [.deepSeek], reverse: true)
    }

    func testDetailTextIsMeasuredAtLayoutWidthThroughoutTransition() {
        let presentation = IslandPresentation()
        presentation.mode = .expanded
        presentation.detailSize = CGSize(width: 360, height: 396)
        presentation.surfaceTransition = IslandSurfaceTransition(
            revision: 1, size: presentation.detailSize, mode: .expanded, animated: false)
        let domain = UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = IslandSettings(defaults: defaults)
        settings.detailLayout = .columns
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek])
        var measurements: [CGSize] = []
        let host = NSHostingView(rootView:
            IslandView(model: model, presentation: presentation, settings: settings)
                .onPreferenceChange(DetailSizeKey.self) { measurements.append($0) })
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 565, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        for layout in [DetailLayout.stacked, .columns] {
            measurements.removeAll()
            withAnimation(IslandMotion.surface) {
                settings.detailLayout = layout
                let target = CGSize(width: layout == .stacked ? 565 : 360, height: 396)
                presentation.detailSize = target
                presentation.surfaceTransition = IslandSurfaceTransition(
                    revision: presentation.surfaceTransition.revision + 1,
                    size: target, mode: .expanded, animated: true)
            }
            for _ in 0..<20 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.04))
                host.layoutSubtreeIfNeeded()
            }
            // 模拟 AppKit 在动画完成后收拢包络，内容也不能再重排一次。
            let settled = measurements.last { $0.width > 0 }
            let settledWidth: CGFloat = layout == .stacked ? 565 : 360
            window.setFrame(NSRect(x: -10000, y: -10000, width: settledWidth, height: 500), display: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(measurements.last { $0.width > 0 }, settled,
                           "收拢窗口包络不应使文字再次换行或改变内容高度")
            let widths = measurements.filter { $0.width > 0 }.map(\.width)
            XCTAssertFalse(widths.isEmpty)
            let intermediate = widths.filter { abs($0 - 322) > 0.5 && abs($0 - 527) > 0.5 }
            XCTAssertTrue(intermediate.isEmpty,
                          "文字不应在外框的中间宽度反复重排：\(intermediate)")
        }
    }

    func testNarrowerDetailCardStaysCenteredThroughRemovalAndWindowSettling() {
        checkCardTransition(from: .stacked, to: .columns)
    }

    func testWiderDetailCardStaysCenteredThroughRemovalAndWindowSettling() {
        checkCardTransition(from: .columns, to: .stacked)
    }

    private func checkCardTransition(from initialLayout: DetailLayout, to targetLayout: DetailLayout,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let initial = CGSize(width: initialLayout == .stacked ? 565 : 360,
                             height: initialLayout == .stacked ? 203 : 411)
        let target = CGSize(width: targetLayout == .stacked ? 565 : 360,
                            height: targetLayout == .stacked ? 203 : 411)
        let presentation = IslandPresentation()
        presentation.mode = .expanded
        presentation.detailSize = initial
        presentation.surfaceTransition = IslandSurfaceTransition(
            revision: 1, size: initial, mode: .expanded, animated: false)
        let domain = UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = IslandSettings(defaults: defaults)
        settings.detailLayout = initialLayout
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek])
        let host = NSHostingView(rootView: IslandView(model: model, presentation: presentation, settings: settings))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 565, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let screenCenter = window.frame.midX
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        withAnimation(IslandMotion.surface) {
            settings.detailLayout = targetLayout
            presentation.detailSize = target
            presentation.surfaceTransition = IslandSurfaceTransition(
                revision: 2, size: target, mode: .expanded, animated: true)
        }
        var checkedFrames = 0
        for index in 0..<30 {
            if index == 20 {
                // 保持屏幕中心与顶边，模拟实际动画完成后的包络收拢。
                window.setFrame(NSRect(x: screenCenter - target.width / 2,
                                       y: window.frame.maxY - target.height,
                                       width: target.width, height: target.height), display: true)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            // 标题下方的深灰底板可直接检出卡片整体横移，避开外框和文字。
            let y = Int(65 * scale)
            let pixels = (0..<bitmap.pixelsWide).filter { x in
                guard let c = bitmap.colorAt(x: x, y: y) else { return false }
                return c.alphaComponent > 0.9 && c.redComponent > 0.02 && c.redComponent < 0.15
            }
            if let left = pixels.first, let right = pixels.last {
                let visibleWidth = CGFloat(right - left + 1) / scale
                if abs(visibleWidth - (target.width - 38)) < 2 {
                    checkedFrames += 1
                    let center = window.frame.minX + CGFloat(left + right + 1) / (2 * scale)
                    XCTAssertEqual(center, screenCenter, accuracy: 1.5,
                                   "目标卡片第\(index)帧应独立保持居中，不能随外框或滚动条槽位漂移",
                                   file: file, line: line)
                }
            }
        }
        XCTAssertGreaterThan(checkedFrames, 10, "应检查到过渡和收拢后的可见卡片", file: file, line: line)
    }

    /// 截取真实 SwiftUI 动画帧并测量不透明底板；改变外层画布数值 frame
    /// 将使增长方向第一帧先偏向左侧，此断言可直接检出该回归。
    private func checkTransition(from initial: CGSize, to target: CGSize,
                                 mode: IslandPresentation.Mode,
                                 platforms: Set<UsagePlatform>, reverse: Bool, hasNotch: Bool = false,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let presentation = IslandPresentation()
        presentation.compactSize = mode == .compact ? initial : CGSize(width: 200, height: 55)
        presentation.detailSize = mode == .expanded ? initial : CGSize(width: 565, height: 396)
        presentation.mode = mode
        presentation.hasNotch = hasNotch
        if hasNotch {
            presentation.notchWidth = 185
            presentation.bandHeight = 32
            presentation.topInset = 41
        }
        presentation.surfaceTransition = IslandSurfaceTransition(
            revision: 1, size: initial, mode: mode, animated: false)
        let domain = UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = IslandSettings(defaults: defaults)
        settings.compactLayout = reverse ? .horizontal : .vertical
        settings.detailLayout = reverse ? .stacked : .columns
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: platforms)
        model.accountConnected = true
        let host = NSHostingView(rootView: IslandView(model: model, presentation: presentation, settings: settings))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: initial.width, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let width = max(initial.width, target.width)
        withAnimation(IslandMotion.surface) {
            window.setFrame(NSRect(x: -10000 - (width - initial.width) / 2,
                                   y: -10000, width: width, height: 450), display: true)
            if mode == .compact {
                settings.compactLayout = reverse ? .vertical : .horizontal
                presentation.compactSize = target
            } else {
                settings.detailLayout = reverse ? .columns : .stacked
                presentation.detailSize = target
            }
            presentation.surfaceTransition = IslandSurfaceTransition(
                revision: 2, size: target, mode: mode, animated: true)
        }
        for index in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                XCTFail("无法截取动画帧", file: file, line: line); return
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["ISLAND_ANIMATION_CAPTURE_DIR"],
               let png = bitmap.representation(using: .png, properties: [:]) {
                let path = URL(fileURLWithPath: directory)
                    .appendingPathComponent("\(mode)-\(reverse)-\(index).png")
                try? png.write(to: path)
            }
            var minX = bitmap.pixelsWide
            var maxX = -1
            var maxY = -1
            var headerMinX = bitmap.pixelsWide
            var accentSamples = 0
            var cameraTextSamples = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.8 {
                        minX = min(minX, x); maxX = max(maxX, x); maxY = max(maxY, y)
                        if color.blueComponent - color.redComponent > 0.15 { accentSamples += 1 }
                        if hasNotch, CGFloat(y) < 32 * CGFloat(bitmap.pixelsWide) / width,
                           abs(CGFloat(x) - CGFloat(bitmap.pixelsWide) / 2) < 92.5 * CGFloat(bitmap.pixelsWide) / width,
                           max(color.redComponent, color.greenComponent, color.blueComponent) > 0.2 {
                            cameraTextSamples += 1
                        }
                        if y >= 28 && y <= 56,
                           max(color.redComponent, color.greenComponent, color.blueComponent) > 0.4 {
                            headerMinX = min(headerMinX, x)
                        }
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(maxX, minX, "底板不应闪空", file: file, line: line)
            XCTAssertEqual(cameraTextSamples, 0, "过渡期间也不能把文字放入相机区域", file: file, line: line)
            let scale = CGFloat(bitmap.pixelsWide) / width
            let center = CGFloat(minX + maxX + 1) / 2
            let expected = CGFloat(bitmap.pixelsWide) / 2
            print("\(mode) 帧\(index): 宽\(CGFloat(maxX-minX+1)/scale)，高\(CGFloat(maxY+1)/scale)，中心偏移\((center-expected)/scale)")
            XCTAssertEqual(center, expected, accuracy: 5, "画布尺寸变化不能把中心拉向一侧", file: file, line: line)
            // 第一帧应保留中间高度，而不是直接采用目标高度。
            if index == 0 {
                if mode == .compact && !reverse {
                    XCTAssertGreaterThan(accentSamples, 3, "平台标题不能因目标宽度提前生效而全部被裁掉", file: file, line: line)
                }
                if mode == .expanded && !reverse {
                    XCTAssertGreaterThanOrEqual(headerMinX, minX + 12,
                                         "详情标题应随居中的内容框移动，不能被左边缘裁断", file: file, line: line)
                }
                let height = CGFloat(maxY + 1) / scale
                if initial.height > target.height {
                    XCTAssertGreaterThan(height, target.height + 5, "高度不应先跳到矮状态", file: file, line: line)
                } else {
                    XCTAssertLessThan(height, target.height - 5, "高度不应先跳到高状态", file: file, line: line)
                }
            }
        }
    }
}
