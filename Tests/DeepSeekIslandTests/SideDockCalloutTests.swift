import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor final class SideDockCalloutTests: XCTestCase {
    func testPointerFollowsIconWhenCardIsClampedAndMirrors() {
        let card = CGRect(x: 100, y: 100, width: 384, height: 300)
        XCTAssertEqual(SideDockCalloutLayout.pointerY(icon: CGRect(x: 500, y: 310, width: 40, height: 40), card: card), 70)
        XCTAssertEqual(SideDockCalloutLayout.pointerY(icon: CGRect(x: 500, y: 500, width: 40, height: 40), card: card), 46)
        XCTAssertEqual(SideDockCalloutLayout.pointerY(icon: CGRect(x: 500, y: 0, width: 40, height: 40), card: card), 254)
        let rect = CGRect(x: 10, y: 20, width: 384, height: 300)
        let right = SideDockCalloutShape(pointsLeft: false, pointerY: 70).path(in: rect)
        let left = SideDockCalloutShape(pointsLeft: true, pointerY: 70).path(in: rect)
        XCTAssertTrue(right.contains(CGPoint(x: rect.maxX - 12, y: rect.minY + 70)))
        XCTAssertFalse(right.contains(CGPoint(x: rect.maxX - 12, y: rect.minY + 110)))
        XCTAssertTrue(left.contains(CGPoint(x: rect.minX + 12, y: rect.minY + 70)))
        XCTAssertFalse(left.contains(CGPoint(x: rect.minX + 12, y: rect.minY + 110)))
        for x in stride(from: CGFloat(6), through: 350, by: 4) {
            for y in stride(from: CGFloat(30), through: 270, by: 4) {
                XCTAssertEqual(right.contains(CGPoint(x: rect.minX + x, y: rect.minY + y)),
                               left.contains(CGPoint(x: rect.maxX - x, y: rect.minY + y)))
            }
        }
    }

    func testDetailsTrackSelectedIconInsteadOfWholeSidebar() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let settings = IslandSettings(defaults: defaults)
        settings.displayMode = .sideDock
        settings.pausesHoverInFullscreen = false
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek, .chatGPT, .zhipu])
        let controller = FloatingStatusController(model: model, settings: settings)
        defer { controller.stop() }
        controller.update(pointer: CGPoint(x: -10000, y: -10000))
        try await Task.sleep(for: .milliseconds(200))
        let first = try XCTUnwrap(model.savedAccounts.first { $0.platform == .chatGPT })
        let second = try XCTUnwrap(model.savedAccounts.first { $0.platform == .zhipu })
        controller.showDetails(account: first)
        try await Task.sleep(for: .milliseconds(100))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentViewController is NSHostingController<MenuBarPopoverView> })
        let host = try XCTUnwrap(panel.contentViewController as? NSHostingController<MenuBarPopoverView>)
        XCTAssertTrue(host.rootView.sideDockCallout)
        XCTAssertFalse(host.rootView.calloutPointsLeft)
        let bottomTarget = panel.frame.maxY - host.rootView.calloutSurface.pointerY
        controller.showDetails(account: second)
        try await Task.sleep(for: .milliseconds(100))
        let topTarget = panel.frame.maxY - host.rootView.calloutSurface.pointerY
        XCTAssertEqual(topTarget - bottomTarget, SideDockLayout.itemHeight + 2, accuracy: 2)
        settings.sideDockOnLeft = true
        controller.update()
        try await Task.sleep(for: .milliseconds(350))
        controller.showDetails(account: first)
        XCTAssertTrue(host.rootView.calloutPointsLeft)
    }

    func testRenderCurvedPointer() throws {
        let preview = ZStack {
            LinearGradient(colors: [.cyan.opacity(0.65), .blue.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Codex 用量").font(.system(size: 17, weight: .medium))
                    Text("5 小时额度                         剩余 21%")
                    ProgressView(value: 0.21).tint(.green)
                    Text("悬停图标，查看对应平台详情").font(.caption).foregroundStyle(.gray)
                }.foregroundStyle(.white).padding(20).frame(width: 300, height: 170)
                .padding(.trailing, 24)
                .background(.black)
                .clipShape(SideDockCalloutShape(pointsLeft: false, pointerY: 85))
                ZStack {
                    Color.black
                    VStack(spacing: 8) {
                        Image(nsImage: MenuBarRenderer.image(platform: .chatGPT, data: .quota(remaining: 21), dark: true, thickness: .standard))
                            .resizable().aspectRatio(contentMode: .fit).frame(width: 40, height: 38)
                        Text("21%").font(.system(size: 12)).foregroundStyle(.white)
                    }
                }.frame(width: 62, height: 190)
                    .clipShape(SideDockShape(docked: true, onLeft: false, curveDepth: SideDockLayout.defaultCurveDepth))
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }.frame(width: 450, height: 280)
        let renderer = ImageRenderer(content: preview)
        renderer.scale = 2
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/aiusage-side-dock-callout.png"))
    }
}
