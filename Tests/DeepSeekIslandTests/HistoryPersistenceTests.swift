import XCTest
import Combine
@testable import DeepSeekIsland

@MainActor
final class HistoryPersistenceTests: XCTestCase {
    func testOfflineStartupCacheNotifiesAccountPresentation() async throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false
        let runtime = model.selectedRuntime(for: .chatGPT)
        let directory = runtime.store.directory.appendingPathComponent("analysis-chatgpt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(UsageAnalysisSnapshot(source: .chatGPT, buckets: [.init(day: "2026-10-07", tokens: 88)])).write(to: directory.appendingPathComponent("usage-analysis.json"))
        var changes = 0
        let observation = runtime.objectWillChange.sink { changes += 1 }
        await runtime.analysis.waitUntilLoaded()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(runtime.analysis.snapshot?.buckets.first?.tokens, 88)
        XCTAssertGreaterThan(changes, 0, "离线启动加载必须通知间接读取历史的账号界面")
        withExtendedLifetime(observation) {}
        runtime.disposeAccountRuntime()
    }
    func testSlowDiskDoesNotBlockMemoryAndLateLoadCannotReplaceFreshData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = UsageAnalysisSnapshot(source: .chatGPT, buckets: [.init(day: "2026-10-07", tokens: 10)])
        try JSONEncoder().encode(old).write(to: root.appendingPathComponent("usage-analysis.json"))
        let queue = DispatchQueue(label: "test.slow-history"), gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let storage = HistoryPersistence(directory: root, queue: queue)
        let store = UsageAnalysisStore(directory: root, storage: storage)
        let start = ContinuousClock.now
        store.accept(.init(source: .chatGPT, buckets: [.init(day: "2026-10-07", tokens: 99)]))
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
        XCTAssertEqual(store.snapshot?.buckets.first?.tokens, 99)
        gate.signal()
        await store.waitUntilLoaded()
        await storage.flush()
        XCTAssertEqual(store.snapshot?.buckets.first?.tokens, 99)
        let saved = try JSONDecoder().decode(UsageAnalysisSnapshot.self, from: Data(contentsOf: root.appendingPathComponent("usage-analysis.json")))
        XCTAssertEqual(saved.buckets.first?.tokens, 99)
    }

    func testInvalidationStopsQueuedWritesAndCleanupPrecedesNewOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "test.deleted-history"), gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let old = HistoryPersistence(directory: root, queue: queue)
        old.save([1], file: "history.json") { _ in }
        old.invalidate(removingFiles: true)
        old.save([2], file: "history.json") { _ in }
        gate.signal()
        await old.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let next = HistoryPersistence(directory: root, queue: queue)
        next.save([3], file: "history.json") { _ in }
        await next.flush()
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: Data(contentsOf: root.appendingPathComponent("history.json"))), [3])
    }

    func testWriteFailurePreservesMemoryAndReportsStorageSeparately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageAnalysisStore(directory: root)
        await store.waitUntilLoaded()
        store.accept(.init(source: .chatGPT, buckets: [.init(day: "2026-10-07", tokens: 77)]))
        await HistoryPersistence.flushAll()
        await Task.yield()
        XCTAssertEqual(store.snapshot?.buckets.first?.tokens, 77)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertNil(store.refreshFailure)
    }

    func testRefreshDuringStartupRetainsOlderDaysWithoutOverwritingNewDay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = UsageAnalysisSnapshot(source: .chatGPT, buckets: [.init(day: "2026-10-06", tokens: 10), .init(day: "2026-10-07", tokens: 20)])
        try JSONEncoder().encode(old).write(to: root.appendingPathComponent("usage-analysis.json"))
        let queue = DispatchQueue(label: "test.startup-merge"), gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let storage = HistoryPersistence(directory: root, queue: queue)
        let store = UsageAnalysisStore(directory: root, storage: storage)
        // Ensure the load request is submitted before releasing the disk.
        await Task.yield()
        store.accept(.init(source: .chatGPT, buckets: [.init(day: "2026-10-07", tokens: 99)]))
        gate.signal()
        await store.waitUntilLoaded()
        XCTAssertEqual(store.snapshot?.buckets.map(\.tokens), [10, 99])
        await storage.flush()
    }

    func testRejectedRefreshDuringStartupStillLoadsValidDiskHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = UsageAnalysisSnapshot(source: .chatGPT, buckets: [.init(day: "2026-10-07", tokens: 10)])
        try JSONEncoder().encode(old).write(to: root.appendingPathComponent("usage-analysis.json"))
        let queue = DispatchQueue(label: "test.rejected-startup"), gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let storage = HistoryPersistence(directory: root, queue: queue)
        let store = UsageAnalysisStore(directory: root, storage: storage)
        store.accept(.init(source: .chatGPT, buckets: [.init(day: "2026-10-07", tokens: -1)]))
        gate.signal()
        await store.waitUntilLoaded()
        XCTAssertEqual(store.snapshot?.buckets.first?.tokens, 10)
        XCTAssertEqual(store.refreshFailure, .invalidResponse)
        await storage.flush()
    }
}
