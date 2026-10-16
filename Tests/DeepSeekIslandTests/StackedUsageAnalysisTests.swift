import XCTest
@testable import DeepSeekIsland

final class StackedUsageAnalysisTests: XCTestCase {
    private let now = UsageAnalysisMath.date("2026-10-16")!.addingTimeInterval(12 * 3600)

    func testStacksAccountsSeparatelyWithoutCountingDuplicateInputs() throws {
        let deepSeek = account(.deepSeek)
        let inputs = [
            input(account: deepSeek, day: "2026-10-15", tokens: 100),
            input(account: deepSeek, day: "2026-10-15", tokens: 100),
            input(account: account(.deepSeek), day: "2026-10-15", tokens: 40),
            input(account: account(.chatGPT), day: "2026-10-15", tokens: 30),
            input(account: account(.zhipu), day: "2026-10-15", tokens: 20)
        ]
        let period = StackedUsagePeriod(inputs: inputs, days: 7, now: now)
        let day = try XCTUnwrap(period.buckets.first { $0.day == "2026-10-15" })
        XCTAssertEqual(period.platforms, [.deepSeek, .zhipu, .chatGPT])
        XCTAssertEqual(day.segments.map(\.tokens), [100, 40, 30, 20])
        XCTAssertEqual(day.segments.map(\.lower), [0, 100, 140, 170])
        XCTAssertEqual(day.segments.map(\.upper), [100, 140, 170, 190])
        XCTAssertEqual(day.segments.first?.returnedAccounts, 1)
        XCTAssertEqual(day.segments.first?.expectedAccounts, 1)
        XCTAssertEqual(day.totalTokens, 190)
        XCTAssertEqual(period.totalTokens, 190)
        XCTAssertEqual(period.completeDays, 1)
    }

    func testDeduplicationUsesNewestSnapshotAndDoesNotLetNilEraseIt() throws {
        let deepSeek = account(.deepSeek)
        let old = input(account: deepSeek, day: "2026-10-15", tokens: 100, updatedAt: now.addingTimeInterval(-60))
        let latest = input(account: deepSeek, day: "2026-10-15", tokens: 200)
        for inputs in [[old, latest, .init(account: deepSeek, snapshot: nil)], [latest, old]] {
            let period = StackedUsagePeriod(inputs: inputs, days: 7, now: now)
            XCTAssertEqual(period.totalTokens, 200)
        }
    }

    func testMissingDatesStayUnknownWhileOfficialZeroIsPreserved() throws {
        let inputs = [input(account: account(.deepSeek), day: "2026-10-15", tokens: 0),
                      StackedUsageInput(account: account(.chatGPT), snapshot: nil)]
        let period = StackedUsagePeriod(inputs: inputs, days: 7, now: now)
        let zero = try XCTUnwrap(period.buckets.first { $0.day == "2026-10-15" })
        XCTAssertEqual(period.buckets.count, 7)
        XCTAssertEqual(zero.totalTokens, 0)
        XCTAssertEqual(zero.segments.count, 1)
        XCTAssertEqual(zero.missingAccounts, 1)
        XCTAssertTrue(zero.isPartial)
        XCTAssertFalse(zero.segments[0].isPartial, "The returned platform can be complete while another is absent")
        XCTAssertNil(period.buckets.first?.totalTokens)
        XCTAssertEqual(period.buckets.first?.missingAccounts, 2)
        XCTAssertEqual(period.totalTokens, 0)
        XCTAssertEqual(period.completeDays, 0)
    }

    func testPartialAndCachedFlagsPropagatePerPlatform() throws {
        let partial = input(account: account(.deepSeek), day: "2026-10-15", tokens: 10, partial: true)
        let cached = input(account: account(.deepSeek), day: "2026-10-15", tokens: 20, cached: true)
        let missing = StackedUsageInput(account: account(.zhipu), snapshot: nil)
        let period = StackedUsagePeriod(inputs: [partial, cached, missing], days: 7, now: now)
        let day = try XCTUnwrap(period.buckets.first { $0.day == "2026-10-15" })
        XCTAssertTrue(day.isPartial)
        XCTAssertTrue(day.isCached)
        XCTAssertTrue(day.segments[0].isPartial)
        XCTAssertTrue(day.segments[1].isCached)
        XCTAssertEqual(day.segments[0].returnedAccounts, 1)
        XCTAssertEqual(day.missingAccounts, 1)
        XCTAssertEqual(day.totalTokens, 30)
    }

