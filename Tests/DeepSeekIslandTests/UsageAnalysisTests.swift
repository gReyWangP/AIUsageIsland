import XCTest
@testable import DeepSeekIsland

final class UsageAnalysisTests: XCTestCase {
    func testChatGPTUsesOfficialDailyBucketsAndRejectsDuplicateDays() throws {
        let data = Data(#"{"stats":{"lifetime_tokens":999,"daily_usage_buckets":[{"start_date":"2026-10-01","tokens":32400000},{"start_date":"2026-10-03","tokens":0}]}}"#.utf8)
        let snapshot = try UsageAnalysisParser.chatGPT(data, now: date("2026-10-06"))
        XCTAssertEqual(snapshot.buckets.map(\.tokens), [32400000, 0])
        XCTAssertEqual(snapshot.buckets.map(\.day), ["2026-10-01", "2026-10-03"])
        XCTAssertEqual(TokenFormatter.short(snapshot.buckets[0].tokens), "0.32亿")
        XCTAssertThrowsError(try UsageAnalysisParser.chatGPT(Data(#"{"stats":{"daily_usage_buckets":[{"start_date":"2026-10-01","tokens":1},{"start_date":"2026-10-01","tokens":2}]}}"#.utf8)))
        XCTAssertThrowsError(try UsageAnalysisParser.chatGPT(Data(#"{"stats":{"daily_usage_buckets":null}}"#.utf8)))
    }
    func testWeightedCacheRateIgnoresOutputAndZeroInputIsUnknown() {
        let buckets = [DailyUsageBucket(day: "2026-10-01", tokens: 1000, cachedInput: 90, uncachedInput: 10, output: 900), DailyUsageBucket(day: "2026-10-02", tokens: 100, cachedInput: 0, uncachedInput: 100, output: 0)]
        XCTAssertEqual(UsageAnalysisMath.cacheRate(buckets), 45)
        XCTAssertNil(UsageAnalysisMath.cacheRate([DailyUsageBucket(day: "2026-10-01", tokens: 5, cachedInput: 0, uncachedInput: 0, output: 5)]))
        XCTAssertNil(UsageAnalysisMath.cacheRate([DailyUsageBucket(day: "2026-10-01", tokens: 5)]))
    }
    func testAverageRequiresSevenConsecutiveCompleteDaysAndDoesNotFillGaps() {
        let complete = (1...7).map { DailyUsageBucket(day: String(format: "2026-10-%02d", $0), tokens: Int64($0 * 100)) }
        XCTAssertEqual(UsageAnalysisMath.averages(complete).map(\.tokens), [400])
        XCTAssertTrue(UsageAnalysisMath.averages(Array(complete.dropFirst())).isEmpty)
        var partial = complete; partial[6].isPartial = true
        XCTAssertTrue(UsageAnalysisMath.averages(partial).isEmpty)
    }
    func testGLMLegacyAndCreditTokenSeriesNeverUseCreditAmounts() throws {
        let legacy = Data(#"{"code":200,"data":{"x_time":["2026-10-01","2026-10-02"],"tokensUsage":[100,200],"modelCallCount":[999,999]}}"#.utf8)
        XCTAssertEqual(try UsageAnalysisParser.zhipu(legacy).buckets.map(\.tokens), [100,200])
        let credit = Data(#"{"code":200,"data":{"modelUsage":{"xTime":["2026-10-01"],"modelDataList":[{"totalTokensUsage":[123],"totalCreditsUsage":[999]},{"totalTokensUsage":[7]}]}}}"#.utf8)
        XCTAssertEqual(try UsageAnalysisParser.zhipu(credit).buckets.map(\.tokens), [130])
        XCTAssertThrowsError(try UsageAnalysisParser.zhipu(Data(#"{"code":200,"data":{"x_time":["2026-10-01"],"tokensUsage":[-1]}}"#.utf8)))
        XCTAssertThrowsError(try UsageAnalysisParser.zhipu(Data(#"{"code":200,"data":{"x_time":["2026-10-01"],"tokensUsage":[null]}}"#.utf8)))
        XCTAssertThrowsError(try UsageAnalysisParser.zhipu(Data(#"{"code":200,"data":{"x_time":["2026-10-01"],"tokensUsage":[true]}}"#.utf8)))
    }
    func testGLMHourlyCoverageMarksIncompleteDaysAndRequiresValidTime() throws {
        let times=(0..<24).map {String(format:"2026-10-01 %02d:00:00",$0)}
        let full=try JSONSerialization.data(withJSONObject:["code":200,"data":["x_time":times,"tokensUsage":Array(repeating:1,count:24)]])
        let bucket=try XCTUnwrap(UsageAnalysisParser.zhipu(full).buckets.first)
        XCTAssertEqual(bucket.tokens,24);XCTAssertFalse(bucket.isPartial)
        let partial=Data(#"{"code":200,"data":{"x_time":["2026-10-01 00:00:00"],"tokensUsage":[7]}}"#.utf8)
        XCTAssertTrue(try UsageAnalysisParser.zhipu(partial).buckets.first!.isPartial)
        XCTAssertThrowsError(try UsageAnalysisParser.zhipu(Data(#"{"code":200,"data":{"x_time":["2026-10-01 2099-10-02"],"tokensUsage":[7]}}"#.utf8)))
    }
    func testLongOfficialAccountHistoryRetainsRequestedRecentWindow() throws {
        let now=date("2026-10-06")
        let rows=(0..<1000).map { offset in ["start_date":UsageAnalysisMath.day(now.addingTimeInterval(-Double(offset)*86400),timezone:"UTC"),"tokens":1] as [String:Any] }
        let data=try JSONSerialization.data(withJSONObject:["stats":["daily_usage_buckets":rows]])
        let snapshot=try UsageAnalysisParser.chatGPT(data,now:now)
        XCTAssertEqual(snapshot.buckets.count,90)
        XCTAssertEqual(snapshot.buckets.first?.day,"2026-07-09")
        XCTAssertEqual(snapshot.buckets.last?.day,"2026-10-06")
    }
    private func date(_ value: String) -> Date { UsageAnalysisMath.date(value)! }
}

@MainActor
final class UsageAnalysisStoreTests: XCTestCase {
    func testPersistsPerAccountAndReplacesRefreshRatherThanAddingConsumption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageAnalysisStore(directory: root.appendingPathComponent("account-a"))
        store.accept(UsageAnalysisSnapshot(source: .deepSeek, buckets: [.init(day: "2026-10-05", tokens: 100)]))
        store.accept(UsageAnalysisSnapshot(source: .deepSeek, buckets: [.init(day: "2026-10-05", tokens: 150)]))
        XCTAssertEqual(store.snapshot?.buckets.map(\.tokens), [150])
        await HistoryPersistence.flushAll()
        let restored = UsageAnalysisStore(directory: root.appendingPathComponent("account-a"))
        await restored.waitUntilLoaded()
        XCTAssertEqual(restored.snapshot?.buckets.map(\.tokens), [150])
        XCTAssertNil(UsageAnalysisStore(directory: root.appendingPathComponent("account-b")).snapshot)
        store.accept(UsageAnalysisSnapshot(source: .deepSeek, buckets: [.init(day: "2026-10-06", tokens: 20)]))
        XCTAssertEqual(store.snapshot?.buckets.map(\.tokens), [150,20], "短响应不能抹掉已返回的历史")
        XCTAssertEqual(store.snapshot?.buckets.first?.isCached,true)
        store.accept(UsageAnalysisSnapshot(source: .deepSeek, buckets: []))
        XCTAssertEqual(store.snapshot?.buckets.map(\.tokens), [150,20], "空响应不能清空缓存")
        store.fail("暂不可用")
        XCTAssertEqual(store.snapshot?.buckets.first?.tokens, 150)
        store.clear()
        await HistoryPersistence.flushAll()
        let cleared = UsageAnalysisStore(directory: root.appendingPathComponent("account-a"))
        await cleared.waitUntilLoaded()
        XCTAssertNil(cleared.snapshot)
    }
}
