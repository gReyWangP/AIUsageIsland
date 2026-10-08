import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

/// 排版尺寸不靠估算：这里用真实的 SwiftUI 渲染量出各排版在 1 / 2 / 3 平台下的实际尺寸，
/// `DetailMetrics` 与面板高度上限据此校验。改动行高或增删行时必须重跑。
@MainActor
final class DetailLayoutTests: XCTestCase {

    func testOfficialAnnouncementDoesNotChangeEitherLayoutHeight() throws {
        let fixture = ResetReminderTests().event(ambiguous: true)
        let event = OfficialResetAnnouncement(id: fixture.id, resetType: fixture.resetType, phase: .scheduled,
            announcedAt: .now, scheduledFor: Date.now.addingTimeInterval(86400), text: fixture.text, sourceURL: fixture.sourceURL)
        let content = try XCTUnwrap(OfficialResetCardContent.make(event, enabled: true, now: .now))
        for count in [1, 3] {
            let values = count == 1 ? [snapshot(.chatGPT)] : snapshots(3)
            let width: CGFloat = count == 1 ? 322 : 684
            let baseline = try XCTUnwrap(render(IslandDetailColumns(snapshots: values).frame(width: width)))
            var measured = CGSize.zero
            let withNotice = IslandDetailColumns(snapshots: values, officialReset: content,
                officialResetLastChecked: .now, onContentHeightChange: { _, size in measured = size }).frame(width: width)
            let image = try XCTUnwrap(render(withNotice))
            XCTAssertEqual(image.height, baseline.height, "公告只能利用已有空白，不能增加卡片高度")
            XCTAssertGreaterThan(measured.height, 0)
            snapshotPNG(withNotice, width: width, to: "/tmp/dsi-official-card-columns-\(count).png")
            let stacked = IslandDetailStacked(snapshots: values, officialReset: content, officialResetLastChecked: .now).frame(width: 527)
            let stackedBaseline = try XCTUnwrap(render(IslandDetailStacked(snapshots: values).frame(width: 527)))
            XCTAssertEqual(try XCTUnwrap(render(stacked)).height, stackedBaseline.height)
            snapshotPNG(stacked, width: 527, to: "/tmp/dsi-official-card-stacked-\(count).png")
        }
        let plain = try XCTUnwrap(render(IslandDetailColumns(snapshots: snapshots(2)).frame(width: 527)))
        let noGPT = try XCTUnwrap(render(IslandDetailColumns(snapshots: snapshots(2), officialReset: content).frame(width: 527)))
        XCTAssertEqual(plain.height, noGPT.height, "没有 ChatGPT 卡片时不能占用公告空间")
    }

    // MARK: - 夹具

    /// `UsagePlatform` 目前只有两个真实平台，但排版必须能处理 N 个。
    /// 这里用一个合成快照补足数量，验证 3 个及以上的列宽与高度。
    private func syntheticSnapshot(_ index: Int) -> PlatformSnapshot {
        PlatformSnapshot(
            id: "synthetic-\(index)",
            platform: .deepSeek,
            title: "平台\(index)",
            compactMetrics: [
                CompactMetric(id: "a", label: "今日", value: "$0.31"),
                CompactMetric(id: "b", label: "本月", value: "$6.44"),
            ],
            heroLabel: "账户余额", heroValue: "$8.20", heroSuffix: "USD",
            rows: [
                DetailMetricRow(id: "a", label: "今日", value: "$0.31", detail: "12.4万 Token"),
                DetailMetricRow(id: "b", label: "近 7 天", value: "$2.10", detail: "88.1万 Token"),
                DetailMetricRow(id: "c", label: "本月", value: "$6.44", detail: "210万 Token"),
            ],
            note: "费用与 Token 取自平台用量接口。",
            accountName: nil, isConnected: true, isSigningIn: false,
            error: nil, warning: nil,
            refreshText: "刷新：22:41"
        )
    }

