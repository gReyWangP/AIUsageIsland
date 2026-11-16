import XCTest
@testable import DeepSeekIsland

final class AntigravityQuotaTests: XCTestCase {
    func testParsesGroupsAndBothWindows() throws {
        let json = """
        {"response":{"groups":[
          {"displayName":"Gemini Models","description":"Gemini group","buckets":[
            {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.91624296,"resetTime":"2026-11-23T02:32:05Z"},
            {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":0.70772845,"resetTime":"2026-11-16T15:33:31Z"}
          ]},
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":1,"resetTime":"2026-11-23T13:36:03Z"},
            {"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1,"resetTime":"2026-11-16T18:36:03Z"}
          ]}
        ],"description":"Shared windows"}}
        """
        let quota = try AntigravityQuotaParser.parse(Data(json.utf8))
        XCTAssertEqual(quota.groups.count, 2)
        let five = try XCTUnwrap(quota.geminiGroup?.bucket(.fiveHour))
        let week = try XCTUnwrap(quota.geminiGroup?.bucket(.week))
        XCTAssertEqual(five.remainingPercent, 70.772845, accuracy: 0.001)
        XCTAssertEqual(week.remainingPercent, 91.624296, accuracy: 0.001)
        XCTAssertNotNil(five.resetAt)
        XCTAssertEqual(quota.thirdPartyGroup?.bucket(.fiveHour)?.remainingPercent, 100)
    }

    func testRejectsMissingBucketsAndErrors() {
        XCTAssertThrowsError(try AntigravityQuotaParser.parse(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? AntigravityQuotaError, .invalidResponse)
        }
        XCTAssertThrowsError(try AntigravityQuotaParser.parse(
            Data(#"{"code":"internal","message":"failed"}"#.utf8))) { error in
            XCTAssertEqual(error as? AntigravityQuotaError, .invalidResponse)
        }
    }

    func testSmallUsedPercentagesRemainPercentages() throws {
        let json = """
        {"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"five","window":"5h","percentageUsed":1},
          {"bucketId":"week","window":"weekly","percentage_used":0.5}
        ]}]}
        """
        let quota = try AntigravityQuotaParser.parse(Data(json.utf8))
        XCTAssertEqual(quota.geminiGroup?.bucket(.fiveHour)?.remainingPercent, 99)
        XCTAssertEqual(quota.geminiGroup?.bucket(.week)?.remainingPercent, 99.5)
    }

    func testLocalClientReturnsQuotaWhenAntigravityIsRunning() async throws {
        guard ProcessInfo.processInfo.environment["DSI_LIVE_ANTIGRAVITY"] == "1" else {
            throw XCTSkip("Explicit local Antigravity service probe only")
        }
        do {
            let quota = try await AntigravityLocalClient().fetchQuota()
            XCTAssertFalse(quota.groups.isEmpty)
            XCTAssertNotNil(quota.geminiGroup?.bucket(.fiveHour))
            XCTAssertNotNil(quota.geminiGroup?.bucket(.week))
        } catch AntigravityQuotaError.notRunning {
            throw XCTSkip("Antigravity is not running on this machine")
        }
    }
}

private actor ScriptedAntigravityService: AntigravityServing {
    var result: Result<AntigravityQuota, Error>

    init(result: Result<AntigravityQuota, Error>) { self.result = result }

    func setResult(_ result: Result<AntigravityQuota, Error>) { self.result = result }

    func fetchQuota() async throws -> AntigravityQuota { try result.get() }
}

private actor PausedAntigravityService: AntigravityServing {
    var pending: CheckedContinuation<AntigravityQuota, Error>?
    var isWaiting: Bool { pending != nil }

    func fetchQuota() async throws -> AntigravityQuota {
        try await withCheckedThrowingContinuation { pending = $0 }
    }

    func finish(_ result: Result<AntigravityQuota, Error>) {
        pending?.resume(with: result)
        pending = nil
    }
}

@MainActor
final class AntigravityRuntimeTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var store: SessionStore!

    override func setUp() async throws {
        try await super.setUp()
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        store = SessionStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        defaults.set(["antigravity"], forKey: "enabledUsagePlatforms")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: store.directory)
        try await super.tearDown()
    }

