import XCTest
@testable import DeepSeekIsland

final class ZhipuQuotaTests: XCTestCase {
    func testCreditWindowsUseFiveHourAndWeeklyPercentages() throws {
        let response = #"{"code":200,"success":true,"data":{"level":"PRO","limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":12.5,"currentValue":"1500","usage":"12000","nextResetTime":1790660000000},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":40,"currentValue":24000,"usage":60000,"nextResetTime":1790800000000},{"type":"TIME_LIMIT","unit":5,"percentage":90}]}}"#
        let quota = try ZhipuQuotaParser.parse(Data(response.utf8))
        XCTAssertEqual(quota.kind, .credits)
        XCTAssertEqual(quota.level, "PRO")
        XCTAssertEqual(quota.fiveHour.usedPercent, 12.5)
        XCTAssertEqual(quota.fiveHour.usedValue, Decimal(1500))
        XCTAssertEqual(quota.week?.usedPercent, 40)
        XCTAssertEqual(quota.week?.limitValue, Decimal(60000))
    }

    func testLegacyTokenWindowsAreNotMislabelledAsCredits() throws {
        let response = #"{"code":0,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"percentage":18},{"type":"TOKENS_LIMIT","unit":6,"percentage":31}]}}"#
        let quota = try ZhipuQuotaParser.parse(Data(response.utf8))
        XCTAssertEqual(quota.kind, .tokens)
        XCTAssertEqual(quota.fiveHour.usedPercent, 18)
        XCTAssertNil(quota.fiveHour.usedValue)
    }

    func testV1WithoutWeeklyWindowIsAcceptedAndAuthErrorIsRejected() throws {
        let missing = #"{"code":200,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"percentage":20}]}}"#
        let auth = #"{"code":1001,"success":false,"msg":"unauthorized"}"#
        let quota = try ZhipuQuotaParser.parse(Data(missing.utf8))
        XCTAssertEqual(quota.fiveHour.usedPercent, 20)
        XCTAssertNil(quota.week)
        XCTAssertThrowsError(try ZhipuQuotaParser.parse(Data(auth.utf8)))
    }

    func testMalformedWeeklyWindowIsNotTreatedAsNoWeeklyLimit() {
        let response = #"{"code":200,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"percentage":20},{"type":"CREDIT_LIMIT","unit":6}]}}"#
        XCTAssertThrowsError(try ZhipuQuotaParser.parse(Data(response.utf8)))
    }

    func testSavedDeepSeekSessionWinsOnlyWithoutExplicitSelection() {
        XCTAssertEqual(UsagePlatform.restore(saved: nil, hasDeepSeekGrant: true), .deepSeek)
        XCTAssertEqual(UsagePlatform.restore(saved: "zhipu", hasDeepSeekGrant: true), .zhipu)
        XCTAssertNil(UsagePlatform.restore(saved: nil, hasDeepSeekGrant: false))
    }
}
