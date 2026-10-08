import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class IslandCompactScreenLayoutTests: XCTestCase {
    func testSinglePlatformUsesBothNotchWingsWithoutContentBelowCamera() {
        let result = render(count: 1, hasNotch: true, layout: .horizontal)
        XCTAssertEqual(result.size, CGSize(width: 565, height: 32))
        XCTAssertGreaterThan(result.leftPixels, 10)
        XCTAssertGreaterThan(result.rightPixels, 10)
        XCTAssertEqual(result.cameraPixels, 0, "摄像头占位不得有文字")
        XCTAssertEqual(result.belowPixels, 0, "单平台横向数据应在刘海两侧，而不是下方")
    }

    func testTwoPlatformsHaveOneCardInEachNotchWing() {
        let result = render(count: 2, hasNotch: true, layout: .horizontal)
        XCTAssertEqual(result.size, CGSize(width: 565, height: 55))
        XCTAssertGreaterThan(result.leftPixels, 10)
        XCTAssertGreaterThan(result.rightPixels, 10)
        XCTAssertEqual(result.cameraPixels, 0)
    }

    func testThreePlatformsStayBelowNotchForReadableColumns() {
        let result = render(count: 3, hasNotch: true, layout: .horizontal)
        XCTAssertEqual(result.size, CGSize(width: 565, height: 87))
        XCTAssertEqual(result.cameraPixels, 0)
        XCTAssertGreaterThan(result.belowPixels, 10)
    }

    func testVerticalAndExternalLayoutsKeepTheirExistingSizes() {
        for count in 1...3 {
            XCTAssertEqual(render(count: count, hasNotch: true, layout: .vertical).size,
                           CGSize(width: 185, height: 32 + 55 * count))
            XCTAssertEqual(render(count: count, hasNotch: false, layout: .horizontal).size,
                           CGSize(width: 565, height: 55))
            XCTAssertEqual(render(count: count, hasNotch: false, layout: .vertical).size,
                           CGSize(width: 200, height: 55 * count))
        }
    }

    private func render(count: Int, hasNotch: Bool, layout: CompactLayout)
        -> (size: CGSize, leftPixels: Int, rightPixels: Int, cameraPixels: Int, belowPixels: Int) {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek, .zhipu])
        var snapshots = Array(model.snapshots.prefix(count))
        if count == 3 {
            let original = snapshots[0]
            snapshots.append(PlatformSnapshot(
                id: "third", platform: original.platform, title: "第三平台",
                compactMetrics: original.compactMetrics, heroLabel: original.heroLabel,
                heroValue: original.heroValue, heroSuffix: original.heroSuffix, rows: original.rows,
                note: original.note, accountName: nil, isConnected: false, isSigningIn: false,
                error: nil, warning: nil, refreshText: nil))
        }
        var reported = CGSize.zero
        let host = NSHostingView(rootView: IslandCompactBar(
            snapshots: snapshots, layout: layout, hasNotch: hasNotch,
            horizontalWidth: 565, notchWidth: 185, bandHeight: 32,
            onContentSizeChange: { _, size in reported = size })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 565, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["ISLAND_ANIMATION_CAPTURE_DIR"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("compact-\(hasNotch)-\(count)-\(layout).png"))
        }
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        var left = 0, right = 0, camera = 0, below = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y), c.alphaComponent > 0.2 else { continue }
                let pointX = CGFloat(x) / scale, pointY = CGFloat(y) / scale
                if pointY < 32 {
                    if pointX < 190 { left += 1 }
                    else if pointX >= 375 { right += 1 }
                    else { camera += 1 }
                } else { below += 1 }
            }
        }
        return (reported, left, right, camera, below)
    }
}
