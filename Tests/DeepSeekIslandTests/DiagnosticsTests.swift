import XCTest
@testable import DeepSeekIsland

@MainActor
final class DiagnosticsTests: XCTestCase {
    func testReportIsAllowlistedAndNeverExportsIdentityOrRawErrors() {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek])
        model.renameAccount(AccountProfileEntry.legacyID, platform: .deepSeek, label: "private@example.com")
        let runtime = model.accountRuntime(for: model.activeAccountReference(for: .deepSeek))
        runtime.accountName = "Private Name"
        runtime.errorMessage = "Bearer secret-token Cookie session-secret https://private.example"
        runtime.analysis.fail("Bearer analysis-secret Cookie session-secret")
        let report = DiagnosticReport.render(model: model)
        for secret in ["private@example.com", "Private Name", "secret-token", "analysis-secret", "session-secret", "private.example", root.directory.path] {
            XCTAssertFalse(report.contains(secret))
        }
        XCTAssertTrue(report.contains("deepseek"))
        XCTAssertTrue(report.contains("账号 1"))
        XCTAssertTrue(report.contains("额度错误类别：none"))
        XCTAssertTrue(report.contains("日统计错误类别：unknown"))
    }
}
