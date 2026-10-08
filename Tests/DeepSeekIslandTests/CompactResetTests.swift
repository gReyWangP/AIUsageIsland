import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland
final class CompactResetTests: XCTestCase {
    @MainActor
    func testActualCompactLayoutsGroupResetWithoutIncreasingHeight() throws {
        _ = NSApplication.shared
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.zhipu])
        let five = Date.now.addingTimeInterval(3600), week = Date.now.addingTimeInterval(7 * 86400)
        model.zhipuQuota = ZhipuQuota(kind: .tokens, level: nil,
            fiveHour: .init(usedPercent: 17, usedValue: nil, limitValue: nil, nextReset: five),
            week: .init(usedPercent: 74, usedValue: nil, limitValue: nil, nextReset: week))
        let snapshot = model.snapshot(for: .zhipu)
        XCTAssertEqual(snapshot.compactMetrics.first?.resetAt, five)
        XCTAssertEqual(snapshot.compactMetrics.last?.resetAt, week)
        var baseline = snapshot
        for i in baseline.compactMetrics.indices { baseline.compactMetrics[i].resetAt = nil }
        for hasNotch in [false, true] {
            for layout in [CompactLayout.horizontal, .vertical] {
                let width: CGFloat = layout == .horizontal ? 565 : (hasNotch ? 185 : 200)
                func render(_ data: PlatformSnapshot) throws -> CGImage {
                    let view = IslandCompactBar(snapshots: [data], layout: layout, hasNotch: hasNotch,
                        horizontalWidth: 565, notchWidth: 185, bandHeight: 32).frame(width: width)
                        .foregroundStyle(.white).background(.black).environment(\.colorScheme, .dark)
                    let renderer = ImageRenderer(content: view); renderer.scale = 2
                    return try XCTUnwrap(renderer.cgImage)
                }
                let image = try render(snapshot), before = try render(baseline)
                XCTAssertEqual(image.height, before.height)
                let bitmap = NSBitmapImageRep(cgImage: image)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/tmp/dsi-grouped-reset-\(layout.rawValue)-\(hasNotch).png"))
            }
        }
    }
    func testBeijingTimeSameDayCrossDayAndPendingWithoutInventingUnknown() {
        let now = ISO8601DateFormatter().date(from: "2026-10-02T06:00:00Z")!
        var metric = CompactMetric(id: "five", label: "5小时剩余", value: "83%")
        XCTAssertNil(metric.resetText(at: now))
        metric.resetAt = now.addingTimeInterval(3600)
        XCTAssertEqual(metric.resetText(at: now), "15:00")
        metric.resetAt = now.addingTimeInterval(86400)
        XCTAssertEqual(metric.resetText(at: now), "10月3日 14:00")
        metric.resetAt = now.addingTimeInterval(-1)
        XCTAssertEqual(metric.resetText(at: now), "待刷新")
        XCTAssertEqual(metric.value, "83%")
    }
}