    private func snapshot(_ platform: UsagePlatform,
                          connected: Bool = true,
                          error: String? = nil) -> PlatformSnapshot {
        let now = Date()
        switch platform {
        case .deepSeek:
            return PlatformSnapshot(
                id: UsagePlatform.deepSeek.rawValue,
                platform: .deepSeek,
                title: UsagePlatform.deepSeek.title,
                compactMetrics: [
                    CompactMetric(id: "tokens", label: "今日 Token", value: "0.48亿"),
                    CompactMetric(id: "cost", label: "今日费用", value: "¥1.99"),
                ],
                heroLabel: "账户余额", heroValue: "¥47.54", heroSuffix: "CNY",
                rows: [
                    DetailMetricRow(id: "today", label: "今日", value: "¥1.99", detail: "0.48亿 Token"),
                    DetailMetricRow(id: "week", label: "近 7 天", value: "¥1.99", detail: "0.48亿 Token"),
                    DetailMetricRow(id: "month", label: "本月", value: "¥2.59", detail: "0.48亿 Token"),
                ],
                note: "费用与 Token 取自平台用量接口。",
                accountName: nil, isConnected: connected, isSigningIn: false,
                error: error, warning: nil,
                refreshText: UsageFormat.refreshTime(now))
        case .zhipu:
            return PlatformSnapshot(
                id: UsagePlatform.zhipu.rawValue,
                platform: .zhipu,
                title: UsagePlatform.zhipu.title,
                compactMetrics: [
                    CompactMetric(id: "five", label: "5 小时", value: "42%"),
                    CompactMetric(id: "week", label: "本周", value: "18%"),
                ],
                heroLabel: "5 小时已用", heroValue: "42%", heroSuffix: nil,
                rows: [
                    DetailMetricRow(id: "week", label: "本周已用", value: "18%"),
                    DetailMetricRow(id: "five-reset", label: "5 小时重置", value: "9月30日 23:32"),
                    DetailMetricRow(id: "week-reset", label: "本周重置", value: "10月1日 22:32"),
                ],
                note: "按智谱页面的额度点数计算。",
                accountName: "智谱 CodingPlan · Max", isConnected: connected, isSigningIn: false,
                error: error, warning: nil,
                refreshText: UsageFormat.refreshTime(now))
        case .chatGPT:
            return PlatformSnapshot(
                id: UsagePlatform.chatGPT.rawValue,
                platform: .chatGPT,
                title: UsagePlatform.chatGPT.title,
                compactMetrics: [
                    CompactMetric(id: "session", label: "5 小时", value: "100%"),
                    CompactMetric(id: "week", label: "本周", value: "63%"),
                ],
                heroLabel: "5 小时已用", heroValue: "100%", heroSuffix: nil,
                rows: [
                    DetailMetricRow(id: "week", label: "本周已用", value: "63%"),
                    DetailMetricRow(id: "session-reset", label: "5 小时重置", value: "10月1日 20:01"),
                    DetailMetricRow(id: "week-reset", label: "本周重置", value: "10月5日 14:26"),
                ],
                note: "额度窗口与 Codex 同源。",
                accountName: "ChatGPT Plus", isConnected: connected, isSigningIn: false,
                error: error, warning: nil,
                refreshText: UsageFormat.refreshTime(now))
        }
    }

    private func snapshots(_ count: Int) -> [PlatformSnapshot] {
        var result = UsagePlatform.allCases.map { snapshot($0) }
        var index = result.count + 1
        while result.count < count {
            result.append(syntheticSnapshot(index))
            index += 1
        }
        return Array(result.prefix(count))
    }

