import XCTest
@testable import DeepSeekIsland
private actor AccountAnalysisService: ChatGPTServing {
    let noQuota: Bool
    init(noQuota: Bool = false) { self.noQuota=noQuota }
    func fetchQuota(grant: ChatGPTGrant) async throws -> ChatGPTQuota {
        if noQuota { throw ChatGPTQuotaError.noQuota }
        return .init(planType:"plus",session:.init(windowSeconds:18000,usedPercent:20,resetAt:.now.addingTimeInterval(3600)),weekly:nil,email:nil,accountID:grant.accountID,limitReached:false)
    }
    func refresh(_ grant: ChatGPTGrant) async throws -> ChatGPTGrant { grant }
    func fetchAnalysis(grant: ChatGPTGrant) async throws -> UsageAnalysisSnapshot {
        .init(source:.chatGPT,buckets:[.init(day:UsageAnalysisMath.day(.now,timezone:"UTC"),tokens:grant.accountID == "a" ? 1000:2000)],timezone:"UTC")
    }
}
@MainActor
final class AccountAnalysisIsolationTests: XCTestCase {
    func testEachAccountReadsAndPersistsItsOwnOfficialHistory() async throws {
        let (model,root,defaults,name)=try fixture(noQuota:false)
        defer {defaults.removePersistentDomain(forName:name);try? FileManager.default.removeItem(at:root.directory)}
        let accounts=model.savedAccounts.filter {$0.platform == .chatGPT}
        for account in accounts { await model.refreshAccount(id:account.id) }
        for _ in 0..<100 where accounts.contains(where:{model.accountRuntime(for:$0).analysis.snapshot == nil}) {try await Task.sleep(for:.milliseconds(10))}
        let values=accounts.map {model.accountRuntime(for:$0).analysis.snapshot?.buckets.first?.tokens}
        XCTAssertEqual(Set(values.compactMap {$0}),Set([Int64(1000),2000]))
        let storeA=model.accountRuntime(for:accounts[0]).analysis
        let storeB=model.accountRuntime(for:accounts[1]).analysis
        XCTAssertFalse(storeA === storeB)
    }
    func testMissingQuotaDoesNotPreventIndependentTokenStatistics() async throws {
        let (model,root,defaults,name)=try fixture(noQuota:true)
        defer {defaults.removePersistentDomain(forName:name);try? FileManager.default.removeItem(at:root.directory)}
        let account=model.savedAccounts.first {$0.platform == .chatGPT}!
        await model.refreshAccount(id:account.id)
        for _ in 0..<100 where model.accountRuntime(for:account).analysis.snapshot == nil {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertNotNil(model.accountRuntime(for:account).analysis.snapshot,"日统计与额度接口相互独立")
    }
    private func fixture(noQuota: Bool) throws -> (IslandModel,SessionStore,UserDefaults,String) {
        let name=UUID().uuidString, defaults=UserDefaults(suiteName:name)!
        let root=SessionStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var profiles=AccountProfiles()
        let second=profiles.add(platform:.chatGPT,label:"工作账号")
        for (entry,id) in [(profiles.entries(for:.chatGPT).first {$0.id == AccountProfileEntry.legacyID}!,"a"),(second,"b")] {
            XCTAssertTrue(profiles.store(for:.chatGPT,entry:entry,root:root).saveChatGPTGrant(.init(accessToken:id,refreshToken:id+"-refresh",accountID:id,savedAt:.now)))
        }
        defaults.set(try JSONEncoder().encode(profiles),forKey:"accountProfilesV1");defaults.set(["chatgpt"],forKey:"enabledUsagePlatforms")
        return (IslandModel(defaults:defaults,sessionRoot:root,chatGPTClient:AccountAnalysisService(noQuota:noQuota)),root,defaults,name)
    }
}
