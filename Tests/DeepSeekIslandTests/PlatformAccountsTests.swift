import XCTest
@testable import DeepSeekIsland

final class PlatformAccountsTests: XCTestCase {
    func testMigrationKeepsExistingDeepSeekGrantAndSavedZhipu() {
        let accounts = PlatformAccounts.restore(stored: nil, legacy: "zhipu", hasDeepSeekGrant: true)
        XCTAssertEqual(accounts.enabled, [.deepSeek, .zhipu])
    }

    func testRemovingOnePlatformKeepsTheOther() {
        let accounts = PlatformAccounts(enabled: [.deepSeek, .zhipu])
        XCTAssertEqual(accounts.removing(.zhipu).enabled, [.deepSeek])
        XCTAssertEqual(accounts.removing(.deepSeek).enabled, [.zhipu])
    }

    func testSavedPlatformsRestoreAsEnabledEvenWhenGrantIsMissing() {
        let accounts = PlatformAccounts.restore(stored: ["deepseek", "zhipu"], legacy: nil,
                                                hasDeepSeekGrant: false)
        XCTAssertEqual(accounts.enabled, [.deepSeek, .zhipu])
    }

    func testDetailTitleUsesPlatformNameForOneAndSummaryForTwo() {
        XCTAssertEqual(PlatformAccounts(enabled: []).detailTitle, "选择平台")
        XCTAssertEqual(PlatformAccounts(enabled: [.deepSeek]).detailTitle, "DeepSeek")
        XCTAssertEqual(PlatformAccounts(enabled: [.zhipu]).detailTitle, "智谱 CodingPlan")
        XCTAssertEqual(PlatformAccounts(enabled: [.deepSeek, .zhipu]).detailTitle, "用量统计")
    }
}
