import XCTest
@testable import DeepSeekIsland

final class OpenCodeGoQuotaTests: XCTestCase {
    func testParsesPercentStatusAndReset() throws {
        let json = """
        {"usage":{
          "rolling":{"status":"ok","percent":38,"resetsAt":"2026-11-06T12:00:00.000Z"},
          "weekly":{"status":"ok","percent":59,"resetsAt":"2026-11-10T00:00:00Z"},
          "monthly":{"status":"rate-limited","percent":0,"resetsAt":"2026-12-01T00:00:00Z"}
        }}
        """
        let quota = try OpenCodeGoQuotaParser.parse(Data(json.utf8))
        XCTAssertEqual(quota.rolling?.usedPercent, 38)
        XCTAssertEqual(quota.weekly?.usedPercent, 59)
        XCTAssertEqual(quota.monthly?.usedPercent, 100)
        XCTAssertNotNil(quota.rolling?.resetAt)
        XCTAssertEqual(quota.rolling?.remainingPercent, 62)
    }

    func testParsesLegacyUsedAndLimitValues() throws {
        let json = """
        {"rolling":{"used":3,"limit":12,"resetsAt":1762430400},
         "weekly":{"used":0,"limit":0,"resetsAt":null},
         "monthly":{"used":100,"limit":100,"resetsAt":null}}
        """
        let quota = try OpenCodeGoQuotaParser.parse(Data(json.utf8))
        XCTAssertEqual(quota.rolling?.usedPercent, 25)
        XCTAssertNil(quota.weekly)
        XCTAssertEqual(quota.monthly?.usedPercent, 100)
    }

    func testRejectsEmptyAndErrorPayloads() {
        XCTAssertThrowsError(try OpenCodeGoQuotaParser.parse(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? OpenCodeGoQuotaError, .noQuota)
        }
        XCTAssertThrowsError(try OpenCodeGoQuotaParser.parse(
            Data(#"{"type":"error","error":{"type":"AuthError"}}"#.utf8))) { error in
            XCTAssertEqual(error as? OpenCodeGoQuotaError, .authorization)
        }
    }
}

private actor ScriptedOpenCodeGoService: OpenCodeGoServing {
    let result: Result<OpenCodeGoQuota, Error>
    private(set) var keys: [String] = []

    init(result: Result<OpenCodeGoQuota, Error>) {
        self.result = result
    }

    func fetchQuota(apiKey: String) async throws -> OpenCodeGoQuota {
        keys.append(apiKey)
        return try result.get()
    }
}

@MainActor
final class OpenCodeGoRuntimeTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var store: SessionStore!

    override func setUp() {
        super.setUp()
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        store = SessionStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: store.directory)
        super.tearDown()
    }

    private var quota: OpenCodeGoQuota {
        OpenCodeGoQuota(
            rolling: .init(usedPercent: 38, resetAt: Date().addingTimeInterval(3_600), status: "ok"),
            weekly: .init(usedPercent: 59, resetAt: Date().addingTimeInterval(86_400), status: "ok"),
            monthly: .init(usedPercent: 22, resetAt: Date().addingTimeInterval(2_592_000), status: "ok")
        )
    }

    func testConnectStoresKeyAndBuildsThreeWindows() async throws {
        let service = ScriptedOpenCodeGoService(result: .success(quota))
        let model = IslandModel(defaults: defaults, sessionRoot: store, openCodeGoClient: service)
        model.platformAccounts = .init(enabled: [.openCodeGo])
        let runtime = model.selectedRuntime(for: .openCodeGo)

        await runtime.connectOpenCodeGo(apiKey: "  sk-go-test  ")

        XCTAssertTrue(runtime.openCodeGoConnected)
        XCTAssertEqual(store.readOpenCodeGoKey(), "sk-go-test")
        XCTAssertEqual(runtime.openCodeGoQuota?.rolling?.usedPercent, 38)
        XCTAssertEqual(runtime.usageReading(for: .openCodeGoFiveHour), .quota(remaining: 62, window: "5 小时"))
        XCTAssertEqual(runtime.usageReading(for: .openCodeGoWeek), .quota(remaining: 41, window: "本周"))
        XCTAssertEqual(runtime.usageReading(for: .openCodeGoMonth), .quota(remaining: 78, window: "本月"))
        XCTAssertEqual(runtime.snapshot(for: .openCodeGo).compactMetrics.count, 3)
        let keys = await service.keys
        XCTAssertEqual(keys, ["sk-go-test"])
    }

    func testInvalidKeyIsNotPersistedAndLeavesAccountDisconnected() async throws {
        let service = ScriptedOpenCodeGoService(result: .failure(OpenCodeGoAccountError.authorization))
        let model = IslandModel(defaults: defaults, sessionRoot: store, openCodeGoClient: service)
        model.platformAccounts = .init(enabled: [.openCodeGo])
        let runtime = model.selectedRuntime(for: .openCodeGo)

        await runtime.connectOpenCodeGo(apiKey: "bad-key")

        XCTAssertFalse(runtime.openCodeGoConnected)
        XCTAssertNil(store.readOpenCodeGoKey())
        XCTAssertNotNil(runtime.openCodeGoError)
        XCTAssertEqual(runtime.openCodeGoRefreshFailure, .authorization)
    }

    func testAddingOpenCodeGoAccountConnectsAndMakesItVisible() async throws {
        let service = ScriptedOpenCodeGoService(result: .success(quota))
        let model = IslandModel(defaults: defaults, sessionRoot: store, openCodeGoClient: service)
        model.networkAvailable = false

        await model.addOpenCodeGoAccount(label: "Go 主账号", apiKey: "sk-go-main")

        let account = model.activeAccountReference(for: .openCodeGo)
        XCTAssertTrue(model.savedAccounts.contains(account))
        XCTAssertTrue(model.visibleAccounts.contains(account))
        XCTAssertTrue(model.accountRuntime(for: account).openCodeGoConnected)
        XCTAssertTrue(model.snapshots.contains { $0.platform == .openCodeGo })
    }
}

final class OpenCodeGoSessionStoreTests: XCTestCase {
    func testKeyRoundTripAndValidation() throws {
        let store = SessionStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        defer { try? FileManager.default.removeItem(at: store.directory) }

        XCTAssertTrue(store.saveOpenCodeGoKey("  sk-go-test  \n"))
        XCTAssertEqual(store.readOpenCodeGoKey(), "sk-go-test")
        XCTAssertTrue(store.deleteOpenCodeGoKey())
        XCTAssertNil(store.readOpenCodeGoKey())
        XCTAssertFalse(store.saveOpenCodeGoKey(" \n"))
        XCTAssertFalse(store.saveOpenCodeGoKey("line1\nline2"))
    }
}
