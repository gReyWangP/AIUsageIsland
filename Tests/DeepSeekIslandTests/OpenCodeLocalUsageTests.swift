import SQLite3
import XCTest
@testable import DeepSeekIsland

final class OpenCodeLocalUsageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAggregatesOpenCodeGoTokensAndIgnoresOtherRecords() throws {
        let url = directory.appendingPathComponent("opencode.db")
        let now = UsageAnalysisMath.date("2026-11-18")!.addingTimeInterval(12 * 3_600)
        let today = now.addingTimeInterval(-2 * 3_600)
        let yesterday = now.addingTimeInterval(-26 * 3_600)
        try database(url, statements: [
            """
            CREATE TABLE session_message (
              id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL,
              seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL,
              data text NOT NULL)
            """,
            messageRow(now: today, json: """
            {"model":{"providerID":"opencode-go","id":"m"},"tokens":{"input":100,"output":20,"cache":{"read":1000,"write":50},"reasoning":30}}
            """),
            messageRow(now: today, json: """
            {"model":{"providerID":"opencode-go","id":"m"},"tokens":{"input":10,"output":5,"cache":{"read":0,"write":0},"reasoning":0}}
            """),
            messageRow(now: yesterday, json: """
            {"model":{"providerID":"opencode-go","id":"m"},"tokens":{"input":7,"output":3,"cache":{"read":0,"write":0},"reasoning":0}}
            """),
            messageRow(now: today, json: """
            {"model":{"providerID":"zhipu","id":"m"},"tokens":{"input":999,"output":999}}
            """),
            messageRow(now: today, type: "user", json: """
            {"model":{"providerID":"opencode-go","id":"m"},"tokens":{"input":999,"output":999}}
            """),
            messageRow(now: today, json: """
            {"model":{"providerID":"opencode-go","id":"m"},"cost":1}
            """),
        ])

        let snapshot = try OpenCodeLocalUsageReader(databaseURL: url, timezone: "UTC").read(now: now)

