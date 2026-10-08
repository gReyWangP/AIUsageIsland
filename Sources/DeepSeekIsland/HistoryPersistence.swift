import Foundation

/// All history I/O uses one serial executor. Submission is synchronous; disk work is not.
/// The lock protects only pending jobs and ownership, never file I/O.
final class HistoryPersistence: @unchecked Sendable {
    private static let sharedQueue = DispatchQueue(label: "AIUsageIsland.history", qos: .utility)
    private let queue: DispatchQueue
    private let directory: URL
    private let lock = NSLock()
    private var valid = true
    private var pending: [String: @Sendable () -> Void] = [:]
    private var scheduled = false

    init(directory: URL, queue: DispatchQueue? = nil) {
        self.directory = directory; self.queue = queue ?? Self.sharedQueue
    }

    func beginLoad<Value: Decodable & Sendable>(_ type: Value.Type, file: String) -> Task<Value?, Never> {
        let (stream, continuation) = AsyncStream<Value?>.makeStream()
        queue.async { [self] in
            let url = directory.appendingPathComponent(file)
            var value: Value?
            if isValid, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size <= 2_000_000, let data = try? Data(contentsOf: url), data.count <= 2_000_000 {
                value = try? JSONDecoder().decode(type, from: data)
            }
            continuation.yield(isValid ? value : nil); continuation.finish()
        }
        return Task { for await value in stream { return value }; return nil }
    }

    func load<Value: Decodable & Sendable>(_ type: Value.Type, file: String) async -> Value? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard isValid else { continuation.resume(returning: nil); return }
                let url = directory.appendingPathComponent(file)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 2_000_000, let data = try? Data(contentsOf: url), data.count <= 2_000_000,
                      let value = try? JSONDecoder().decode(type, from: data), isValid else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: value)
            }
        }
    }

    func save<Value: Encodable & Sendable>(_ value: Value, file: String,
                                          completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        lock.lock()
        guard valid else { lock.unlock(); return }
        pending[file] = { [self] in
            guard isValid else { return }
            let success: Bool
            do {
                let data = try JSONEncoder().encode(value)
                guard isValid else { return }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(file), options: .atomic)
                success = true
            } catch { success = false }
            Task { @MainActor [self] in if isValid { completion(success) } }
        }
        if !scheduled {
            scheduled = true
            queue.async { [self] in drain() }
        }
        lock.unlock()
    }

    private var isValid: Bool { lock.withLock { valid } }
    private func drain() {
        while true {
            let jobs = lock.withLock { () -> [@Sendable () -> Void] in
                guard valid, !pending.isEmpty else { scheduled = false; pending.removeAll(); return [] }
                let jobs = Array(pending.values); pending.removeAll(); return jobs
            }
            guard !jobs.isEmpty else { return }
            for job in jobs { job() }
        }
    }

    /// Invalidates late load completions and queued saves immediately. A deletion queued
    /// behind an active write also removes that write's output before a new owner loads it.
    func invalidate(removingFiles: Bool = false, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        lock.withLock { valid = false; pending.removeAll() }
        if removingFiles {
            queue.async { [directory] in
                let success = Self.remove(directory)
                Task { @MainActor in completion?(success) }
            }
        }
    }

    static func removeDirectory(_ directory: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        sharedQueue.async {
            let success = remove(directory)
            Task { @MainActor in completion(success) }
        }
    }
    private static func remove(_ directory: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            return true
        } catch { return false }
    }
    func flush() async { await Self.barrier(queue) }
    static func flushAll() async { await barrier(sharedQueue) }
    private static func barrier(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
