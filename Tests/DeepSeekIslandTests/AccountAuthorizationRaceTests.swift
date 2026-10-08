import XCTest
@testable import DeepSeekIsland

@MainActor
final class AccountAuthorizationRaceTests: XCTestCase {
    final class DeepAuth: PlatformAuthorizing {
        var pending: [CheckedContinuation<String, Error>] = []
        func signIn() async throws -> String { try await withCheckedThrowingContinuation { pending.append($0) } }
        func cancel() {}
    }
    final class GPTAuth: ChatGPTAuthorizing {
        var pending: [CheckedContinuation<ChatGPTGrant, Error>] = []
        func signIn() async throws -> ChatGPTGrant { try await withCheckedThrowingContinuation { pending.append($0) } }
        func cancel() {}
    }
    func testExpiredLegacyDeepSeekIdentityDoesNotBlockValidReauthorization() async {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        XCTAssertTrue(root.savePlatformToken("expired"))
        let auth = DeepAuth()
        let model = IslandModel(defaults: defaults, sessionRoot: root, deepSeekAuth: auth,
                                deepSeekProfileFetcher: { token in
            if token == "expired" { throw PlatformError.expired }
            return AccountProfile(displayName: "Alice", identity: "email:alice@example.com")
        })
        model.networkAvailable = false
        let login = Task { await model.signIn(.deepSeek) }
        for _ in 0..<100 where auth.pending.isEmpty { await Task.yield() }
        guard let pending = auth.pending.first else { XCTFail("login did not start"); return }
        pending.resume(returning: "valid")
        await login.value
        XCTAssertEqual(root.readPlatformToken(), "valid")
        XCTAssertNil(model.accountManagementError)
    }
    func testDeepSeekSameIdentityWithDifferentTokensIsNotAddedTwice() async {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        XCTAssertTrue(root.savePlatformToken("original"))
        let auth = DeepAuth()
        let model = IslandModel(defaults: defaults, sessionRoot: root, deepSeekAuth: auth,
                                deepSeekProfileFetcher: { _ in AccountProfile(displayName: "Alice", identity: "email:alice@example.com") })
        model.networkAvailable = false
        let login = Task { await model.addAccount(platform: .deepSeek, label: "工作") }
        for _ in 0..<100 where auth.pending.isEmpty { await Task.yield() }
        guard let pending = auth.pending.first else { XCTFail("login did not start"); return }
        pending.resume(returning: "new-token-same-user")
        await login.value
        XCTAssertEqual(root.readPlatformToken(), "original")
        XCTAssertNil(model.accountProfiles.store(for: .deepSeek, root: root).readPlatformToken())
        XCTAssertEqual(model.visibleAccounts.map(\.id), ["deepseek"])
        XCTAssertNotNil(model.accountManagementError)
    }
    func testDeepSeekUnknownIdentityCannotAddAnotherUnverifiedAccount() async {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        XCTAssertTrue(root.savePlatformToken("original"))
        let auth = DeepAuth()
        let model = IslandModel(defaults: defaults, sessionRoot: root, deepSeekAuth: auth,
                                deepSeekProfileFetcher: { _ in AccountProfile(displayName: "138****1234") })
        model.networkAvailable = false
        let login = Task { await model.addAccount(platform: .deepSeek, label: "第二个") }
        for _ in 0..<100 where auth.pending.isEmpty { await Task.yield() }
        guard let pending = auth.pending.first else { XCTFail("login did not start"); return }
        pending.resume(returning: "different-token")
        await login.value
        XCTAssertEqual(root.readPlatformToken(), "original")
        XCTAssertNil(model.accountProfiles.store(for: .deepSeek, root: root).readPlatformToken())
        XCTAssertEqual(model.visibleAccounts.map(\.id), ["deepseek"])
        XCTAssertTrue(model.accountManagementError?.contains("无法确认") == true)
    }

    func testDeepSeekDifferentStableIdentitiesAllowTwoAccounts() async {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        XCTAssertTrue(root.savePlatformToken("original"))
        let auth = DeepAuth()
        let model = IslandModel(defaults: defaults, sessionRoot: root, deepSeekAuth: auth,
                                deepSeekProfileFetcher: { token in AccountProfile(displayName: "同名", identity: token == "original" ? "user:one" : "user:two") })
        model.networkAvailable = false
        let login = Task { await model.addAccount(platform: .deepSeek, label: "第二个") }
        for _ in 0..<100 where auth.pending.isEmpty { await Task.yield() }
        guard let pending = auth.pending.first else { XCTFail("login did not start"); return }
        pending.resume(returning: "new-token")
        await login.value
        XCTAssertEqual(root.readPlatformToken(), "original")
        XCTAssertEqual(model.accountProfiles.store(for: .deepSeek, root: root).readPlatformToken(), "new-token")
        XCTAssertNil(model.accountManagementError)
        XCTAssertEqual(model.visibleAccounts.count, 2)
    }

