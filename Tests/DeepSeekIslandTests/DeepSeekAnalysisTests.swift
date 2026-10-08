import XCTest
@testable import DeepSeekIsland
final class DeepSeekAnalysisTests: XCTestCase {
    func testPreservesCacheCategoriesAndOfficialCostAcrossModels() throws {
        let now = UsageAnalysisMath.date("2026-10-06")!.addingTimeInterval(12*3600)
        let time = Int64(UsageAnalysisMath.date("2026-10-05")!.timeIntervalSince1970)
        let amount = Data("{\"code\":0,\"data\":{\"biz_code\":0,\"biz_data\":{\"series\":[{\"model\":\"a\",\"buckets\":[{\"time\":\(time),\"usage\":{\"PROMPT_CACHE_HIT_TOKEN\":90,\"PROMPT_CACHE_MISS_TOKEN\":10,\"RESPONSE_TOKEN\":20}}]},{\"model\":\"b\",\"buckets\":[{\"time\":\(time),\"usage\":{\"RESPONSE_TOKEN\":30}}]}]}}}".utf8)
        let costs: [Int64: Decimal] = [time: Decimal(string:"0.12345")!]
        let snapshot = try PlatformAccountClient.decodeAnalysis(amount, cost:costs, currency:"CNY", now:now)
        let day = try XCTUnwrap(snapshot.buckets.first)
        XCTAssertEqual(day.tokens,150); XCTAssertEqual(day.cachedInput,90); XCTAssertEqual(day.uncachedInput,10); XCTAssertEqual(day.output,50)
        XCTAssertEqual(day.cost,Decimal(string:"0.12345")!); XCTAssertEqual(UsageAnalysisMath.cacheRate(snapshot.buckets),90)
        XCTAssertFalse(day.isPartial)
    }
    func testThirtyDayQueryCoversLastMonthAtStartOfMonth() {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:0)!
        let ranges = UsageRanges(now:UsageAnalysisMath.date("2026-10-06")!,calendar:calendar)
        XCTAssertEqual(ranges.queryRange.start,UsageAnalysisMath.date("2026-09-07"))
    }
}
