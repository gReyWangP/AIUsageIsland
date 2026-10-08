import XCTest
@testable import DeepSeekIsland

@MainActor
final class MultiAccountDisplayTests: XCTestCase {
    func testObsoleteSelectionReferencesDoNotConsumeVisibleSlots() throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        let obsolete = (0..<4).map { _ in AccountReference(platform: .chatGPT, profileID: UUID()) }
        defaults.set(try JSONEncoder().encode(AccountDisplaySelection(accounts: obsolete)), forKey: "displayedAccountsV1")
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false
        let valid = model.activeAccountReference(for: .chatGPT)
        model.setAccountVisible(valid, visible: true)
        XCTAssertEqual(model.visibleAccounts, [valid])
        XCTAssertNil(model.accountManagementError)
    }
    func testVisibleSelectionCapOrderPersistenceAndHidingPreserveCredentials() throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        var profiles = AccountProfiles()
        var references = [AccountReference(platform: .chatGPT, profileID: AccountProfileEntry.legacyID)]
        for name in ["工作", "测试", "团队", "备用"] {
            let entry = profiles.add(platform: .chatGPT, label: name)
            references.append(AccountReference(platform: .chatGPT, profileID: entry.id))
        }
        defaults.set(try JSONEncoder().encode(profiles), forKey: "accountProfilesV1")
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        defaults.set(try JSONEncoder().encode(AccountDisplaySelection()), forKey: "displayedAccountsV1")
        XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "personal", refreshToken: "personal-refresh", accountID: "personal-id", savedAt: .now)))
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false
        for reference in references { model.setAccountVisible(reference, visible: true) }
        XCTAssertEqual(model.visibleAccounts, Array(references.prefix(4)))
        XCTAssertNotNil(model.accountManagementError)
        model.setAccountVisible(references[0], visible: false)
        model.setAccountVisible(references[4], visible: true)
        model.moveAccount(references[4], by: -1)
        XCTAssertEqual(model.visibleAccounts, [references[1], references[2], references[4], references[3]])
        XCTAssertEqual(root.readChatGPTGrant()?.refreshToken, "personal-refresh")
        let restored = IslandModel(defaults: defaults, sessionRoot: root)
        XCTAssertEqual(restored.visibleAccounts, [references[1], references[2], references[4], references[3]])
    }

    func testChoosingMenuAccountRetainsItsOwnCachedQuotaAndDoesNotAlterDisplayOrder() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        var profiles = AccountProfiles()
        let work = profiles.add(platform: .chatGPT, label: "工作")
        profiles.select(AccountProfileEntry.legacyID, for: .chatGPT)
        defaults.set(try JSONEncoder().encode(profiles), forKey: "accountProfilesV1")
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        let reference = AccountReference(platform: .chatGPT, profileID: work.id)
        let legacy = AccountReference(platform: .chatGPT, profileID: AccountProfileEntry.legacyID)
        defaults.set(try JSONEncoder().encode(AccountDisplaySelection(accounts: [reference, legacy])), forKey: "displayedAccountsV1")
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false
        let worker = model.accountRuntime(for: reference)
        worker.chatGPTQuota = try ChatGPTQuotaParser.parse(Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":61,"limit_window_seconds":18000,"reset_at":1791275163}}}"#.utf8))
        worker.chatGPTLastUpdated = .now
        worker.chatGPTConnected = true
        await model.selectAccount(work.id, platform: .chatGPT)
        XCTAssertEqual(model.snapshots[0].heroValue, "61%")
        XCTAssertEqual(model.visibleAccounts, [reference, legacy])
    }
    func testSavedSelectionCanShowTwoAccountsOfSamePlatformInChosenOrder() throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        var profiles = AccountProfiles()
        let work = profiles.add(platform: .chatGPT, label: "工作 ChatGPT")
        profiles.select(AccountProfileEntry.legacyID, for: .chatGPT)
        defaults.set(try JSONEncoder().encode(profiles), forKey: "accountProfilesV1")
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        let selection: [String: Any] = ["accounts": [
            ["platform": "chatgpt", "profileID": work.id.uuidString],
            ["platform": "chatgpt", "profileID": AccountProfileEntry.legacyID.uuidString]
        ]]
        defaults.set(try JSONSerialization.data(withJSONObject: selection), forKey: "displayedAccountsV1")
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false
        XCTAssertEqual(model.snapshots.map(\.title), ["工作 ChatGPT", "ChatGPT"])
        XCTAssertEqual(Set(model.snapshots.map(\.id)).count, 2)
        model.renameAccount(work.id, platform: .chatGPT, label: "公司")
        XCTAssertEqual(model.snapshots.map(\.title), ["公司", "ChatGPT"])
    }

    func testEmptySavedSelectionDoesNotReenableCards() throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["chatgpt"], forKey: "enabledUsagePlatforms")
        defaults.set(Data(#"{"accounts":[]}"#.utf8), forKey: "displayedAccountsV1")
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        XCTAssertTrue(model.snapshots.isEmpty)
        XCTAssertTrue(model.platformAccounts.enabled.contains(.chatGPT))
    }
}
