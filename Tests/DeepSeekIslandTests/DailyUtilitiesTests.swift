import XCTest
@testable import DeepSeekIsland

@MainActor
final class DailyUtilitiesTests: XCTestCase {
    func testCachedDataIsMarkedFailedOrOffline() {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek])
        model.accountConnected = true
        model.balance = 39
        model.lastUpdated = Date()
        model.errorMessage = "请求失败"
        XCTAssertTrue(model.freshness(for: .deepSeek).label.contains("缓存"))
        model.networkAvailable = false
        XCTAssertTrue(model.freshness(for: .deepSeek).label.contains("离线"))
        model.networkAvailable = true
        model.errorMessage = nil
        model.isLoading = true
        XCTAssertTrue(model.freshness(for: .deepSeek).label.contains("更新中"))
    }
    func testRecoveryUsesOnlyConnectedStalePlatformsAndThrottles() {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek, .chatGPT, .zhipu])
        model.accountConnected = true
        model.chatGPTConnected = false
        model.zhipuConnected = false
        model.lastUpdated = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(model.recoveryPlatforms(at: now), [.deepSeek])
        model.noteRefreshAttempt(.deepSeek, at: now)
        XCTAssertTrue(model.recoveryPlatforms(at: now.addingTimeInterval(10)).isEmpty)
        XCTAssertEqual(model.recoveryPlatforms(at: now.addingTimeInterval(31)), [.deepSeek])
        model.networkAvailable = false
        XCTAssertTrue(model.automaticRefreshPlatforms().isEmpty)
    }
}

@MainActor
final class RecoveryGeometryTests: XCTestCase {
    func testScreenSwitchRecomputesSizesWithNewWidthAndHeightCap() {
        let presentation = IslandPresentation()
        let external = NotchLayout(frame: NSRect(x: 0, y: 0, width: 2560, height: 1440), topLeft: nil, topRight: nil)
        presentation.applyScreenLayout(external, screenSize: CGSize(width: 2560, height: 1440), compactLayout: .vertical, detailLayout: .columns, platformCount: 3)
        XCTAssertEqual(presentation.compactSize.width, 200)
        let wide = presentation.detailSize.width
        let internalScreen = NotchLayout(frame: NSRect(x: 0, y: 0, width: 1512, height: 982), topLeft: NSRect(x: 0, y: 950, width: 663.5, height: 32), topRight: NSRect(x: 848.5, y: 950, width: 663.5, height: 32))
        presentation.applyScreenLayout(internalScreen, screenSize: CGSize(width: 1512, height: 982), compactLayout: .vertical, detailLayout: .columns, platformCount: 3)
        XCTAssertEqual(presentation.compactSize.width, 185)
        XCTAssertLessThanOrEqual(presentation.detailSize.width, wide)
        XCTAssertLessThanOrEqual(presentation.detailSize.height, 491)
    }
    func testDisconnectedScreenInvalidatesPendingAnimation() {
        var transition = IslandWindowTransition()
        _ = transition.begin(from: .zero, to: CGRect(x: 0, y: 0, width: 400, height: 300), animated: true)
        let revision = transition.revision
        transition.invalidate()
        XCTAssertNil(transition.complete(revision: revision))
    }
}

@MainActor
final class DataStateBoundaryTests: XCTestCase {
    func testOldAndPartialDataAreClearlyMarked() {
        let model = IslandModel()
        model.accountConnected = true
        model.balance = 10
        let now = Date(timeIntervalSince1970: 1000)
        model.lastUpdated = now.addingTimeInterval(-601)
        XCTAssertEqual(model.freshness(for: .deepSeek, at: now).phase, .stale)
        XCTAssertFalse(model.freshness(for: .deepSeek, at: now).allowsAlerts)
        model.lastUpdated = now
        model.usageError = "用量更新失败"
        let partial = model.freshness(for: .deepSeek, at: now)
        XCTAssertTrue(partial.isCached)
        XCTAssertTrue(partial.label.contains("余额已更新"))
        XCTAssertTrue(partial.allowsAlerts)
    }
    func testPinnedPanelWaitsForWakeThenMovesWithoutLosingPin() {
        let presentation = IslandPresentation()
        presentation.pinned = true
        presentation.mode = .expanded
        presentation.updateVisibilityForScreenChange(hide: true, sleeping: true)
        XCTAssertEqual(presentation.mode, .hidden)
        XCTAssertTrue(presentation.pinned)
        presentation.updateVisibilityForScreenChange(hide: true, sleeping: false)
        XCTAssertEqual(presentation.mode, .expanded)
        XCTAssertTrue(presentation.pinned)
    }
}