    func testUsesOriginalDayLabelsWithoutPretendingTimezoneConversion() throws {
        let clock = UsageAnalysisMath.date("2026-10-15")!.addingTimeInterval(17 * 3600)
        let inputs = [input(account: account(.deepSeek), day: "2026-10-16", tokens: 5, timezone: "Asia/Shanghai"),
                      input(account: account(.chatGPT), day: "2026-10-15", tokens: 7, timezone: "UTC")]
        let period = StackedUsagePeriod(inputs: inputs, days: 7, now: clock)
        XCTAssertEqual(period.buckets.last?.day, "2026-10-16")
        XCTAssertEqual(period.buckets.last?.totalTokens, 5)
        XCTAssertEqual(period.buckets.first { $0.day == "2026-10-15" }?.totalTokens, 7)
        XCTAssertTrue(period.buckets.last?.isPartial == true)
        XCTAssertEqual(period.dateDomain.upperBound, UsageAnalysisMath.date("2026-10-17"))
    }

    func testOverflowNeverWrapsOrShowsAnIncompleteStackAsTheFullTotal() throws {
        let samePlatform = [input(account: account(.deepSeek), day: "2026-10-15", tokens: Int64.max),
                            input(account: account(.deepSeek), day: "2026-10-15", tokens: 1)]
        let crossPlatform = [input(account: account(.deepSeek), day: "2026-10-15", tokens: Int64.max),
                             input(account: account(.chatGPT), day: "2026-10-15", tokens: 1)]
        for inputs in [samePlatform, crossPlatform] {
            let period = StackedUsagePeriod(inputs: inputs, days: 7, now: now)
            let day = try XCTUnwrap(period.buckets.first { $0.day == "2026-10-15" })
            XCTAssertNil(day.totalTokens)
            XCTAssertTrue(day.hasOverflow)
            XCTAssertTrue(day.segments.isEmpty)
            XCTAssertTrue(day.isPartial)
            XCTAssertNil(period.totalTokens)
            XCTAssertTrue(period.hasOverflow)
        }
        let account = account(.deepSeek)
        var snapshot = try XCTUnwrap(input(account: account, day: "2026-10-15", tokens: Int64.max).snapshot)
        snapshot.buckets.append(.init(day: "2026-10-14", tokens: 1))
        let period = StackedUsagePeriod(inputs: [.init(account: account, snapshot: snapshot)], days: 7, now: now)
        XCTAssertNil(period.totalTokens)
        XCTAssertTrue(period.hasOverflow)
        XCTAssertFalse(period.buckets.contains(where: \.hasOverflow), "Individual days still fit")
    }

    func testInvalidAccountSourceAndInvalidBucketsCannotContaminateTotals() throws {
        let chatGPT = account(.chatGPT)
        var mismatch = try XCTUnwrap(input(account: account(.deepSeek), day: "2026-10-15", tokens: 5).snapshot)
        let invalid = UsageAnalysisSnapshot(source: .deepSeek, buckets: [.init(day: "2026-10-15", tokens: -1)])
        let period = StackedUsagePeriod(inputs: [.init(account: chatGPT, snapshot: mismatch),
                                                 .init(account: account(.deepSeek), snapshot: invalid)], days: 7, now: now)
        XCTAssertNil(period.totalTokens)
        XCTAssertTrue(period.buckets.allSatisfy { $0.missingAccounts == 2 })
        mismatch.buckets = []
        XCTAssertNil(StackedUsagePeriod(inputs: [], days: 7, now: now).totalTokens)
    }

    private func account(_ platform: UsagePlatform) -> AccountReference {
        .init(platform: platform, profileID: UUID())
    }

    private func input(account: AccountReference, day: String, tokens: Int64,
                       timezone: String = "UTC", partial: Bool = false, cached: Bool = false,
                       updatedAt: Date? = nil) -> StackedUsageInput {
        let source: UsageAnalysisSource = switch account.platform {
        case .deepSeek: .deepSeek
        case .chatGPT: .chatGPT
        case .zhipu: .zhipu
        }
        let bucket = DailyUsageBucket(day: day, tokens: tokens, isPartial: partial, isCached: cached)
        return .init(account: account, snapshot: .init(source: source, buckets: [bucket],
                                                      updatedAt: updatedAt ?? now, timezone: timezone))
    }
}
