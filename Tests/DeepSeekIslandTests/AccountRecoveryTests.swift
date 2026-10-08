import XCTest
@testable import DeepSeekIsland

private struct RecoveryChatGPTService: ChatGPTServing {
    let failure: UsageRefreshFailure
    func fetchQuota(grant: ChatGPTGrant) async throws -> ChatGPTQuota { throw failure }
    func refresh(_ grant: ChatGPTGrant) async throws -> ChatGPTGrant { throw failure }
}

@MainActor
final class AccountRecoveryTests: XCTestCase {
    func testAccountRowDistinguishesNetworkRateLimitAndInterfaceFailures() async throws {
        for (failure, expected): (UsageRefreshFailure, String) in [
            (.transport(URLError.notConnectedToInternet.rawValue), "网络更新失败"),
            (.rateLimited(until: .now.addingTimeInterval(600)), "限流冷却中"),
            (.invalidResponse, "接口格式变化"),
            (.credentialPersistence, "授权保存失败")
        ] {
            let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
            let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
            XCTAssertTrue(root.saveChatGPTGrant(.init(accessToken: "test", refreshToken: "test-refresh", accountID: "test-account", savedAt: .now)))
            let model = IslandModel(defaults: defaults, sessionRoot: root, chatGPTClient: RecoveryChatGPTService(failure: failure))
            let account = model.activeAccountReference(for: .chatGPT)
            let runtime = model.accountRuntime(for: account)
            runtime.chatGPTQuota = .init(planType: "plus", session: .init(windowSeconds: 18000, usedPercent: 15, resetAt: nil), weekly: nil, email: nil, accountID: nil, limitReached: false)
            runtime.chatGPTLastUpdated = .now
            await runtime.refreshChatGPT()
            XCTAssertEqual(model.accountConnectionLabel(account), expected)
            let recovery = runtime.recoveryPresentation()
            switch failure {
            case .transport: XCTAssertEqual(recovery.action, .retry); XCTAssertTrue(recovery.canPerformAction)
            case .rateLimited: XCTAssertEqual(recovery.action, .wait); XCTAssertFalse(recovery.canPerformAction)
            case .invalidResponse: XCTAssertEqual(recovery.action, .officialPage)
            case .credentialPersistence: XCTAssertEqual(recovery.action, .signIn)
            default: XCTFail("Unexpected fixture")
            }
            XCTAssertEqual(runtime.chatGPTQuota?.session?.usedPercent, 15, "失败保留有效缓存")
            XCTAssertTrue(runtime.chatGPTConnected)
        }
    }

    func testRateLimitRemainsHigherPriorityThanAuthorizationAndCancellation() {
        let now = Date(timeIntervalSince1970: 1000)
        var policy = RefreshPolicy()
        policy.record(.rateLimited(until: now.addingTimeInterval(600)), at: now)
        policy.record(.authorization, at: now)
        policy.record(.cancelled, at: now)
        let waiting = AccountRecoveryPresentation.make(connected: true, signingIn: false, loaded: true,
            networkAvailable: true, loading: false, issue: nil, failure: .authorization,
            cooldownUntil: policy.cooldownUntil, platform: .chatGPT, at: now)
        XCTAssertEqual(waiting.action, .wait)
        XCTAssertFalse(waiting.canPerformAction)
        XCTAssertFalse(policy.canAttempt(at: now, manual: true))
        let expired = AccountRecoveryPresentation.make(connected: true, signingIn: false, loaded: true,
            networkAvailable: true, loading: false, issue: nil, failure: .authorization,
            cooldownUntil: policy.cooldownUntil, platform: .chatGPT, at: now.addingTimeInterval(600))
        XCTAssertEqual(expired.action, .signIn)
    }

    func testDailyStatisticsFailureAndCancellationRemainIndependentOfQuota() throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.platformAccounts = .init(enabled: [.chatGPT])
        let runtime = model.selectedRuntime(for: .chatGPT)
        runtime.chatGPTConnected = true
        runtime.chatGPTLastUpdated = .now
        runtime.analysis.accept(.init(source: .chatGPT, buckets: [.init(day: "2026-10-01", tokens: 123)], updatedAt: Date(timeIntervalSince1970: 1790812800)))
        runtime.analysis.fail("private-statistics-error", failure: .authorization)
        runtime.analysis.fail("cancelled", failure: .cancelled)
        XCTAssertEqual(runtime.analysis.refreshFailure, .authorization)
        XCTAssertEqual(runtime.analysis.snapshot?.buckets.first?.tokens, 123)
        XCTAssertNil(runtime.primaryRefreshFailure)
        XCTAssertEqual(runtime.recoveryPresentation().action, .retry)
        let report = DiagnosticReport.render(model: model)
        XCTAssertTrue(report.contains("额度错误类别：none"))
        XCTAssertTrue(report.contains("日统计错误类别：authorization"))
        XCTAssertFalse(report.contains("private-statistics-error"))
    }
}