    private var quota: AntigravityQuota {
        .init(groups: [.init(name: "Gemini Models", description: nil, buckets: [
            .init(id: "five", displayName: "5h", window: .fiveHour,
                  remainingPercent: 12, resetAt: Date().addingTimeInterval(3_600)),
            .init(id: "week", displayName: "Weekly", window: .week,
                  remainingPercent: 8, resetAt: Date().addingTimeInterval(86_400)),
        ])])
    }

    private var grant: AntigravityCloudGrant {
        .init(accessToken: "access", refreshToken: "refresh",
              expiresAt: Date().addingTimeInterval(3_600), email: "user@example.com",
              projectID: "project", clientID: "client", clientSecret: "secret")
    }

    func testLocalConnectionFeedsBothWindowsAndResetReminders() async {
        let service = ScriptedAntigravityService(result: .success(quota))
        let model = IslandModel(defaults: defaults, sessionRoot: store, antigravityClient: service)
        let runtime = model.selectedRuntime(for: .antigravity)

        await runtime.connectAntigravity(source: .local)

        XCTAssertTrue(runtime.antigravityConnected)
        XCTAssertEqual(runtime.usageReading(for: .antigravityFiveHour), .quota(remaining: 12, window: "5 小时"))
        XCTAssertEqual(runtime.usageReading(for: .antigravityWeek), .quota(remaining: 8, window: "本周"))
        let snapshot = runtime.snapshot(for: .antigravity)
        XCTAssertEqual(snapshot.compactMetrics.count, 2)
        XCTAssertEqual(snapshot.rows.compactMap(\.reservationMetric), [.antigravityFiveHour, .antigravityWeek])
        XCTAssertTrue(snapshot.rows.filter { $0.reservationMetric != nil }.allSatisfy(\.resetFresh))
        XCTAssertEqual(runtime.resetQuotaObservations().map(\.metric), [.antigravityFiveHour, .antigravityWeek])
        XCTAssertNotNil(runtime.quotaResetDate(for: .antigravityFiveHour))
        XCTAssertNotNil(runtime.quotaResetDate(for: .antigravityWeek))
    }

    func testCloudSourceAndCredentialsRestoreAfterRestart() {
        let model = IslandModel(defaults: defaults, sessionRoot: store)
        model.selectedRuntime(for: .antigravity).setAntigravitySource(.cloud)
        XCTAssertTrue(store.saveAntigravityCloudGrant(grant))

        let restored = IslandModel(defaults: defaults, sessionRoot: store)
        let runtime = restored.selectedRuntime(for: .antigravity)
        XCTAssertEqual(runtime.antigravitySource, .cloud)
        XCTAssertTrue(runtime.antigravityConnected)
        XCTAssertEqual(runtime.automaticRefreshPlatforms(), [.antigravity])
        XCTAssertTrue(runtime.snapshot(for: .antigravity).note.contains("Google 云端"))
    }

    func testPollingWaitsForCloudCredentialsAndForLoginToFinish() {
        let model = IslandModel(defaults: defaults, sessionRoot: store)
        let runtime = model.selectedRuntime(for: .antigravity)
        XCTAssertEqual(runtime.automaticRefreshPlatforms(), [.antigravity])
        runtime.antigravitySigningIn = true
        XCTAssertEqual(runtime.automaticRefreshPlatforms(), [])
        runtime.antigravitySigningIn = false
        runtime.setAntigravitySource(.cloud)
        XCTAssertEqual(runtime.automaticRefreshPlatforms(), [])
    }

    func testReconnectingClearsAuthorizationPause() async {
        let service = ScriptedAntigravityService(result: .failure(AntigravityQuotaError.authorization))
        let model = IslandModel(defaults: defaults, sessionRoot: store, antigravityClient: service)
        let runtime = model.selectedRuntime(for: .antigravity)
        await runtime.refresh(.antigravity)
        XCTAssertFalse(runtime.refreshPolicy.canAttempt(at: Date().addingTimeInterval(3_600)))

        await service.setResult(.success(quota))
        await runtime.connectAntigravity()

        XCTAssertTrue(runtime.antigravityConnected)
        XCTAssertTrue(runtime.refreshPolicy.canAttempt())
        XCTAssertNil(runtime.antigravityRefreshFailure)
    }

