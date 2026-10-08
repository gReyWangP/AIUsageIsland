import XCTest
@testable import DeepSeekIsland

final class AccountProfilesTests: XCTestCase {
    func testDefaultNamesAndCustomNamesAreIndependentOfCredentialIdentity() {
        var profiles = AccountProfiles()
        XCTAssertEqual(profiles.active(for: .chatGPT).label, "ChatGPT")
        let first = profiles.add(platform: .chatGPT, label: "")
        let second = profiles.add(platform: .chatGPT, label: "  ")
        XCTAssertEqual(first.label, "ChatGPT一")
        XCTAssertEqual(second.label, "ChatGPT二")
        profiles.rename(first.id, platform: .chatGPT, label: " 工作账号 ")
        XCTAssertEqual(profiles.entries(for: .chatGPT).first { $0.id == first.id }?.label, "工作账号")
        XCTAssertEqual(profiles.active(for: .chatGPT).id, second.id)
    }
    func testLegacyAndNewAccountsUseSeparateCredentialDirectories() throws {
        var profiles = AccountProfiles()
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root.directory) }
        XCTAssertEqual(profiles.store(for: .chatGPT, root: root).directory, root.directory)
        let added = profiles.add(platform: .chatGPT, label: "工作")
        let workStore = profiles.store(for: .chatGPT, root: root)
        XCTAssertNotEqual(workStore.directory, root.directory)
        XCTAssertTrue(workStore.saveChatGPTGrant(.init(accessToken: "work", refreshToken: "work-refresh", accountID: "work-id", savedAt: .now)))
        profiles.select(AccountProfileEntry.legacyID, for: .chatGPT)
        XCTAssertNil(profiles.store(for: .chatGPT, root: root).readChatGPTGrant())
        XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "personal", refreshToken: "personal-refresh", accountID: "personal-id", savedAt: .now)))
        profiles.select(added.id, for: .chatGPT)
        XCTAssertEqual(profiles.store(for: .chatGPT, root: root).readChatGPTGrant()?.accessToken, "work")
        XCTAssertEqual(root.readChatGPTGrant()?.accessToken, "personal")
        XCTAssertEqual(profiles.active(for: .deepSeek).id, AccountProfileEntry.legacyID)
        let restored = try JSONDecoder().decode(AccountProfiles.self, from: JSONEncoder().encode(profiles))
        XCTAssertEqual(restored.active(for: .chatGPT).id, added.id)
        XCTAssertEqual(restored.entries(for: .chatGPT).count, 2)
        profiles.select(UUID(), for: .chatGPT)
        XCTAssertEqual(profiles.active(for: .chatGPT).id, added.id)
    }
}

@MainActor
final class AccountModelIsolationTests: XCTestCase {
    func testOfflineSwitchClearsOldDataPreservesBothGrantsAndRemovalInvalidatesContext() async throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        var profiles = AccountProfiles()
        let work = profiles.add(platform: .chatGPT, label: "工作")
        let workStore = profiles.store(for: .chatGPT, root: root)
        XCTAssertTrue(workStore.saveChatGPTGrant(.init(accessToken: "work", refreshToken: "work-refresh", accountID: "work-id", savedAt: .now)))
        XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "personal", refreshToken: "personal-refresh", accountID: "personal-id", savedAt: .now)))
        defaults.set(try JSONEncoder().encode(profiles), forKey: "accountProfilesV1")
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT]); model.networkAvailable = false
        model.chatGPTAccountName = "old work name"; model.chatGPTLastUpdated = .now
        let oldContext = model.chatGPTAuthorizationContext
        await model.selectAccount(AccountProfileEntry.legacyID, platform: .chatGPT)
        XCTAssertNil(model.chatGPTAccountName); XCTAssertNil(model.chatGPTLastUpdated)
        XCTAssertTrue(model.chatGPTConnected); XCTAssertNotEqual(model.chatGPTAuthorizationContext, oldContext)
        XCTAssertEqual(model.activeAccountKey(for: .chatGPT), "legacy")
        XCTAssertEqual(workStore.readChatGPTGrant()?.accessToken, "work")
        let beforeRemoval = model.chatGPTAuthorizationContext
        model.disconnect(.chatGPT)
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        XCTAssertNotEqual(model.chatGPTAuthorizationContext, beforeRemoval)
        XCTAssertNil(root.readChatGPTGrant()); XCTAssertNil(workStore.readChatGPTGrant())
        XCTAssertEqual(model.accountProfiles.entries(for: .chatGPT).count, 1)
        XCTAssertNotEqual(work.id, AccountProfileEntry.legacyID)
    }
}