    func testDeepSeekStableIDRejectsRotatedTokenWithMaskedContacts() async throws {
        let json = #"{"code":0,"data":{"biz_code":0,"biz_data":{"user_id":"same-user","email":"a***@example.com","id_profile":{"name":"Alice"}}}}"#
        let profile = try PlatformAccountClient.decodeProfile(Data(json.utf8))
        try await assertDeepSeekRejected(profile: profile, storedIdentity: "user:same-user", previousProfile: profile, adding: true)
    }

    func testDeepSeekContactIdentityMigratesWithoutAllowingDuplicate() async throws {
        let json = #"{"code":0,"data":{"biz_code":0,"biz_data":{"user_id":"same-user","email":"alice@example.com","id_profile":{"name":"Alice"}}}}"#
        let profile = try PlatformAccountClient.decodeProfile(Data(json.utf8))
        try await assertDeepSeekRejected(profile: profile, storedIdentity: "email:alice@example.com", previousProfile: profile, adding: true)
    }

    func testDeepSeekUnknownOldIdentityBlocksUnverifiableNewAccount() async throws {
        try await assertDeepSeekRejected(profile: .init(displayName: "Alice", identity: "user:new"), storedIdentity: nil,
                                         previousProfile: .init(displayName: "a***@example.com"), adding: true)
    }

    func testDeepSeekReauthorizationCannotReplaceKnownAccountWithUnknownIdentity() async throws {
        try await assertDeepSeekRejected(profile: .init(displayName: "a***@example.com"), storedIdentity: "user:original",
                                         previousProfile: .init(displayName: "Alice", identity: "user:original"), adding: false)
    }

    func testDeepSeekExpiredKnownIdentityCannotBeReplacedByAnotherIdentityFormat() async {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        XCTAssertTrue(root.savePlatformToken("expired"))
        let auth = DeepAuth()
        let model = IslandModel(defaults: defaults, sessionRoot: root, deepSeekAuth: auth,
                                deepSeekProfileFetcher: { token in
            if token == "expired" { throw PlatformError.expired }
            return AccountProfile(displayName: "Other", identity: "email:other@example.com")
        })
        model.networkAvailable = false
        model.accountProfiles.identify(AccountProfileEntry.legacyID, platform: .deepSeek, identity: "user:original")
        let login = Task { await model.signIn(.deepSeek) }
        for _ in 0..<100 where auth.pending.isEmpty { await Task.yield() }
        guard let pending = auth.pending.first else { XCTFail("login did not start"); return }
        pending.resume(returning: "other-token")
        await login.value
        XCTAssertEqual(root.readPlatformToken(), "expired")
        XCTAssertNotNil(model.accountManagementError)
    }

