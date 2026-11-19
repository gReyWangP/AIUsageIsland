import Foundation
import SQLite3

enum OpenCodeLocalUsageError: LocalizedError, Equatable {
    case databaseMissing
    case unsupportedSchema
    case sqlite(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .databaseMissing: "未找到本机 OpenCode 数据库；请先在本机使用 OpenCode"
        case .unsupportedSchema: "本机 OpenCode 数据库版本暂不支持"
        case .sqlite(let message): "读取本机 OpenCode 用量失败：\(message)"
        case .invalidResponse: "本机 OpenCode 用量记录格式无法识别"
        }
    }
}

/// Aggregates OpenCode Go token counts from OpenCode's local SQLite database.
/// Only token/model metadata is read; message text and prompts are never selected.
struct OpenCodeLocalUsageReader: Sendable {
    let databaseURL: URL
    let timezone: String

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         timezone: String = TimeZone.current.identifier,
         dataHome: String? = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]) {
        let root = dataHome.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? homeDirectory.appendingPathComponent(".local/share")
        self.init(databaseURL: root.appendingPathComponent("opencode/opencode.db"),
                  timezone: timezone)
    }

    init(databaseURL: URL, timezone: String) {
        self.databaseURL = databaseURL
        self.timezone = timezone.isEmpty ? "Asia/Shanghai" : timezone
    }

    func read(now: Date = .now, historyDays: Int = 90) throws -> UsageAnalysisSnapshot {
        let url = databaseURL.resolvingSymlinksInPath()
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            throw OpenCodeLocalUsageError.databaseMissing
        }
        return try withDatabase { db in
            let cutoffMs = Int64(now.addingTimeInterval(-Double(max(30, historyDays)) * 86_400)
                .timeIntervalSince1970 * 1_000)
            var rows: [TokenRow] = []
            if tableExists("session_message", db: db) {
                let sql = sessionMessageSQL + inheritedMessageFilter(sessionTable: "session_v2", messageTable: "session_message", db: db)
                rows = try readRows(sql, cutoffMs: cutoffMs, db: db)
            }
            if tableExists("message", db: db) {
                let currentIDs = Set(rows.map(\.id))
                let sql = legacyMessageSQL + inheritedMessageFilter(sessionTable: "session", messageTable: "message", db: db)
                rows += try readRows(sql, cutoffMs: cutoffMs, db: db)
                    .filter { !currentIDs.contains($0.id) }
            }
            guard !rows.isEmpty || tableExists("session_message", db: db) || tableExists("message", db: db) else {
                throw OpenCodeLocalUsageError.unsupportedSchema
            }
            let today = UsageAnalysisMath.day(now, timezone: timezone)
            let start = UsageAnalysisMath.day(now.addingTimeInterval(-Double(max(30, historyDays) - 1) * 86_400),
                                              timezone: timezone)
            var totals: [String: Totals] = [:]
            for row in rows {
                let date = row.timestampMs > 100_000_000_000
                    ? Date(timeIntervalSince1970: Double(row.timestampMs) / 1_000)
                    : Date(timeIntervalSince1970: Double(row.timestampMs))
                let day = UsageAnalysisMath.day(date, timezone: timezone)
                guard day >= start, day <= today else { continue }
                var value = totals[day] ?? Totals()
                value.input = try add(value.input, row.input)
                value.output = try add(value.output, row.output)
                value.cacheRead = try add(value.cacheRead, row.cacheRead)
                value.cacheWrite = try add(value.cacheWrite, row.cacheWrite)
                value.reasoning = try add(value.reasoning, row.reasoning)
                totals[day] = value
            }
            let buckets = try totals.keys.sorted().map { day -> DailyUsageBucket in
                guard let value = totals[day],
                      let tokens = UsageAnalysisMath.sum([value.input, value.output,
                                                          value.cacheRead, value.cacheWrite,
                                                          value.reasoning]) else {
                    throw OpenCodeLocalUsageError.invalidResponse
                }
                return DailyUsageBucket(
                    day: day,
                    tokens: tokens,
                    cachedInput: value.cacheRead,
                    uncachedInput: value.input,
                    output: value.output,
                    reasoning: value.reasoning,
                    cacheWrite: value.cacheWrite,
                    isPartial: day == today)
            }
            guard UsageAnalysisMath.validate(buckets) else { throw OpenCodeLocalUsageError.invalidResponse }
            return UsageAnalysisSnapshot(source: .openCodeGoLocal, buckets: buckets,
                                         updatedAt: now, timezone: timezone)
        }
    }

    private struct Totals {
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheWrite: Int64 = 0
        var reasoning: Int64 = 0
    }

    private struct TokenRow {
        let id: String
        let timestampMs: Int64
        let input: Int64
        let output: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let reasoning: Int64
    }

    private func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum >= 0 else { throw OpenCodeLocalUsageError.invalidResponse }
        return sum
    }

    private var tokenColumns: String {
        """
        json_extract(data,'$.tokens.input'),
        json_extract(data,'$.tokens.output'),
        json_extract(data,'$.tokens.cache.read'),
        json_extract(data,'$.tokens.cache.write'),
        json_extract(data,'$.tokens.reasoning')
        """
    }

    private var sessionMessageSQL: String {
        """
        SELECT
          id,
          CAST(COALESCE(json_extract(data,'$.time.created'),
            CASE WHEN time_created < 100000000000 THEN time_created * 1000 ELSE time_created END) AS INTEGER),
          \(tokenColumns)
        FROM session_message
        WHERE type IN ('assistant', 'compaction')
          AND json_valid(data)
          AND json_extract(data,'$.model.providerID') = 'opencode-go'
          AND json_type(data,'$.tokens') = 'object'
          AND (CASE WHEN time_created < 100000000000 THEN time_created * 1000 ELSE time_created END) >= ?1
        """
    }

    private var legacyMessageSQL: String {
        """
        SELECT
          id,
          CAST(COALESCE(json_extract(data,'$.time.created'),
            CASE WHEN time_created < 100000000000 THEN time_created * 1000 ELSE time_created END) AS INTEGER),
          \(tokenColumns)
        FROM message
        WHERE json_valid(data)
          AND json_extract(data,'$.providerID') = 'opencode-go'
          AND json_extract(data,'$.role') = 'assistant'
          AND json_type(data,'$.tokens') = 'object'
          AND (CASE WHEN time_created < 100000000000 THEN time_created * 1000 ELSE time_created END) >= ?1
        """
    }

    private func withDatabase<T>(_ read: (OpaquePointer) throws -> T) throws -> T {
        let path = databaseURL.resolvingSymlinksInPath().path
        var db: OpaquePointer?
        var result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        if result != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            db = nil
            let hasWAL = FileManager.default.fileExists(atPath: path + "-wal")
            let hasSHM = FileManager.default.fileExists(atPath: path + "-shm")
            guard !hasWAL, !hasSHM else { throw OpenCodeLocalUsageError.sqlite(message) }
            let immutable = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
            result = sqlite3_open_v2(immutable, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        }
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw OpenCodeLocalUsageError.sqlite(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeLocalUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        return try read(db)
    }

    private func tableExists(_ name: String, db: OpaquePointer) -> Bool {
        sqlite3_table_column_metadata(db, nil, name, nil, nil, nil, nil, nil, nil) == SQLITE_OK
    }

    private func inheritedMessageFilter(sessionTable: String, messageTable: String, db: OpaquePointer) -> String {
        guard sqlite3_table_column_metadata(db, nil, sessionTable, "fork_session_id", nil, nil, nil, nil, nil) == SQLITE_OK else {
            return ""
        }
        return """

          AND NOT EXISTS (
            SELECT 1 FROM \(sessionTable) AS session
            WHERE session.id = \(messageTable).session_id
              AND session.fork_session_id IS NOT NULL
              AND \(messageTable).time_created < session.time_created)
        """
    }

    private func readRows(_ sql: String, cutoffMs: Int64, db: OpaquePointer) throws -> [TokenRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw OpenCodeLocalUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoffMs)
        var rows: [TokenRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw OpenCodeLocalUsageError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            guard let rawID = sqlite3_column_text(statement, 0) else {
                throw OpenCodeLocalUsageError.invalidResponse
            }
            let timestamp = sqlite3_column_int64(statement, 1)
            guard timestamp > 0 else { continue }
            let values = try (2...6).map { try integer(statement, column: Int32($0)) }
            guard values.contains(where: { $0 != nil }) else { continue }
            rows.append(TokenRow(
                id: String(cString: rawID),
                timestampMs: timestamp,
                input: values[0] ?? 0,
                output: values[1] ?? 0,
                cacheRead: values[2] ?? 0,
                cacheWrite: values[3] ?? 0,
                reasoning: values[4] ?? 0))
        }
        return rows
    }

    private func integer(_ statement: OpaquePointer, column: Int32) throws -> Int64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
            throw OpenCodeLocalUsageError.invalidResponse
        }
        let value = sqlite3_column_int64(statement, column)
        guard value >= 0 else { throw OpenCodeLocalUsageError.invalidResponse }
        return value
    }
}
