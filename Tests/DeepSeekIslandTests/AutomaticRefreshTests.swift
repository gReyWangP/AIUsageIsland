import XCTest
@testable import DeepSeekIsland

@MainActor
final class AutomaticRefreshTests: XCTestCase {
    private func model() -> IslandModel {
        let model = IslandModel()
        model.platformAccounts = PlatformAccounts(enabled: Set(UsagePlatform.allCases))
        model.accountConnected = false
        model.zhipuConnected = false
        model.chatGPTConnected = false
        return model
    }

    func testAutomaticPollingSkipsUnconnectedPlatforms() {
        XCTAssertEqual(model().automaticRefreshPlatforms(), [])
    }

    func testZhipuSessionMayBeRestoredOnceAtStartup() {
        let model = model()
        XCTAssertEqual(model.automaticRefreshPlatforms(restoringZhipuSession: true), [.zhipu])
        XCTAssertEqual(model.automaticRefreshPlatforms(), [])
    }

    func testOnlyConnectedAndEnabledPlatformsArePolled() {
        let model = model()
        model.accountConnected = true
        model.chatGPTConnected = true
        XCTAssertEqual(model.automaticRefreshPlatforms(), [.deepSeek, .chatGPT])
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        XCTAssertEqual(model.automaticRefreshPlatforms(), [.chatGPT])
    }

    func testZhipuBrowserLoginDoesNotTriggerBackgroundReloads() {
        let model = model()
        model.zhipuConnected = true
        model.zhipuSigningIn = true
        XCTAssertEqual(model.automaticRefreshPlatforms(), [])
    }

    func testChatGPTLoadingIsIncludedInGlobalRefreshState() {
        let model = model()
        model.chatGPTLoading = true
        XCTAssertTrue(model.isRefreshing)
        model.chatGPTLoading = false
        XCTAssertFalse(model.isRefreshing)
    }
}