    @discardableResult
    private func render(_ view: some View, scale: CGFloat = 1) -> CGImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = scale
        return renderer.cgImage
    }

    private func writePNG(_ image: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// 出图用：铺黑底，否则白字在透明背景上看不见。
    private func snapshotPNG(_ view: some View, width: CGFloat, to path: String) {
        let wrapped = ZStack { Color.black; view }
            .frame(width: width)
            .environment(\.colorScheme, .dark)
        guard let image = render(wrapped, scale: 2) else { return }
        writePNG(image, to: path)
    }

    /// 让设置页截图显示真实的版本号（读仓库根的 Info.plist）。
    private static func applyRealVersionForSnapshots() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DeepSeekIslandTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = plist as? [String: Any],
              let version = values["CFBundleShortVersionString"] as? String else { return }
        IslandBrand.versionOverride = version
    }

    // MARK: - 横向详情 · 并列栏

    func testColumnsContentHeightForEachPlatformCount() {
        var heights: [Int: CGFloat] = [:]
        for count in 1...3 {
            let panelWidth = DetailMetrics.panelWidth(platformCount: count,
                                                      screenWidth: 1512)
            let view = IslandDetailColumns(snapshots: snapshots(count))
                .frame(width: panelWidth - 2 * DetailMetrics.horizontalPadding)
            guard let image = render(view) else { return XCTFail("渲染失败 count=\(count)") }
            heights[count] = CGFloat(image.height)
            print("📐 并列栏 · \(count) 平台：面板宽 \(panelWidth)，列宽 "
                  + "\(DetailMetrics.columnWidth(panelWidth: panelWidth, platformCount: count))，"
                  + "内容高 \(image.height)")
            snapshotPNG(IslandDetailColumns(snapshots: snapshots(count)),
                        width: panelWidth, to: "/tmp/dsi-cols-\(count).png")
        }
        XCTAssertEqual(heights.count, 3)
        // 行数固定（表头 + hero + 3 指标 + 说明 + 刷新 + 分隔线 + 账号），
        // 所以 1/2/3 平台的内容高度应当一致——这正是共享行网格的意义。
        XCTAssertEqual(heights[1], heights[2], "1 与 2 平台内容高度应相同")
        XCTAssertEqual(heights[2], heights[3], "2 与 3 平台内容高度应相同")
    }

    func testColumnsShareRowBaselines() {
        let panelWidth = DetailMetrics.panelWidth(platformCount: 3, screenWidth: 1512)
        let view = IslandDetailColumns(snapshots: snapshots(3))
            .frame(width: panelWidth - 2 * DetailMetrics.horizontalPadding)
        guard let image = render(view) else { return XCTFail("渲染失败") }

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return XCTFail("无法建立位图上下文")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 三列各自的内容上下边界必须一致
        let third = width / 3
        func bounds(_ range: Range<Int>) -> (Int, Int)? {
            let rows = (0..<height).filter { y in
                range.contains { x in pixels[(y * width + x) * 4 + 3] > 8 }
            }
            guard let top = rows.first, let bottom = rows.last else { return nil }
            return (top, bottom)
        }
        guard let a = bounds(0..<third),
              let b = bounds(third..<(2 * third)),
              let c = bounds((2 * third)..<width) else { return XCTFail("某列没有内容") }
        print("📐 三列内容 y 范围：\(a) / \(b) / \(c)")
        XCTAssertEqual(a.0, b.0, accuracy: 1); XCTAssertEqual(b.0, c.0, accuracy: 1)
        XCTAssertEqual(a.1, b.1, accuracy: 1); XCTAssertEqual(b.1, c.1, accuracy: 1)
    }

    // MARK: - 纵向详情 · 堆叠

    func testStackedContentHeightForEachPlatformCount() {
        for count in 1...3 {
            let view = IslandDetailStacked(snapshots: snapshots(count))
                .frame(width: 565 - 2 * DetailMetrics.horizontalPadding)
            guard let image = render(view) else { return XCTFail("渲染失败 count=\(count)") }
            let panel = CGFloat(image.height) + 14 + 79
            print("📐 堆叠 · \(count) 平台：内容高 \(image.height)，面板高 \(Int(panel))，"
                  + "14″ 占 \(String(format: "%.1f", panel / 982 * 100))%")
            XCTAssertLessThanOrEqual(panel, 982 * 0.5,
                                     "\(count) 平台的面板高度不该超过屏幕一半")
            snapshotPNG(IslandDetailStacked(snapshots: snapshots(count)),
                        width: 565, to: "/tmp/dsi-stack-\(count).png")
        }
    }

    /// 错误提示会让内容变高，但两列必须一起长高而不是错位。
    func testErrorStateGrowsEvenly() {
        let plain = IslandDetailColumns(snapshots: snapshots(2))
            .frame(width: 565 - 38)
        let errored = IslandDetailColumns(snapshots: [
            snapshot(.deepSeek, error: "用量接口未接受当前网页登录授权；余额仍可读取"),
            snapshot(.zhipu),
        ]).frame(width: 565 - 38)
        guard let a = render(plain), let b = render(errored) else { return XCTFail("渲染失败") }
        print("📐 错误态：\(a.height) → \(b.height)")
        XCTAssertGreaterThan(b.height, a.height)
    }

    // MARK: - 悬浮条

    func testCompactBarSizes() {
        for layout in CompactLayout.allCases {
            for count in 1...3 {
                let view = IslandCompactBar(snapshots: snapshots(count),
                                            layout: layout,
                                            hasNotch: true,
                                            horizontalWidth: 565,
                                            notchWidth: 185,
                                            bandHeight: 32)
                guard let image = render(ZStack { Color.black; view }) else {
                    return XCTFail("渲染失败")
                }
                print("📐 悬浮条 · \(layout.title) · \(count) 平台：\(image.width) × \(image.height)")
                writePNG(image, to: "/tmp/dsi-bar-\(layout.rawValue)-\(count).png")
            }
        }
    }

    // MARK: - 设置页

    func testSettingsViewRenders() {
        // 截图上的版本号取自仓库里的 Info.plist：测试进程的 Bundle.main 是测试 runner，
        // 直接读会拿到 Xcode 的版本号（16.0），出图就假了。
        Self.applyRealVersionForSnapshots()
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek, .zhipu])
        let settings = IslandSettings(defaults: UserDefaults(suiteName: "settings-test")!)
        let view = IslandSettingsView(settings: settings, model: model)
            .frame(width: 565 - 38)
        guard let image = render(ZStack { Color.black; view }, scale: 2) else {
            return XCTFail("设置页渲染失败")
        }
        print("📐 设置页（527 宽）：\(image.width / 2) × \(image.height / 2)")
        // 独立窗口用的尺寸：宽度固定 420，量出高度
        let windowView = IslandSettingsView(settings: settings, model: model)
            .padding(18)
            .frame(width: 420)
        if let winImage = render(ZStack { Color.black; windowView }, scale: 2) {
            print("📐 设置窗口内容：\(winImage.width / 2) × \(winImage.height / 2)")
        }
        writePNG(image, to: "/tmp/dsi-settings.png")
        // 独立窗口整幅（含 logo 页眉），用于人工核对版本号与分割线位置。
        snapshotPNG(IslandSettingsView(settings: settings, model: model).padding(18),
                    width: 420, to: "/tmp/dsi-settings-window.png")
    }

    // MARK: - 标识

    /// logo 是资源包里的图，路径找错时界面只是不显示，编译和运行都不会报错，
    /// 所以这里显式断言图能取到，并把两处用到 logo 的界面出图。
    func testBrandLogoLoadsAndRenders() {
        XCTAssertNotNil(IslandBrand.logo, "没加载到 AppLogo.png：检查资源包是否随 .app 一起拷贝")
        XCTAssertEqual(IslandBrand.name, "AIUsageIsland")

        snapshotPNG(PlatformPickerView(onPick: { _ in }),
                    width: 360, to: "/tmp/dsi-picker.png")
    }

    func testSettingsPersistAcrossInstances() {
        let suite = "settings-persist-test"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let first = IslandSettings(defaults: defaults)
        XCTAssertEqual(first.compactLayout, .horizontal)
        XCTAssertEqual(first.detailLayout, .columns)
        XCTAssertEqual(first.screenSelection, .automatic)
        first.compactLayout = .vertical
        first.detailLayout = .stacked
        first.screenSelection = .display(id: 42, name: "Studio Display")

        let second = IslandSettings(defaults: defaults)
        XCTAssertEqual(second.compactLayout, .vertical)
        XCTAssertEqual(second.detailLayout, .stacked)
        XCTAssertEqual(second.screenSelection, .display(id: 42, name: "Studio Display"))

        // 只存了 ID 没有名字时视为无效记录，回退自动——显示器 ID 会随插拔变化
        defaults.removeObject(forKey: "screenDisplayName")
        XCTAssertEqual(IslandSettings(defaults: defaults).screenSelection, .automatic)
    }

    /// 悬浮条放进高容器里**不得被撑高**。
    ///
    /// 这里复现的是一个真实事故：横向悬浮条里用 `Rectangle().frame(width: 1)`
    /// 画分隔线，而 Rectangle 在高度方向是弹性的，会把整条撑到容器高度。
    /// 容器高度又来自面板尺寸（maxSize），于是形成自我强化的循环——
    /// 实测把 55 pt 的悬浮条撑到 441 pt，悬停时出现一整块黑面板。
    /// 只有 2 个平台以上才画分隔线，所以 1 个平台时看不出问题。
    func testCompactBarDoesNotStretchToContainerHeight() {
        for layout in CompactLayout.allCases {
            for count in 1...3 {
                var reported = CGSize.zero
                let bar = IslandCompactBar(snapshots: snapshots(count),
                                           layout: layout,
                                           hasNotch: false,
                                           horizontalWidth: 565,
                                           notchWidth: 185,
                                           bandHeight: 32,
                                           onContentSizeChange: { _, size in reported = size })
                // 关键：给一个远高于悬浮条的容器
                let view = ZStack(alignment: .top) { bar }
                    .frame(width: 565, height: 441)
                    .environment(\.colorScheme, .dark)
                _ = render(view)
                print("📐 高容器中的悬浮条 · \(layout.title) · \(count) 平台：上报 \(reported)")
                XCTAssertLessThan(reported.height, 220,
                                  "\(layout.title)/\(count) 平台：悬浮条被容器撑高了（\(reported)）")
            }
        }
    }

    /// 详情必须上报**完整尺寸**，不能只报高度。
    ///
    /// 事故现场：切换排版后面板停在 360 pt 宽，而卡片是 565 pt 宽，
    /// 卡片左右被裁掉、只剩中间一截。根因就是只比高度——
    /// 宽度变了而高度没变时，面板宽度永远不会刷新。
    func testDetailReportsWidthNotJustHeight() {
        for count in 1...3 {
            var columnsSize = CGSize.zero
            _ = render(IslandDetailColumns(snapshots: snapshots(count),
                                           onContentHeightChange: { _, size in columnsSize = size })
                .frame(width: 527))
            var stackedSize = CGSize.zero
            _ = render(IslandDetailStacked(snapshots: snapshots(count),
                                           onContentHeightChange: { _, size in stackedSize = size })
                .frame(width: 527))
            print("📐 \(count) 平台上报：并列栏 \(columnsSize)，堆叠 \(stackedSize)")
            for (name, size) in [("并列栏", columnsSize), ("堆叠", stackedSize)] {
                XCTAssertGreaterThan(size.width, 1,
                                     "\(name)/\(count)：必须上报宽度，否则面板宽度会僵死在旧值")
                XCTAssertGreaterThan(size.height, 1)
            }
            // 两种排版的高度确实不同（并列栏高度恒定，堆叠每加一个平台就多一张卡），
            // 但**宽度都必须上报**——这正是本用例要守住的点。
        }
    }

    /// 两种详情的尺寸必须**各自自洽**，不能交叉。
    ///
    /// 事故现场：切换排版后面板发出「新宽度 + 旧高度」的混合尺寸——
    /// 「左右两栏」拿到 360×203（变矮，栏目内容被裁），
    /// 「上下堆叠」拿到 565×410（变高，卡片下方大片留白）。
    /// 用户看到的直观感受就是「上下和左右是反的」。
    func testDetailLayoutsDoNotCrossSizes() {
        for count in 1...3 {
            var columnsContent = CGSize.zero
            _ = render(IslandDetailColumns(snapshots: snapshots(count),
                                           onContentHeightChange: { _, size in columnsContent = size })
                .frame(width: DetailMetrics.panelWidth(platformCount: count, screenWidth: 2560) - 38))
            var stackedContent = CGSize.zero
            _ = render(IslandDetailStacked(snapshots: snapshots(count),
                                           onContentHeightChange: { _, size in stackedContent = size })
                .frame(width: NotchLayout.externalBarWidth - 38))

            // 宽度策略：并列栏随平台数变化，堆叠恒定全宽
            let columnsWidth = DetailMetrics.panelWidth(platformCount: count, screenWidth: 2560)
            let stackedWidth = NotchLayout.externalBarWidth
            let columnsHeight = columnsContent.height + 79
            let stackedHeight = stackedContent.height + 79

            print("📐 \(count) 平台 → 左右两栏 \(columnsWidth)×\(columnsHeight)，上下堆叠 \(stackedWidth)×\(stackedHeight)")

            if count == 1 {
                // 单平台是用户最容易踩到的场景：并列栏窄而高，堆叠宽而矮
                XCTAssertLessThan(columnsWidth, stackedWidth, "并列栏应比堆叠窄")
                XCTAssertGreaterThan(columnsHeight, stackedHeight, "并列栏应比堆叠高")
            }
            // 无论平台数，两者的尺寸都不能相同——相同就说明发生了交叉
            XCTAssertNotEqual(CGSize(width: columnsWidth, height: columnsHeight),
                              CGSize(width: stackedWidth, height: stackedHeight),
                              "\(count) 平台：两种排版尺寸相同，宽度或高度必然有一个用错了排版")
        }
    }

    // MARK: - 面板宽度规则

    func testPanelWidthRule() {
        XCTAssertEqual(DetailMetrics.panelWidth(platformCount: 1, screenWidth: 1512), 360)
        XCTAssertEqual(DetailMetrics.panelWidth(platformCount: 2, screenWidth: 1512), 565)
        XCTAssertEqual(DetailMetrics.panelWidth(platformCount: 3, screenWidth: 1512), 722)
        // 每列不得窄于可读下限
        for count in 2...5 {
            let width = DetailMetrics.panelWidth(platformCount: count, screenWidth: 1512)
            let column = DetailMetrics.columnWidth(panelWidth: width, platformCount: count)
            XCTAssertGreaterThanOrEqual(column, DetailMetrics.minColumnWidth,
                                        "\(count) 平台的列宽 \(column) 低于下限")
        }
        // 窄屏上要按比例封顶，不能撑破屏幕
        let narrow = DetailMetrics.panelWidth(platformCount: 3, screenWidth: 800)
        XCTAssertLessThanOrEqual(narrow, 800 * DetailMetrics.maxScreenWidthRatio)
    }

    // MARK: - 快照

    func testModelBuildsOneSnapshotPerEnabledPlatform() {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek, .zhipu])
        XCTAssertEqual(model.snapshots.map(\.id), ["deepseek", "zhipu"])
        // 每个平台都要有两格悬浮指标和三行详情，排版才有统一结构可用
        for snapshot in model.snapshots {
            XCTAssertEqual(snapshot.compactMetrics.count, 2)
            XCTAssertEqual(snapshot.rows.count, 3)
            XCTAssertFalse(snapshot.note.isEmpty)
        }
    }

    func testRemovingToOnePlatformRestoresSingleColumnTitle() {
        var accounts = PlatformAccounts(enabled: [.deepSeek, .zhipu])
        XCTAssertEqual(accounts.detailTitle, "用量统计")
        XCTAssertEqual(accounts.ordered, [.deepSeek, .zhipu])
        accounts = accounts.removing(.zhipu)
        XCTAssertEqual(accounts.detailTitle, UsagePlatform.deepSeek.title)
        accounts = accounts.removing(.deepSeek)
        XCTAssertEqual(accounts.detailTitle, "选择平台")
        XCTAssertTrue(accounts.ordered.isEmpty)
    }
}