        XCTAssertEqual(snapshot.source, .openCodeGoLocal)
        XCTAssertEqual(snapshot.timezone, "UTC")
        XCTAssertEqual(snapshot.buckets.map(\.day), ["2026-11-17", "2026-11-18"])
        let todayBucket = try XCTUnwrap(snapshot.buckets.last)
        XCTAssertEqual(todayBucket.tokens, 1_215)
        XCTAssertEqual(todayBucket.cachedInput, 1_000)
        XCTAssertEqual(todayBucket.uncachedInput, 110)
        XCTAssertEqual(todayBucket.output, 25)
        XCTAssertEqual(todayBucket.reasoning, 30)
        XCTAssertEqual(todayBucket.cacheWrite, 50)
        XCTAssertTrue(todayBucket.isPartial)
        XCTAssertEqual(snapshot.buckets.first?.tokens, 10)
        XCTAssertFalse(snapshot.buckets.first?.isPartial == true)
        XCTAssertTrue(UsageAnalysisMath.validate(snapshot.buckets))
    }

    func testFallsBackToLegacyMessageTable() throws {
        let url = directory.appendingPathComponent("opencode.db")
        let now = UsageAnalysisMath.date("2026-11-18")!.addingTimeInterval(12 * 3_600)
        try database(url, statements: [
            "CREATE TABLE message (id text PRIMARY KEY, time_created integer NOT NULL, data text NOT NULL)",
            """
            INSERT INTO message VALUES('m1', \(milliseconds(now)),
            '{"providerID":"opencode-go","role":"assistant","modelID":"m","tokens":{"input":4,"output":6,"cache":{"read":8,"write":2},"reasoning":1}}')
            """,
        ])
        let snapshot = try OpenCodeLocalUsageReader(databaseURL: url, timezone: "UTC").read(now: now)
        let bucket = try XCTUnwrap(snapshot.buckets.first)
        XCTAssertEqual(bucket.tokens, 21)
        XCTAssertEqual(bucket.cachedInput, 8)
        XCTAssertEqual(bucket.uncachedInput, 4)
        XCTAssertEqual(bucket.output, 6)
        XCTAssertEqual(bucket.reasoning, 1)
        XCTAssertEqual(bucket.cacheWrite, 2)
    }

    func testSchemaWithoutUsageReturnsEmptySnapshot() throws {
        let url = directory.appendingPathComponent("opencode.db")
        try database(url, statements: [
            """
            CREATE TABLE session_message (
              id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL,
              seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL,
              data text NOT NULL)
            """,
        ])
        let snapshot = try OpenCodeLocalUsageReader(databaseURL: url, timezone: "UTC").read()
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertEqual(snapshot.source, .openCodeGoLocal)
    }

    func testCombinesMigratedAndLegacyHistoryWithoutCountingMessagesTwice() throws {
        let url = directory.appendingPathComponent("opencode.db")
        let now = UsageAnalysisMath.date("2026-11-18")!.addingTimeInterval(12 * 3_600)
        try database(url, statements: [
            "CREATE TABLE session_message (id text PRIMARY KEY, type text, time_created integer, data text)",
            "CREATE TABLE message (id text PRIMARY KEY, time_created integer, data text)",
            """
            INSERT INTO session_message VALUES('shared','assistant',\(milliseconds(now)),
              '{"model":{"providerID":"opencode-go"},"tokens":{"input":10,"output":5}}')
            """,
            """
            INSERT INTO message VALUES('shared',\(milliseconds(now)),
              '{"providerID":"opencode-go","role":"assistant","tokens":{"input":10,"output":5}}')
            """,
            """
            INSERT INTO message VALUES('legacy',\(milliseconds(now)),
              '{"providerID":"opencode-go","role":"assistant","tokens":{"input":2,"output":3}}')
            """,
        ])
        let snapshot = try OpenCodeLocalUsageReader(databaseURL: url, timezone: "UTC").read(now: now)
        XCTAssertEqual(snapshot.buckets.first?.tokens, 20)
        XCTAssertEqual(snapshot.buckets.first?.uncachedInput, 12)
    }

    func testTokenOverflowAndMalformedCountsFailWithoutReturningPartialTotals() throws {
        for input in [String(Int64.max), "-1", "1.5", "\"invalid\""] {
            let url = directory.appendingPathComponent(UUID().uuidString + ".db")
            let now = Date.now
            try database(url, statements: [
                "CREATE TABLE session_message (id text PRIMARY KEY, type text, time_created integer, data text)",
                """
                INSERT INTO session_message VALUES('invalid','assistant',\(milliseconds(now)),
                  '{"model":{"providerID":"opencode-go"},"tokens":{"input":\(input),"output":1}}')
                """,
            ])
            XCTAssertThrowsError(try OpenCodeLocalUsageReader(databaseURL: url, timezone: "UTC").read(now: now)) {
                XCTAssertEqual($0 as? OpenCodeLocalUsageError, .invalidResponse)
            }
        }
    }

    func testForkedSessionHistoryDoesNotCountInheritedTokenUsageAgain() throws {
        let url = directory.appendingPathComponent("opencode.db")
        let now = Date.now
        try database(url, statements: [
            "CREATE TABLE session_v2 (id text PRIMARY KEY, fork_session_id text, time_created integer)",
            "CREATE TABLE session_message (id text PRIMARY KEY, session_id text, type text, time_created integer, data text)",
            "INSERT INTO session_v2 VALUES('original',NULL,\(milliseconds(now)-2000))",
            "INSERT INTO session_v2 VALUES('fork','original',\(milliseconds(now)-1000))",
            """
            INSERT INTO session_message VALUES('original-message','original','assistant',\(milliseconds(now)-2000),
              '{"model":{"providerID":"opencode-go"},"tokens":{"input":10}}')
            """,
            """
            INSERT INTO session_message VALUES('inherited-message','fork','assistant',\(milliseconds(now)-2000),
              '{"model":{"providerID":"opencode-go"},"tokens":{"input":10}}')
            """,
            """
            INSERT INTO session_message VALUES('new-message','fork','assistant',\(milliseconds(now)),
              '{"model":{"providerID":"opencode-go"},"tokens":{"input":5}}')
            """,
        ])
        let snapshot = try OpenCodeLocalUsageReader(databaseURL: url, timezone: "UTC").read(now: now)
        XCTAssertEqual(snapshot.buckets.first?.tokens, 15)
    }

    func testReadsConfiguredDataHome() throws {
        let reader = OpenCodeLocalUsageReader(homeDirectory: directory, timezone: "UTC",
                                              dataHome: directory.appendingPathComponent("custom-data").path)
        try FileManager.default.createDirectory(at: reader.databaseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try database(reader.databaseURL, statements: [
            "CREATE TABLE message (id text PRIMARY KEY, time_created integer, data text)",
            """
            INSERT INTO message VALUES('local',\(milliseconds(.now)),
              '{"providerID":"opencode-go","role":"assistant","tokens":{"input":7}}')
            """,
        ])
        XCTAssertEqual(try reader.read().buckets.first?.tokens, 7)
    }

    func testReadsLiveOpenCodeDatabaseWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["DSI_LIVE_OPENCODE_DB"] == "1" else {
            throw XCTSkip("Explicit local OpenCode database probe only")
        }
        let snapshot = try OpenCodeLocalUsageReader().read()
        XCTAssertEqual(snapshot.source, .openCodeGoLocal)
        XCTAssertFalse(snapshot.buckets.isEmpty)
        XCTAssertTrue(UsageAnalysisMath.validate(snapshot.buckets))
    }

    func testMissingDatabaseThrows() {
        let url = directory.appendingPathComponent("missing.db")
        XCTAssertThrowsError(try OpenCodeLocalUsageReader(databaseURL: url, timezone: "UTC").read()) { error in
            XCTAssertEqual(error as? OpenCodeLocalUsageError, .databaseMissing)
        }
    }

    private func messageRow(now: Date, type: String = "assistant", json: String) -> String {
        """
        INSERT INTO session_message VALUES('\(UUID().uuidString)','s','\(type)',0,\(milliseconds(now)),\(milliseconds(now)),'\(json)')
        """
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    private func database(_ url: URL, statements: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw OpenCodeLocalUsageError.sqlite("could not create test database")
        }
        defer { sqlite3_close(db) }
        for sql in statements {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "sqlite error"
                sqlite3_free(error)
                throw OpenCodeLocalUsageError.sqlite(message)
            }
        }
    }
}

