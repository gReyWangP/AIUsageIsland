import XCTest
@testable import DeepSeekIsland

@MainActor
final class UsageAnalysisPerformanceTests: XCTestCase {
    func testRepeatedDetailOverviewAndChartPreparationFitInteractionBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = UsageAnalysisStore(directory:directory)
        let buckets = (0..<90).map { offset in
            DailyUsageBucket(day:UsageAnalysisMath.day(Date.now.addingTimeInterval(-Double(offset)*86400)),tokens:1_000_000,cachedInput:800_000,uncachedInput:100_000,output:100_000)
        }
        store.accept(.init(source:.deepSeek,buckets:buckets))
        let started = ContinuousClock.now
        for _ in 0..<100 {
            XCTAssertFalse(UsageAnalysisOverview.make(store,platform:.deepSeek).detail.isEmpty)
        }
        for index in 0..<100 {
            XCTAssertNotNil(store.period(days:index.isMultiple(of:2) ? 7 : 30).totalTokens)
        }
        // One chart body previously recalculated all averages for every line segment.
        for _ in 0..<30 { XCTAssertFalse(UsageAnalysisMath.averages(buckets).isEmpty) }
        let elapsed = started.duration(to:.now)
        print("ANALYSIS interaction preparation: \(elapsed)")
        XCTAssertLessThan(elapsed,.milliseconds(250),"交互路径不能反复构造日期格式器、解析和扫描历史")
    }
    func testPreparedPeriodsInvalidateOnNewDataMidnightFailureAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = UsageAnalysisStore(directory:directory)
        let now = try XCTUnwrap(UsageAnalysisMath.date("2026-10-06"))
        let buckets = (0..<30).map { offset in
            DailyUsageBucket(day:UsageAnalysisMath.day(now.addingTimeInterval(-Double(offset)*86400),timezone:"UTC"),tokens:100)
        }
        store.accept(.init(source:.chatGPT,buckets:buckets,updatedAt:now,timezone:"UTC"))
        let week = store.period(days:7,now:now), month = store.period(days:30,now:now)
        XCTAssertEqual(week.totalTokens,700);XCTAssertEqual(month.totalTokens,3000)
        XCTAssertEqual(week.averages.count,7);XCTAssertEqual(week.segments.count,7)
        XCTAssertEqual(store.period(days:7,now:now).buckets,week.buckets)
        store.accept(.init(source:.chatGPT,buckets:[.init(day:"2026-10-06",tokens:900)],updatedAt:now,timezone:"UTC"))
        XCTAssertEqual(store.period(days:7,now:now).totalTokens,1500)
        XCTAssertEqual(store.period(days:30,now:now).totalTokens,3800)
        XCTAssertEqual(store.period(days:7,now:now.addingTimeInterval(86400)).buckets.count,6)
        let overview=store.overview(platform:.chatGPT)
        store.fail("测试刷新失败")
        XCTAssertTrue(store.overview(platform:.chatGPT).detail.contains("测试刷新失败"))
        XCTAssertEqual(store.overview(platform:.chatGPT).today,overview.today)
        store.clear()
        XCTAssertTrue(store.period(days:30,now:now).buckets.isEmpty)
        XCTAssertEqual(store.overview(platform:.chatGPT).today,"—")
    }

    func testFastDateParsingPreservesStrictValidationAndLeapDays() {
        for day in ["2026-02-29","2026-04-31","2026-00-01","2026-13-01","2026-01-00","2026-1-01","2026/01/01","２０２６-01-01","0000-01-01"] {
            XCTAssertNil(UsageAnalysisMath.date(day),day)
        }
        let leap=UsageAnalysisMath.date("2024-02-29")
        XCTAssertNotNil(leap)
        XCTAssertEqual(leap.map {UsageAnalysisMath.day($0,timezone:"UTC")},"2024-02-29")
    }

}