    func testChatGPTMissingIdentityCannotAddSecondAccount() async {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "original", refreshToken: "original-refresh", accountID: "original-id", savedAt: .now)))
        let auth = GPTAuth(), model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTAuth: auth)
        model.networkAvailable = false
        let login = Task { await model.addAccount(platform: .chatGPT, label: "第二个") }
        for _ in 0..<100 where auth.pending.isEmpty { await Task.yield() }
        guard let pending = auth.pending.first else { XCTFail("login did not start"); return }
        pending.resume(returning: .init(accessToken: "new", refreshToken: "new-refresh", accountID: nil, savedAt: .now))
        await login.value
        XCTAssertNil(model.accountProfiles.store(for: .chatGPT, root: root).readChatGPTGrant())
        XCTAssertNotNil(model.accountManagementError)
    }

    func testDeepSeekLegacyProfileAliasesRejectDuplicateAcrossIdentityFormats() async throws {
        try await assertDeepSeekRejected(profile: .init(displayName: "Alice", identity: "user:alice", identityAliases: ["email:alice@example.com"]),
                                         storedIdentity: nil, previousProfile: .init(displayName: "Alice", identity: "email:alice@example.com"), adding: true)
    }

    func testDeepSeekExpiredTokenDoesNotEraseSavedOwnership() async throws {
        try await assertDeepSeekRejected(profile: .init(displayName: "Bob", identity: "user:bob"),
                                         storedIdentity: "user:alice", previousProfile: .init(displayName: "Alice", identity: "user:alice"), adding: false, hasToken: false)
    }

    func testDeepSeekDuplicateIsRejectedEvenWhenOriginalTokenWasRemoved() async throws {
        try await assertDeepSeekRejected(profile: .init(displayName: "Alice", identity: "user:alice"),
                                         storedIdentity: "user:alice", previousProfile: .init(displayName: "Alice", identity: "user:alice"), adding: true, hasToken: false)
    }

    private func assertDeepSeekRejected(profile: AccountProfile, storedIdentity: String?, previousProfile: AccountProfile, adding: Bool, hasToken: Bool = true) async throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        if hasToken { XCTAssertTrue(root.savePlatformToken("original")) }
        let auth = DeepAuth()
        let model = IslandModel(defaults: defaults, sessionRoot: root, deepSeekAuth: auth,
                                deepSeekProfileFetcher: { token in token == "original" ? previousProfile : profile })
        model.networkAvailable = false
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek])
        model.accountProfiles.identify(AccountProfileEntry.legacyID, platform: .deepSeek, identity: storedIdentity)
        let login = Task {
            if adding { await model.addAccount(platform: .deepSeek, label: "第二个") }
            else { await model.signIn(.deepSeek) }
        }
        for _ in 0..<100 where auth.pending.isEmpty { await Task.yield() }
        guard let pending = auth.pending.first else { XCTFail("login did not start"); return }
        pending.resume(returning: "rotated-token")
        await login.value
        XCTAssertEqual(root.readPlatformToken(), hasToken ? "original" : nil)
        if adding { XCTAssertNil(model.accountProfiles.store(for: .deepSeek, root: root).readPlatformToken()) }
        XCTAssertNotNil(model.accountManagementError)
    }

    actor ExpiredGPTService: ChatGPTServing {
        func fetchQuota(grant: ChatGPTGrant) async throws -> ChatGPTQuota { throw ChatGPTAccountError.authorization }
        func refresh(_ grant: ChatGPTGrant) async throws -> ChatGPTGrant { throw ChatGPTAccountError.authorization }
    }

    func testChatGPTIdentitySurvivesExpiredAuthorizationAndReload() async {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "expired", refreshToken: "expired-refresh", accountID: "alice", savedAt: .now)))
        let model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTClient: ExpiredGPTService())
        model.networkAvailable = false
        await model.refreshChatGPT()
        XCTAssertNil(root.readChatGPTGrant())
        XCTAssertEqual(model.accountProfiles.entries(for: .chatGPT).first?.identity, "alice")
        let reloaded = IslandModel(defaults: defaults, sessionRoot: root)
        reloaded.networkAvailable = false
        XCTAssertEqual(reloaded.accountProfiles.entries(for: .chatGPT).first?.identity, "alice")
    }

    func testChatGPTExpiredGrantCannotReplaceSavedAccountIdentity() async {
        await assertChatGPTExpiredIdentityProtected(adding: false, returnedID: "bob")
    }

    func testChatGPTDuplicateIsRejectedAfterOriginalGrantWasRemoved() async {
        await assertChatGPTExpiredIdentityProtected(adding: true, returnedID: "alice")
    }

    private func assertChatGPTExpiredIdentityProtected(adding: Bool, returnedID: String) async {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let auth = GPTAuth(), model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTAuth: auth)
        model.networkAvailable = false
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        model.accountProfiles.identify(AccountProfileEntry.legacyID, platform: .chatGPT, identity: "alice")
        let login = Task {
            if adding { await model.addAccount(platform: .chatGPT, label: "第二个") }
            else { await model.signIn(.chatGPT) }
        }
        for _ in 0..<100 where auth.pending.isEmpty { await Task.yield() }
        guard let pending = auth.pending.first else { XCTFail("login did not start"); return }
        pending.resume(returning: .init(accessToken: "new", refreshToken: "new-refresh", accountID: returnedID, savedAt: .now))
        await login.value
        XCTAssertNil(model.accountProfiles.store(for: .chatGPT, root: root).readChatGPTGrant())
        XCTAssertEqual(model.accountProfiles.entries(for: .chatGPT).first?.identity, "alice")
        XCTAssertNotNil(model.accountManagementError)
    }

    func testDuplicateBrowserLoginPreservesOriginalGrantAndLeavesNewProfileHidden() async throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let original = ChatGPTGrant(accessToken: "personal", refreshToken: "personal-refresh", accountID: "same-user", savedAt: .now)
        XCTAssertTrue(root.saveChatGPTGrant(original))
        let auth = GPTAuth(), model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTAuth: auth)
        model.networkAvailable = false
        let login = Task { await model.addAccount(platform: .chatGPT, label: "工作") }
        for _ in 0..<100 where auth.pending.isEmpty { await Task.yield() }
        XCTAssertEqual(auth.pending.count, 1)
        guard let pending = auth.pending.first else { return }
        pending.resume(returning: .init(accessToken: "new", refreshToken: "new-refresh", accountID: "same-user", savedAt: .now))
        await login.value
        XCTAssertEqual(root.readChatGPTGrant(), original)
        XCTAssertNil(model.accountProfiles.store(for: .chatGPT, root: root).readChatGPTGrant())
        XCTAssertEqual(model.snapshots.map(\.id), ["chatgpt"])
        XCTAssertNotNil(model.accountManagementError)
        XCTAssertEqual(model.accountConnectionLabel(model.activeAccountReference(for: .chatGPT)), "重复账号 · 未添加")
    }
    func testReauthorizingSavedProfileCannotSilentlyReplaceItsIdentity() async throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let original = ChatGPTGrant(accessToken: "personal", refreshToken: "personal-refresh", accountID: "personal-id", savedAt: .now)
        XCTAssertTrue(root.saveChatGPTGrant(original))
        let auth = GPTAuth(), model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTAuth: auth)
        model.networkAvailable = false
        let login = Task { await model.signIn(.chatGPT) }
        for _ in 0..<100 where auth.pending.isEmpty { await Task.yield() }
        guard let pending = auth.pending.first else { XCTFail("login did not start"); return }
        pending.resume(returning: .init(accessToken: "wrong", refreshToken: "wrong-refresh", accountID: "different-id", savedAt: .now))
        await login.value
        XCTAssertEqual(root.readChatGPTGrant(), original)
        XCTAssertNotNil(model.chatGPTError)
    }
    func testSharedRefreshTokenIsRejectedEvenIfAccountHeaderDiffers() throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "old", refreshToken: "shared", accountID: "one", savedAt: .now)))
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        XCTAssertNotNil(model.duplicateChatGPTAccount(.init(accessToken: "new", refreshToken: "shared", accountID: "two", savedAt: .now), excluding: UUID()))
    }
    func testDuplicateChatGPTAccountUsesJWTIdentityWhenOlderGrantHasNoAccountID() throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let claims = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"same-account"}}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "old.\(claims).signature", refreshToken: "old-refresh", accountID: nil, savedAt: .now)))
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        XCTAssertNotNil(model.duplicateChatGPTAccount(.init(accessToken: "new", refreshToken: "new-refresh", accountID: "same-account", savedAt: .now), excluding: UUID()))
        XCTAssertNil(model.duplicateChatGPTAccount(.init(accessToken: "other", refreshToken: "other-refresh", accountID: "different-workspace", savedAt: .now), excluding: UUID()))
    }
    func testOldDeepSeekCancellationDoesNotClearNewLoginState() async {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let auth = DeepAuth(), model = IslandModel(defaults: defaults, sessionRoot: root, deepSeekAuth: auth)
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek])
        let first = Task { await model.signIn(.deepSeek) }
        for _ in 0..<30 where auth.pending.count < 1 { await Task.yield() }
        model.disconnect(.deepSeek); model.platformAccounts = PlatformAccounts(enabled: [.deepSeek])
        let second = Task { await model.signIn(.deepSeek) }
        for _ in 0..<30 where auth.pending.count < 2 { await Task.yield() }
        XCTAssertEqual(auth.pending.count, 2)
        auth.pending[0].resume(throwing: PlatformError.cancelled); await first.value
        XCTAssertTrue(model.isSigningIn); XCTAssertNil(model.errorMessage)
        auth.pending[1].resume(throwing: PlatformError.expired); await second.value
        XCTAssertFalse(model.isSigningIn); XCTAssertNotNil(model.errorMessage)
    }
    func testOldGPTCancellationDoesNotClearNewLoginState() async {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let auth = GPTAuth(), model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTAuth: auth)
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        let first = Task { await model.signIn(.chatGPT) }
        for _ in 0..<30 where auth.pending.count < 1 { await Task.yield() }
        model.disconnect(.chatGPT); model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        let second = Task { await model.signIn(.chatGPT) }
        for _ in 0..<30 where auth.pending.count < 2 { await Task.yield() }
        XCTAssertEqual(auth.pending.count, 2)
        auth.pending[0].resume(throwing: PlatformError.cancelled); await first.value
        XCTAssertTrue(model.chatGPTSigningIn); XCTAssertNil(model.chatGPTError)
        auth.pending[1].resume(throwing: ChatGPTAccountError.authorization); await second.value
        XCTAssertFalse(model.chatGPTSigningIn); XCTAssertNotNil(model.chatGPTError)
    }
}
