import XCTest
@testable import DeepSeekIsland

private actor ScriptedChatGPTService: ChatGPTServing {
    var replies: [Result<ChatGPTQuota, Error>]
    let rotation: Result<ChatGPTGrant, Error>
    private(set) var fetchedTokens: [String] = []
    private(set) var rotations = 0

    init(replies: [Result<ChatGPTQuota, Error>], rotation: Result<ChatGPTGrant, Error>) {
        self.replies = replies; self.rotation = rotation
    }
    func fetchQuota(grant: ChatGPTGrant) async throws -> ChatGPTQuota {
        fetchedTokens.append(grant.accessToken)
        return try replies.removeFirst().get()
    }
    func refresh(_ grant: ChatGPTGrant) async throws -> ChatGPTGrant {
        rotations += 1
        return try rotation.get()
    }
}

private actor HeldChatGPTRotation: ChatGPTServing {
    enum Hold: Sendable { case rotation, retry }
    let hold: Hold
    init(hold: Hold = .rotation) { self.hold = hold }
    private var quotaContinuation: CheckedContinuation<ChatGPTQuota, Error>?
    private var continuation: CheckedContinuation<ChatGPTGrant, Error>?
    private(set) var fetches = 0
    var isWaiting: Bool { continuation != nil || quotaContinuation != nil }
    func fetchQuota(grant: ChatGPTGrant) async throws -> ChatGPTQuota {
        fetches += 1
        if hold == .retry, fetches > 1 {
            return try await withCheckedThrowingContinuation { quotaContinuation = $0 }
        }
        throw ChatGPTAccountError.authorization
    }
    func refresh(_ grant: ChatGPTGrant) async throws -> ChatGPTGrant {
        if hold == .retry {
            return .init(accessToken: "new", refreshToken: "new-refresh", accountID: grant.accountID, savedAt: .now)
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func fail(_ error: Error) {
        continuation?.resume(throwing: error); continuation = nil
        quotaContinuation?.resume(throwing: error); quotaContinuation = nil
    }
    func finish(_ grant: ChatGPTGrant) {
        continuation?.resume(returning: grant)
        continuation = nil
    }
}

@MainActor
final class ChatGPTRefreshAdapterTests: XCTestCase {
    private var grant: ChatGPTGrant {
        .init(accessToken: "old", refreshToken: "old-refresh", accountID: "test", savedAt: .now)
    }
    private var quota: ChatGPTQuota {
        .init(planType: "pro", session: nil,
              weekly: .init(windowSeconds: 604800, usedPercent: 42, resetAt: nil),
              email: nil, accountID: "test", limitReached: false)
    }
    private func fixture(service: any ChatGPTServing) throws -> (IslandModel, AccountRuntime, SessionStore) {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let store = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: store.directory)
        }
        XCTAssertTrue(store.saveChatGPTGrant(grant))
        let model = IslandModel(defaults: defaults, sessionRoot: store, chatGPTClient: service)
        model.platformAccounts = .init(enabled: [.chatGPT])
        let runtime = model.selectedRuntime(for: .chatGPT)
        runtime.chatGPTQuota = quota
        runtime.chatGPTLastUpdated = .now
        return (model, runtime, store)
    }

    func testCancellationPreservesCachedReadingAndDoesNotReportFailure() async throws {
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            let service = ScriptedChatGPTService(replies: [.failure(error)], rotation: .failure(error))
            let (model, runtime, store) = try fixture(service: service)
            defer { withExtendedLifetime(model) {} }
            let updated = runtime.chatGPTLastUpdated
            await runtime.refreshChatGPT()
            XCTAssertNil(runtime.chatGPTUsageError)
            XCTAssertNil(runtime.chatGPTError)
            XCTAssertEqual(runtime.chatGPTLastUpdated, updated)
            XCTAssertEqual(runtime.chatGPTQuota?.weekly?.usedPercent, 42)
            XCTAssertNotNil(store.readChatGPTGrant())
            XCTAssertFalse(runtime.chatGPTLoading)
        }
    }

    func testServerFailureKeepsGrantAndCachedDataButBlocksAlerts() async throws {
        let service = ScriptedChatGPTService(replies: [.failure(ChatGPTAccountError.server(503))], rotation: .failure(CancellationError()))
        let (model, runtime, store) = try fixture(service: service)
        defer { withExtendedLifetime(model) {} }
        await runtime.refreshChatGPT()
        XCTAssertNotNil(store.readChatGPTGrant())
        XCTAssertEqual(runtime.chatGPTQuota?.weekly?.usedPercent, 42)
        XCTAssertFalse(runtime.freshness(for: .chatGPT).allowsAlerts)
        let rotations = await service.rotations
        XCTAssertEqual(rotations, 0)
    }

    func testRejectedRotationClearsOnlyExpiredAuthorization() async throws {
        let service = ScriptedChatGPTService(replies: [.failure(ChatGPTAccountError.authorization)], rotation: .failure(ChatGPTAccountError.authorization))
        let (model, runtime, store) = try fixture(service: service)
        defer { withExtendedLifetime(model) {} }
        await runtime.refreshChatGPT()
        XCTAssertNil(store.readChatGPTGrant())
        XCTAssertFalse(runtime.chatGPTConnected)
        XCTAssertNil(runtime.chatGPTQuota)
        XCTAssertNotNil(runtime.chatGPTError)
        let rotations = await service.rotations
        XCTAssertEqual(rotations, 1)
    }
    func testFailureClassificationDoesNotExposeUnderlyingDetails() {
        let cases: [(Error, UsageRefreshFailure)] = [
            (CancellationError(), .cancelled), (URLError(.cancelled), .cancelled),
            (URLError(.timedOut), .transport(URLError.timedOut.rawValue)),
            (ChatGPTAccountError.authorization, .authorization),
            (ChatGPTQuotaError.authorization, .authorization),
            (ChatGPTAccountError.server(429), .http(429)),
            (ChatGPTAccountError.invalidResponse, .invalidResponse),
            (ChatGPTQuotaError.noQuota, .noQuota),
            (ChatGPTQuotaError.invalidResponse, .invalidResponse),
            (NSError(domain: "secret-token", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret-token"]), .unknown)
        ]
        for (error, expected) in cases {
            let actual = ChatGPTUsageAdapter.failure(for: error)
            XCTAssertEqual(actual, expected)
            XCTAssertFalse(actual.message(for: .chatGPT).contains("secret-token"))
        }
    }

    func testRotationPersistsBeforeRetryAndDoesNotRetrySecondAuthorizationFailure() async throws {
        let rotated = ChatGPTGrant(accessToken: "new", refreshToken: "new-refresh", accountID: "test", savedAt: .now)
        let service = ScriptedChatGPTService(replies: [.failure(ChatGPTAccountError.authorization), .failure(ChatGPTAccountError.authorization)], rotation: .success(rotated))
        var saved: ChatGPTGrant?
        do {
            _ = try await ChatGPTUsageAdapter(service: service).fetch(grant: grant,
                persistRotatedGrant: { saved = $0; return true }, isCurrent: { true })
            XCTFail("Second authorization failure should propagate")
        } catch { XCTAssertEqual(error as? UsageRefreshFailure, .authorization) }
        XCTAssertEqual(saved, rotated)
        let tokens = await service.fetchedTokens, rotations = await service.rotations
        XCTAssertEqual(tokens, ["old", "new"])
        XCTAssertEqual(rotations, 1)
    }

    func testFailedPersistenceStopsQuotaRetryWithStorageFailure() async throws {
        let service = ScriptedChatGPTService(replies: [.failure(ChatGPTAccountError.authorization)], rotation: .success(grant))
        do {
            _ = try await ChatGPTUsageAdapter(service: service).fetch(grant: grant,
                persistRotatedGrant: { _ in false }, isCurrent: { true })
            XCTFail("Cannot retry with unsaved credentials")
        } catch { XCTAssertEqual(error as? UsageRefreshFailure, .credentialPersistence) }
        let tokens = await service.fetchedTokens
        XCTAssertEqual(tokens, ["old"])
    }

    func testSuccessClearsStructuredFailure() async throws {
        let service = ScriptedChatGPTService(replies: [.failure(ChatGPTAccountError.server(503)), .success(quota)], rotation: .failure(CancellationError()))
        let (model, runtime, _) = try fixture(service: service)
        defer { withExtendedLifetime(model) {} }
        await runtime.refreshChatGPT()
        XCTAssertEqual(runtime.chatGPTRefreshFailure, .http(503))
        await runtime.refreshChatGPT()
        XCTAssertNil(runtime.chatGPTRefreshFailure)
        XCTAssertNil(runtime.chatGPTUsageError)
        XCTAssertTrue(runtime.freshness(for: .chatGPT).allowsAlerts)
    }

    private func waitForRotation(_ service: HeldChatGPTRotation) async throws {
        for _ in 0..<500 {
            if await service.isWaiting { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Rotation did not start")
        throw CancellationError()
    }

    func testCancellationAfterRotationStartsStillSavesReplacementBeforeStopping() async throws {
        let service = HeldChatGPTRotation()
        let (model, runtime, store) = try fixture(service: service)
        defer { withExtendedLifetime(model) {} }
        let task = Task { await runtime.refreshChatGPT() }
        try await waitForRotation(service)
        task.cancel()
        let rotated = ChatGPTGrant(accessToken: "new", refreshToken: "replacement", accountID: "test", savedAt: .now)
        await service.finish(rotated)
        await task.value
        XCTAssertEqual(store.readChatGPTGrant(), rotated)
        XCTAssertNil(runtime.chatGPTRefreshFailure)
        XCTAssertNil(runtime.chatGPTUsageError)
        XCTAssertEqual(runtime.chatGPTQuota?.weekly?.usedPercent, 42)
        XCTAssertFalse(runtime.chatGPTLoading)
        let fetches = await service.fetches
        XCTAssertEqual(fetches, 1)
    }

    func testDisposedRuntimeCannotPersistLateRotationOrApplyFailure() async throws {
        let service = HeldChatGPTRotation()
        let (model, runtime, store) = try fixture(service: service)
        defer { withExtendedLifetime(model) {} }
        let original = store.readChatGPTGrant()
        let task = Task { await runtime.refreshChatGPT() }
        try await waitForRotation(service)
        runtime.disposeAccountRuntime()
        await service.finish(.init(accessToken: "late", refreshToken: "late", accountID: "test", savedAt: .now))
        await task.value
        XCTAssertEqual(store.readChatGPTGrant(), original)
        XCTAssertNil(runtime.chatGPTRefreshFailure)
        XCTAssertNil(runtime.chatGPTQuota)
        XCTAssertFalse(runtime.chatGPTConnected)
        let fetches = await service.fetches
        XCTAssertEqual(fetches, 1)
    }

    func testCancelledRetryDoesNotErasePreviousFailure() async throws {
        let service = ScriptedChatGPTService(replies: [.failure(ChatGPTAccountError.server(503)), .failure(CancellationError())], rotation: .failure(CancellationError()))
        let (model, runtime, _) = try fixture(service: service)
        defer { withExtendedLifetime(model) {} }
        await runtime.refreshChatGPT()
        let message = runtime.chatGPTUsageError
        await runtime.refreshChatGPT()
        XCTAssertEqual(runtime.chatGPTRefreshFailure, .http(503))
        XCTAssertEqual(runtime.chatGPTUsageError, message)
        runtime.disposeAccountRuntime()
        XCTAssertNil(runtime.chatGPTRefreshFailure)
    }

    func testCancellationTakesPrecedenceOverLateServiceFailures() async throws {
        for hold in [HeldChatGPTRotation.Hold.rotation, .retry] {
            for error: Error in [ChatGPTAccountError.authorization, ChatGPTAccountError.server(503)] {
                let service = HeldChatGPTRotation(hold: hold)
                let (model, runtime, store) = try fixture(service: service)
                defer { withExtendedLifetime(model) {} }
                let task = Task { await runtime.refreshChatGPT() }
                try await waitForRotation(service)
                task.cancel()
                await service.fail(error)
                await task.value
                XCTAssertEqual(store.readChatGPTGrant()?.accessToken, hold == .retry ? "new" : "old")
                XCTAssertTrue(runtime.chatGPTConnected)
                XCTAssertEqual(runtime.chatGPTQuota?.weekly?.usedPercent, 42)
                XCTAssertNil(runtime.chatGPTRefreshFailure)
                XCTAssertNil(runtime.chatGPTError)
                XCTAssertNil(runtime.chatGPTUsageError)
                XCTAssertFalse(runtime.chatGPTLoading)
            }
        }
    }

    func testCancellationCannotHideFailureToSaveAlreadyRotatedCredentials() async throws {
        let service = ScriptedChatGPTService(replies: [.failure(ChatGPTAccountError.authorization)], rotation: .success(grant))
        let task = Task {
            try await ChatGPTUsageAdapter(service: service).fetch(grant: grant,
                persistRotatedGrant: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return false
                }, isCurrent: { true })
        }
        do {
            _ = try await task.value
            XCTFail("Failure to save a consumed rotation must remain visible")
        } catch { XCTAssertEqual(error as? UsageRefreshFailure, .credentialPersistence) }
    }

}
