import XCTest
@testable import DeepSeekIsland

@MainActor
final class ZhipuAccountIdentityTests: XCTestCase {
    private func fixture() -> (UserDefaults, IslandModel, AccountReference, AccountReference) {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = IslandModel(defaults: defaults, sessionRoot: SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        model.networkAvailable = false; model.platformAccounts = PlatformAccounts(enabled: [.zhipu])
        let first = model.activeAccountReference(for: .zhipu)
        model.setAccountVisible(first, visible: true)
        let second = model.accountProfiles.add(platform: .zhipu, label: "另一个智谱")
        return (defaults, model, first, AccountReference(platform: .zhipu, profileID: second.id))
    }
    private func quota(_ identity: String?) -> ZhipuQuota {
        .init(kind: .tokens, level: "Max", fiveHour: .init(usedPercent: 10, usedValue: nil, limitValue: nil, nextReset: nil),
              week: .init(usedPercent: 20, usedValue: nil, limitValue: nil, nextReset: nil), accountIdentity: identity)
    }
    func testSameCustomerIdentityDoesNotConnectOrDisplayAnotherAccount() {
        let (_, model, first, second) = fixture()
        model.accountProfiles.identify(first.profileID, platform: .zhipu, identity: "customer:original")
        model.zhipuSigningIn = true; model.pendingAutoDisplay.insert(second)
        model.acceptZhipuQuota(quota("original"))
        XCTAssertFalse(model.zhipuConnected)
        XCTAssertFalse(model.visibleAccounts.contains(second))
        XCTAssertNotNil(model.accountManagementError)
    }
    func testDifferentCustomerIdentityCanConnectAndDisplay() {
        let (_, model, first, second) = fixture()
        model.accountProfiles.identify(first.profileID, platform: .zhipu, identity: "customer:original")
        model.zhipuSigningIn = true; model.pendingAutoDisplay.insert(second)
        model.acceptZhipuQuota(quota("different"))
        XCTAssertTrue(model.zhipuConnected)
        XCTAssertTrue(model.visibleAccounts.contains(second))
    }
    func testMissingIdentityWaitsForIdentityBeforeCompletingLogin() {
        let (_, model, _, second) = fixture()
        model.zhipuSigningIn = true; model.pendingAutoDisplay.insert(second)
        model.acceptZhipuQuota(quota(nil))
        XCTAssertFalse(model.zhipuConnected)
        XCTAssertTrue(model.zhipuSigningIn)
        model.acceptZhipuQuota(quota("confirmed"))
        XCTAssertTrue(model.zhipuConnected)
        XCTAssertFalse(model.zhipuSigningIn)
    }
    func testHiddenRuntimeIdentityIsPersistedOnOwningModel() {
        let (defaults, model, first, _) = fixture()
        model.accountRuntime(for: first).acceptZhipuQuota(quota("original"))
        XCTAssertEqual(model.accountProfiles.entries(for: .zhipu).first?.identity, "customer:original")
        let restored = IslandModel(defaults: defaults, sessionRoot: model.sessionRoot)
        XCTAssertEqual(restored.accountProfiles.entries(for: .zhipu).first?.identity, "customer:original")
    }
    func testEarlierSavedAccountWinsWhenIdentityArrivesAfterNewAccount() {
        let (_, model, first, second) = fixture()
        model.zhipuSigningIn = true; model.pendingAutoDisplay.insert(second)
        model.acceptZhipuQuota(quota("same"))
        XCTAssertTrue(model.zhipuConnected)
        model.accountRuntime(for: first).acceptZhipuQuota(quota("same"))
        XCTAssertFalse(model.zhipuConnected)
        XCTAssertFalse(model.visibleAccounts.contains(second))
        XCTAssertTrue(model.accountRuntime(for: first).zhipuConnected)
    }
    func testRejectedDuplicateCannotReconnectFromMissingIdentityOnReload() {
        let (_, model, first, second) = fixture()
        model.zhipuSigningIn = true; model.pendingAutoDisplay.insert(second)
        model.acceptZhipuQuota(quota("same"))
        model.accountRuntime(for: first).acceptZhipuQuota(quota("same"))
        XCTAssertFalse(model.zhipuConnected)
        model.acceptZhipuQuota(quota(nil))
        XCTAssertFalse(model.zhipuConnected)
        XCTAssertNil(model.zhipuQuota)
    }
}
