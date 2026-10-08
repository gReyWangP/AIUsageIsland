import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class MultiAccountLayoutTests: XCTestCase {
    func testReopeningTwoAccountDetailsCorrectsStaleThreePlatformWidth() throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        let settings = IslandSettings(defaults: defaults)
        model.presentationSettings = settings; model.networkAvailable = false
        model.platformAccounts = PlatformAccounts(enabled: Set(UsagePlatform.allCases))
        model.setAccountVisible(model.activeAccountReference(for: .zhipu), visible: false)
        XCTAssertEqual(model.detailSnapshots.count, 2)
        let presentation = IslandPresentation(); presentation.mode = .expanded
        let host = NSHostingView(rootView: IslandView(model: model, presentation: presentation, settings: settings))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 722, height: 491), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        RunLoop.main.run(until: .now.addingTimeInterval(0.1))
        // Reproduce screen recovery restoring the old enabled-platform count (3),
        // while the content still has only two selected accounts.
        presentation.detailSize.width = 722
        presentation.mode = .compact
        RunLoop.main.run(until: .now.addingTimeInterval(0.05))
        presentation.mode = .expanded
        RunLoop.main.run(until: .now.addingTimeInterval(0.1))
        XCTAssertEqual(presentation.detailSize.width, 565)
    }
    private final class ScrollTarget: ObservableObject { @Published var id: String? }
    private struct FocusFixture: View {
        @ObservedObject var target: ScrollTarget
        let snapshots: [PlatformSnapshot]
        var columns = false
        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if columns { IslandDetailColumns(snapshots: snapshots) }
                        else { IslandDetailStacked(snapshots: snapshots) }
                    }.padding(18)
                }.onChange(of: target.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
    func testStackedDetailCanScrollToWeeklyRowOfNonlegacyAccount() throws { try assertScroll(columns: false) }
    func testColumnsDetailCanScrollToWeeklyRowOfNonlegacyAccount() throws { try assertScroll(columns: true) }
    private func assertScroll(columns: Bool) throws {
        let snapshots = (0..<4).map { index in
            PlatformSnapshot(id: "chatgpt:account-\(index)", platform: .chatGPT, title: "账号\(index)",
                compactMetrics: [], heroLabel: "本次", heroValue: "26%", heroSuffix: nil,
                rows: [DetailMetricRow(id: "week", label: "本周", value: "63%")], note: "",
                accountName: "账号\(index)", isConnected: true, isSigningIn: false, error: nil,
                warning: nil, refreshText: "刚刚更新")
        }
        let target = ScrollTarget()
        let hosting = NSHostingView(rootView: FocusFixture(target: target, snapshots: snapshots, columns: columns))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: columns ? 954 : 565, height: columns ? 80 : 140),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        window.orderFront(nil); hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.1))
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap { findScroll($0) }.first
        }
        let scroll = try XCTUnwrap(findScroll(hosting))
        let before = scroll.documentVisibleRect.minY
        target.id = "chatgpt:account-3-week"
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.2))
        XCTAssertGreaterThan(abs(scroll.documentVisibleRect.minY - before), 20)
    }
    private func write<V: View>(_ view: V, name: String) throws -> CGImage {
        let image: CGImage
        if name.hasPrefix("settings") {
            // ImageRenderer cannot render AppKit-backed pickers and scroll views.
            let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 680), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting
            window.appearance = NSAppearance(named: .darkAqua)
            window.orderFront(nil)
            defer { window.close() }
            hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 680)
            hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            RunLoop.main.run(until: Date.now.addingTimeInterval(0.05))
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            image = try XCTUnwrap(bitmap.cgImage)
        } else {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
            renderer.scale = 2
            image = try XCTUnwrap(renderer.cgImage)
        }
        if let path = ProcessInfo.processInfo.environment["AI_USAGE_PREVIEW_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = NSBitmapImageRep(cgImage: image)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
        return image
    }
    func testFourAccountLayoutsAndBoundedSettingsRenderAtActualSize() throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false
        model.platformAccounts = PlatformAccounts(enabled: Set(UsagePlatform.allCases))
        let work = model.accountProfiles.add(platform: .chatGPT, label: "工作 ChatGPT")
        model.accountProfiles.select(AccountProfileEntry.legacyID, for: .chatGPT)
        model.balance = Decimal(string: "47.54"); model.accountConnected = true; model.accountName = "个人账号"
        model.lastUpdated = .now
        model.zhipuConnected = true; model.zhipuLastUpdated = .now
        model.zhipuQuota = ZhipuQuota(kind: .tokens, level: "Max", fiveHour: .init(usedPercent: 42, usedValue: nil, limitValue: nil, nextReset: .now.addingTimeInterval(3600)),
                                   week: .init(usedPercent: 63, usedValue: nil, limitValue: nil, nextReset: .now.addingTimeInterval(86400)))
        model.chatGPTConnected = true; model.chatGPTLastUpdated = .now
        model.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: 26, resetAt: .now.addingTimeInterval(3600)),
                                         weekly: .init(windowSeconds: 604800, usedPercent: 63, resetAt: .now.addingTimeInterval(86400)), email: nil, accountID: nil, limitReached: false)
        let workRef = AccountReference(platform: .chatGPT, profileID: work.id)
        model.setAccountVisible(workRef, visible: true)
        let worker = model.accountRuntime(for: workRef)
        worker.chatGPTQuota = ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: 61, resetAt: .now.addingTimeInterval(3600)),
                                          weekly: .init(windowSeconds: 604800, usedPercent: 81, resetAt: .now.addingTimeInterval(86400)), email: nil, accountID: nil, limitReached: false)
        worker.chatGPTConnected = true; worker.chatGPTLastUpdated = .now
        let snapshots = model.snapshots
        XCTAssertEqual(snapshots.count, 4)
        let columnsWidth = DetailMetrics.panelWidth(platformCount: 4, screenWidth: 1512)
        let columns = try write(IslandDetailColumns(snapshots: snapshots).padding(.horizontal, 19).padding(.vertical, 14)
            .frame(width: columnsWidth).background(Color.black), name: "detail-horizontal")
        XCTAssertEqual(columns.width / 2, 954)
        let stacked = try write(IslandDetailStacked(snapshots: snapshots).padding(.horizontal, 19).padding(.vertical, 14)
            .frame(width: 565).background(Color.black), name: "detail-vertical")
        XCTAssertGreaterThan(stacked.height, columns.height)
        for layout in CompactLayout.allCases {
            let image = try write(IslandCompactBar(snapshots: snapshots, layout: layout, hasNotch: true,
                horizontalWidth: 565, notchWidth: 185, bandHeight: 32).background(Color.black), name: "compact-" + layout.rawValue)
            XCTAssertEqual(image.width / 2, layout == .horizontal ? 565 : 185)
        }
        let settings = IslandSettings(defaults: defaults)
        settings.showsMenuBarItem = true
        settings.menuBarAccount = workRef
        let previousVersion = IslandBrand.versionOverride
        IslandBrand.versionOverride = "1.19.5"
        defer { IslandBrand.versionOverride = previousVersion }
        for page in [0, 1] {
            let image = try write(IslandSettingsView(settings: settings, model: model, initiallySelectedPage: page)
                .padding(18).frame(width: 680, height: 680).background(IslandSettingsBackground(settings: settings)), name: page == 0 ? "settings-layout" : "settings-accounts")
            XCTAssertEqual(image.width / 2, 680); XCTAssertEqual(image.height / 2, 680)
        }
    }
}