@MainActor
final class OpenCodeLocalUsageRuntimeTests: XCTestCase {
    func testAnalysisRefreshesFromLocalDatabaseWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-local-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let databaseURL = root.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE session_message (
          id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL,
          seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL,
          data text NOT NULL);
        INSERT INTO session_message VALUES('m1','s','assistant',0,
          \(Int64(Date.now.timeIntervalSince1970 * 1_000)),
          \(Int64(Date.now.timeIntervalSince1970 * 1_000)),
          '{"model":{"providerID":"opencode-go","id":"m"},"tokens":{"input":2,"output":3,"reasoning":0,"cache":{"read":4,"write":0}}}');
        """
        var error: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, &error), SQLITE_OK)
        sqlite3_free(error)
        sqlite3_close(db)

        let reader = OpenCodeLocalUsageReader(databaseURL: databaseURL,
                                              timezone: TimeZone.current.identifier)
        let model = IslandModel(defaults: defaults,
                                sessionRoot: SessionStore(directory: root.appendingPathComponent("session")),
                                openCodeLocalUsage: reader)
        model.platformAccounts = PlatformAccounts(enabled: [.openCodeGo])
        model.networkAvailable = false
        let runtime = model.selectedRuntime(for: .openCodeGo)
        await runtime.analysis.waitUntilLoaded()
        model.startPolling()
        defer { model.pauseAccountPolling() }
        for _ in 0..<500 where runtime.analysis.snapshot == nil {
            try await Task.sleep(for: .milliseconds(2))
        }

        let snapshot = try XCTUnwrap(runtime.analysis.snapshot)
        XCTAssertEqual(snapshot.source, .openCodeGoLocal)
        XCTAssertEqual(snapshot.buckets.last?.tokens, 9)
        XCTAssertEqual(snapshot.buckets.last?.cachedInput, 4)
        await runtime.refreshUsageAnalysis()
        XCTAssertFalse(runtime.analysis.isLoading)
    }
}
