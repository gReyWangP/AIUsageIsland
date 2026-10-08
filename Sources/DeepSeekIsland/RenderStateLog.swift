import Foundation

/// Detailed logging is opt-in for release builds, for the lifetime of one process.
enum RenderStateLog {
    static let isEnabled: Bool = {
        if let value = ProcessInfo.processInfo.environment["AIUSAGE_RENDER_DIAGNOSTICS"] {
            return value == "1"
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    private static let logger = RenderStateLogger(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeepSeekIsland", isDirectory: true),
        enabled: isEnabled
    )

    static func append(_ line: @autoclosure () -> String) {
        guard isEnabled else { return }
        logger.append(line())
    }
}

/// The lock serializes append and trim, including calls from resource loading.
final class RenderStateLogger: @unchecked Sendable {
    private let directory: URL
    private let enabled: Bool
    private let lock = NSLock()
    private let maxLines = 200

    init(directory: URL, enabled: Bool) {
        self.directory = directory
        self.enabled = enabled
    }

    func append(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let message = String(line().prefix(4096)).replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let entry = "[\(formatter.string(from: Date()))] " + message + "\n"
        let file = directory.appendingPathComponent("render-state.log")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = Data(entry.utf8)
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: file)
            }
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.split(separator: "\n")
            if lines.count > maxLines {
                try (lines.suffix(maxLines).joined(separator: "\n") + "\n")
                    .write(to: file, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("AIUsageIsland: 无法写入渲染诊断日志")
        }
    }
}
