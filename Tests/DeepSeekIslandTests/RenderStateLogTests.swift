import XCTest
@testable import DeepSeekIsland

final class RenderStateLogTests: XCTestCase {
    func testDisabledLoggingDoesNotEvaluateMessageOrCreateDirectory() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = RenderStateLogger(directory: directory, enabled: false)
        var evaluated = false
        func message() -> String { evaluated = true; return "render" }
        logger.append(message())
        XCTAssertFalse(evaluated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testExplicitDiagnosticLoggingKeepsOnlyRecentBoundedEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = RenderStateLogger(directory: directory, enabled: true)
        for i in 0..<205 { logger.append("entry-\(i)") }
        let file = directory.appendingPathComponent("render-state.log")
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 200)
        XCTAssertTrue(lines.first!.hasSuffix("entry-5"))
        XCTAssertTrue(lines.last!.hasSuffix("entry-204"))
        logger.append(String(repeating: "x", count: 20_000))
        let bounded = try String(contentsOf: file, encoding: .utf8)
        XCTAssertLessThan(bounded.split(separator: "\n").last!.count, 4200)
    }
}
