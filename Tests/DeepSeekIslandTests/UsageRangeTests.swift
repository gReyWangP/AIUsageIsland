import XCTest
@testable import DeepSeekIsland

final class UsageRangeTests: XCTestCase {
    func testTodaySevenDaysAndMonthUseLocalCalendarBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 15)))
        let ranges = UsageRanges(now: now, calendar: calendar)
        XCTAssertEqual(ranges.today.start, calendar.date(from: DateComponents(year: 2026, month: 9, day: 29)))
        XCTAssertEqual(ranges.today.end, calendar.date(from: DateComponents(year: 2026, month: 9, day: 30)))
        XCTAssertEqual(ranges.sevenDays.start, calendar.date(from: DateComponents(year: 2026, month: 9, day: 23)))
        XCTAssertEqual(ranges.sevenDays.end, ranges.today.end)
        XCTAssertEqual(ranges.month.start, calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        XCTAssertEqual(ranges.month.end, calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        XCTAssertEqual(ranges.timezoneOffset, 28_800)
    }

    func testDateRangeURLUsesExclusiveEndAndTimezone() throws {
        let range = UsageRange(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        let url = try XCTUnwrap(range.url(kind: "amount", timezoneOffset: 28_800))
        XCTAssertEqual(url.host, "platform.deepseek.com")
        XCTAssertEqual(url.path, "/api/v0/usage/by_api_key/amount")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "start" })?.value, "100")
        XCTAssertEqual(query.first(where: { $0.name == "end" })?.value, "200")
        XCTAssertEqual(query.first(where: { $0.name == "tz" })?.value, "28800")
    }

    func testOfficialSummarySeparatesTodaySevenDaysAndMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 15)))
        let ranges = UsageRanges(now: now, calendar: calendar)
        func stamp(_ day: Int) -> Int64 {
            Int64(calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 12))!.timeIntervalSince1970)
        }
        let summary = OfficialUsageSummary(
            amount: [stamp(1): 10, stamp(23): 20, stamp(29): 30],
            cost: [stamp(1): 1, stamp(23): 2, stamp(29): 3],
            ranges: ranges
        )
        XCTAssertEqual(summary.today.tokens, 30)
        XCTAssertEqual(summary.sevenDays.tokens, 50)
        XCTAssertEqual(summary.month.tokens, 60)
        XCTAssertEqual(summary.today.cost, 3)
        XCTAssertEqual(summary.sevenDays.cost, 5)
        XCTAssertEqual(summary.month.cost, 6)
    }
}
