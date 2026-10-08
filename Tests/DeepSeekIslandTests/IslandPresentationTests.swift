import XCTest
@testable import DeepSeekIsland

final class IslandPresentationTests: XCTestCase {
    @MainActor
    func testExpandedIslandCanCloseDirectlyToNotch() {
        let presentation = IslandPresentation()
        var expansionChanges: [Bool] = []
        presentation.onExpansionChanged = { expansionChanges.append($0) }

        presentation.mode = .expanded
        XCTAssertTrue(presentation.visible)
        XCTAssertTrue(presentation.expanded)

        presentation.mode = .hidden
        XCTAssertFalse(presentation.visible)
        XCTAssertFalse(presentation.expanded)
        XCTAssertEqual(expansionChanges, [true, false])
    }

    @MainActor
    func testSuccessfulSignInOpensTemporaryDetailsWithoutPinning() {
        let presentation = IslandPresentation()
        let now = Date(timeIntervalSince1970: 100)
        presentation.openDetails(at: now)
        XCTAssertEqual(presentation.mode, .expanded)
        XCTAssertFalse(presentation.pinned)
        XCTAssertTrue(presentation.shouldWaitBeforeHiding(at: now.addingTimeInterval(5), pointerInside: false))
        XCTAssertFalse(presentation.shouldWaitBeforeHiding(at: now.addingTimeInterval(7), pointerInside: false))
    }

    @MainActor
    func testMovingIntoDetailsEndsTemporaryGraceAndExplicitPinPersists() {
        let presentation = IslandPresentation()
        let now = Date(timeIntervalSince1970: 100)
        presentation.openDetails(at: now)
        XCTAssertFalse(presentation.shouldWaitBeforeHiding(at: now.addingTimeInterval(1), pointerInside: true))
        XCTAssertFalse(presentation.shouldWaitBeforeHiding(at: now.addingTimeInterval(2), pointerInside: false))
        presentation.pinned = true
        presentation.openDetails(at: now.addingTimeInterval(3))
        XCTAssertTrue(presentation.pinned)
    }

    @MainActor
    func testDetailWindowAndContentShareHalfScreenHeightLimit() {
        let presentation = IslandPresentation()
        presentation.screenHeight = 800
        presentation.detailHeights[DetailLayout.stacked.rawValue] = 700
        let size = presentation.detailSize(for: .stacked, platformCount: 2)
        XCTAssertEqual(size.height, 400,
                       "窗口和可见详情应共用高度上限，否则动画和鼠标判定会覆盖空白区域")
    }

    func testOnlyAppOpenLinkCanRevealDetails() {
        XCTAssertTrue(IslandOpenURL.isOpenRequest(URL(string: "deepseekisland://open")!))
        XCTAssertFalse(IslandOpenURL.isOpenRequest(URL(string: "deepseekisland://other")!))
        XCTAssertFalse(IslandOpenURL.isOpenRequest(URL(string: "https://example.com/open")!))
    }

    /// 设置窗口是独立窗口，岛的收起／展开不该影响它。
    ///
    /// 早先设置页塞在详情面板里，面板一收就得复位；现在它是独立窗口，
    /// 用户完全可以收起岛、留着设置窗口慢慢调。
    @MainActor
    func testSettingsWindowIsIndependentOfPanelMode() {
        let presentation = IslandPresentation()
        presentation.showingSettings = true

        presentation.mode = .expanded
        presentation.mode = .hidden
        let afterHide = presentation.showingSettings
        XCTAssertTrue(afterHide, "岛收起时设置窗口不该跟着关")

        presentation.mode = .compact
        let afterCompact = presentation.showingSettings
        XCTAssertTrue(afterCompact)
    }

    /// `@Published` 在 willSet 阶段发信号——**闭包内读到的属性还是旧值**。
    ///
    /// 这条不是测我们的代码，而是把踩过的坑钉在这里：
    /// `applyPresentation` 曾经在订阅回调里回头读 `presentation.detailSize`，
    /// 于是每次都用上一次的尺寸，面板永远慢一拍——
    /// 表现为「内容已经换排版了，面板宽高还是旧的，卡片被裁 / 大片留白」。
    /// 正确做法是把闭包收到的值当参数传下去。
    func testPublishedEmitsBeforeValueIsSet() {
        final class Box: ObservableObject { @Published var size = CGSize.zero }
        let box = Box()
        var seenInsideSink: CGSize?
        let token = box.$size.sink { _ in seenInsideSink = box.size }
        defer { token.cancel() }

        box.size = CGSize(width: 100, height: 100)

        XCTAssertEqual(seenInsideSink, .zero,
                       "@Published 在 willSet 发信号，闭包内应读到旧值；"
                       + "若这条断言失败，说明语义变了，applyPresentation 的显式尺寸参数可以简化")
    }
}