    func testChangingSourceClearsAuthorizationPause() async {
        let service = ScriptedAntigravityService(result: .failure(AntigravityQuotaError.authorization))
        let model = IslandModel(defaults: defaults, sessionRoot: store, antigravityClient: service)
        let runtime = model.selectedRuntime(for: .antigravity)
        await runtime.refresh(.antigravity)
        XCTAssertFalse(runtime.refreshPolicy.canAttempt())
        runtime.setAntigravitySource(.cloud)
        XCTAssertTrue(runtime.refreshPolicy.canAttempt())
        XCTAssertNil(runtime.antigravityRefreshFailure)
    }

    func testChangedSourceDiscardsPendingLocalResponse() async {
        let service = PausedAntigravityService()
        let model = IslandModel(defaults: defaults, sessionRoot: store, antigravityClient: service)
        let runtime = model.selectedRuntime(for: .antigravity)
        let refresh = Task { await runtime.refreshAntigravity() }
        for _ in 0..<500 {
            if await service.isWaiting { break }
            await Task.yield()
        }
        let waiting = await service.isWaiting
        XCTAssertTrue(waiting)
        runtime.setAntigravitySource(.cloud)
        await service.finish(.success(quota))
        await refresh.value

        XCTAssertNil(runtime.antigravityQuota)
        XCTAssertFalse(runtime.antigravityConnected)
        XCTAssertFalse(runtime.antigravityLoading)
        XCTAssertEqual(runtime.antigravitySource, .cloud)
    }

    func testRemovingAccountDiscardsPendingConnectionError() async {
        let service = PausedAntigravityService()
        let model = IslandModel(defaults: defaults, sessionRoot: store, antigravityClient: service)
        let runtime = model.selectedRuntime(for: .antigravity)
        let connect = Task { await runtime.connectAntigravity() }
        for _ in 0..<500 {
            if await service.isWaiting { break }
            await Task.yield()
        }
        let waiting = await service.isWaiting
        XCTAssertTrue(waiting)
        model.disconnect(.antigravity)
        await service.finish(.failure(AntigravityQuotaError.authorization))
        await connect.value

        XCTAssertNil(runtime.antigravityError)
        XCTAssertNil(model.accountManagementError)
        XCTAssertFalse(runtime.antigravitySigningIn)
        XCTAssertTrue(model.savedAccounts.isEmpty)
    }

    func testCancellationDoesNotBecomeRefreshFailure() async {
        let service = ScriptedAntigravityService(result: .failure(URLError(.cancelled)))
        let model = IslandModel(defaults: defaults, sessionRoot: store, antigravityClient: service)
        let runtime = model.selectedRuntime(for: .antigravity)
        await runtime.refreshAntigravity()
        XCTAssertNil(runtime.antigravityRefreshFailure)
        XCTAssertNil(runtime.antigravityError)
    }

    func testRemovalClearsCloudCredentialsAndSourcePreference() {
        let model = IslandModel(defaults: defaults, sessionRoot: store)
        let runtime = model.selectedRuntime(for: .antigravity)
        runtime.setAntigravitySource(.cloud)
        XCTAssertTrue(store.saveAntigravityCloudGrant(grant))
        let sourceKey = "antigravitySource-" + runtime.account.profileID.uuidString
        model.disconnect(.antigravity)
        XCTAssertNil(store.readAntigravityCloudGrant())
        XCTAssertNil(defaults.string(forKey: sourceKey))
        XCTAssertTrue(model.savedAccounts.isEmpty)
    }

    func testFailedCredentialRemovalKeepsAccount() throws {
        let model = IslandModel(defaults: defaults, sessionRoot: store)
        let account = model.activeAccountReference(for: .antigravity)
        try FileManager.default.createDirectory(at: store.directory.appendingPathComponent("antigravity-cloud-grant"),
                                                withIntermediateDirectories: true)
        model.disconnect(.antigravity)
        XCTAssertTrue(model.savedAccounts.contains(account))
        XCTAssertNotNil(model.accountManagementError)
    }
}
