import XCTest
@testable import DeepSeekIsland

private actor RotatingQuotaService: ChatGPTServing {
    private var pending: CheckedContinuation<ChatGPTGrant, Error>?
    private var original: ChatGPTGrant?
    private(set) var rotations = 0
    var isWaiting: Bool { pending != nil }
    func fetchQuota(grant: ChatGPTGrant) async throws -> ChatGPTQuota {
        if grant.accessToken == "expired-left" { throw ChatGPTAccountError.authorization }
        return ChatGPTQuota(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: grant.accountID == "left" ? 61 : 26, resetAt: .now.addingTimeInterval(3600)),
                            weekly: nil, email: nil, accountID: grant.accountID, limitReached: false)
    }
    func refresh(_ grant: ChatGPTGrant) async throws -> ChatGPTGrant {
        rotations += 1; original = grant
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func complete() {
        guard var grant = original else { return }
        grant.accessToken = "rotated-left"; grant.refreshToken = "rotated-refresh-left"
        pending?.resume(returning: grant); pending = nil
    }
}

@MainActor
final class AccountRefreshIsolationTests: XCTestCase {
    func testRotationIsSerializedAndHidingCannotDiscardRotatedGrant() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        var profiles = AccountProfiles()
        let left = profiles.add(platform: .chatGPT, label: "工作")
        let leftStore = profiles.store(for: .chatGPT, root: root)
        XCTAssertTrue(leftStore.saveChatGPTGrant(.init(accessToken: "expired-left", refreshToken: "refresh-left", accountID: "left", savedAt: .now)))
        profiles.select(AccountProfileEntry.legacyID, for: .chatGPT)
        let originalRight = ChatGPTGrant(accessToken: "valid-right", refreshToken: "refresh-right", accountID: "right", savedAt: .now)
        XCTAssertTrue(root.saveChatGPTGrant(originalRight))
        defaults.set(try JSONEncoder().encode(profiles), forKey: "accountProfilesV1")
        let leftRef = AccountReference(platform: .chatGPT, profileID: left.id)
        let rightRef = AccountReference(platform: .chatGPT, profileID: AccountProfileEntry.legacyID)
        defaults.set(try JSONEncoder().encode(AccountDisplaySelection(accounts: [leftRef, rightRef])), forKey: "displayedAccountsV1")
        let service = RotatingQuotaService()
        let model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTClient: service)
        let refresh = Task { await model.refreshAccount(id: leftRef.id) }
        for _ in 0..<500 {
            if await service.isWaiting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let waiting = await service.isWaiting
        XCTAssertTrue(waiting)
        await model.refreshAccount(id: leftRef.id)
        await model.refreshAccount(id: rightRef.id)
        XCTAssertEqual(model.chatGPTQuota?.session?.usedPercent, 26)
        await model.selectAccount(left.id, platform: .chatGPT)
        XCTAssertEqual(model.activeAccountKey(for: .chatGPT), "legacy", "Cannot transfer ownership during a token rotation")
        model.setAccountVisible(leftRef, visible: false)
        await service.complete(); await refresh.value
        XCTAssertEqual(leftStore.readChatGPTGrant()?.refreshToken, "rotated-refresh-left")
        XCTAssertEqual(root.readChatGPTGrant(), originalRight)
        let rotations = await service.rotations
        XCTAssertEqual(rotations, 1)
        model.setAccountVisible(leftRef, visible: true)
        XCTAssertEqual(model.snapshots.map(\.heroValue), ["26%", "61%"])
    }

    func testRemovingOneAccountLeavesOtherGrantAndCardAvailable() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        var profiles = AccountProfiles()
        let work = profiles.add(platform: .chatGPT, label: "工作")
        let workStore = profiles.store(for: .chatGPT, root: root)
        XCTAssertTrue(workStore.saveChatGPTGrant(.init(accessToken: "work", refreshToken: "work-refresh", accountID: "work-id", savedAt: .now)))
        XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "personal", refreshToken: "personal-refresh", accountID: "personal-id", savedAt: .now)))
        defaults.set(try JSONEncoder().encode(profiles), forKey: "accountProfilesV1")
        let workRef = AccountReference(platform: .chatGPT, profileID: work.id)
        let personal = AccountReference(platform: .chatGPT, profileID: AccountProfileEntry.legacyID)
        defaults.set(try JSONEncoder().encode(AccountDisplaySelection(accounts: [workRef, personal])), forKey: "displayedAccountsV1")
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false
        await model.removeAccount(workRef)
        XCTAssertNil(workStore.readChatGPTGrant())
        XCTAssertEqual(root.readChatGPTGrant()?.refreshToken, "personal-refresh")
        XCTAssertEqual(model.snapshots.map(\.id), ["chatgpt"])
        XCTAssertTrue(model.platformAccounts.enabled.contains(.chatGPT))
    }
}
