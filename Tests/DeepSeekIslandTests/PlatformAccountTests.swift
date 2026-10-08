import XCTest
@testable import DeepSeekIsland

final class PlatformAccountTests: XCTestCase {
    func testProfilePrefersNameOverContact() throws {
        let json = #"{"code":0,"data":{"biz_code":0,"biz_data":{"email":"g***@example.com","mobile":"138****1234","id_profile":{"name":"小灰","picture":null}}}}"#
        let profile = try PlatformAccountClient.decodeProfile(Data(json.utf8))
        XCTAssertEqual(profile.displayName, "小灰")
    }

    func testProfileFallsBackToContactWhenNameMissing() throws {
        let json = #"{"code":0,"data":{"biz_code":0,"biz_data":{"email":"g***@example.com","id_profile":{"name":null}}}}"#
        let profile = try PlatformAccountClient.decodeProfile(Data(json.utf8))
        XCTAssertEqual(profile.displayName, "g***@example.com")
    }

    func testProfileRejectsResponseWithoutIdentity() {
        let json = #"{"code":0,"data":{"biz_code":0,"biz_data":{}}}"#
        XCTAssertThrowsError(try PlatformAccountClient.decodeProfile(Data(json.utf8)))
    }

    func testProfileUsesStableUserIDWhenContactsAreMasked() throws {
        let json = #"{"code":0,"data":{"biz_code":0,"biz_data":{"user_id":"customer-123","email":"g***@example.com","id_profile":{"name":"小灰"}}}}"#
        let profile = try PlatformAccountClient.decodeProfile(Data(json.utf8))
        XCTAssertEqual(profile.identity, "user:customer-123")
    }

    func testProfileAcceptsNumericIDWithoutLosingPrecision() throws {
        let json = #"{"code":0,"data":{"biz_code":0,"biz_data":{"id":9007199254740993,"mobile":"138****1234"}}}"#
        let profile = try PlatformAccountClient.decodeProfile(Data(json.utf8))
        XCTAssertEqual(profile.identity, "user:9007199254740993")
    }

    func testAccountSummaryCombinesRechargeAndBonusWallets() throws {
        let json = #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"100.25"}],"bonus_wallets":[{"currency":"CNY","balance":"9.75"}]}}}"#
        let summary = try PlatformAccountClient.decodeSummary(Data(json.utf8))
        XCTAssertEqual(summary.balances["CNY"], Decimal(110))
    }

    func testAccountSummaryAcceptsScientificZeroBalance() throws {
        let json = #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"0E-16"}],"bonus_wallets":[]}}}"#
        let summary = try PlatformAccountClient.decodeSummary(Data(json.utf8))
        XCTAssertEqual(summary.balances["CNY"], .zero)
    }

    func testBusinessFailureDoesNotBecomeZeroBalance() {
        let json = #"{"code":0,"data":{"biz_code":40003,"biz_data":{}}}"#
        XCTAssertThrowsError(try PlatformAccountClient.decodeSummary(Data(json.utf8)))
    }

    func testAuthorizationFailureIsClassifiedAsExpired() {
        let json = #"{"code":40003,"data":{}}"#
        XCTAssertThrowsError(try PlatformAccountClient.decodeSummary(Data(json.utf8))) { error in
            guard case PlatformError.expired = error else {
                return XCTFail("Expected expired account authorization")
            }
        }
    }

    func testAuthorizationUrlRequiresOfficialOriginAndPath() {
        XCTAssertNoThrow(try PlatformAccountClient.validateAuthorizeURL("https://platform.deepseek.com/dsh/authorize?id=1"))
        XCTAssertThrowsError(try PlatformAccountClient.validateAuthorizeURL("https://other.example/dsh/authorize?id=1"))
        XCTAssertThrowsError(try PlatformAccountClient.validateAuthorizeURL("https://platform.deepseek.com/evil"))
    }

    func testUsageAmountCountsOnlyTokenTypesAcrossKeysAndModels() throws {
        let json = #"""
        {"code":0,"data":{"biz_code":0,"biz_data":{"series":[
          {"model":"a","api_key":{"name":"first"},"buckets":[
            {"time":100,"usage":{"PROMPT_CACHE_HIT_TOKEN":"10","PROMPT_CACHE_MISS_TOKEN":"20","RESPONSE_TOKEN":"5","REQUEST":"3"}},
            {"time":200,"usage":{"RESPONSE_TOKEN":"999"}}]},
          {"model":"b","api_key":{"name":"second"},"buckets":[
            {"time":100,"usage":{"PROMPT_CACHE_HIT_TOKEN":"2","RESPONSE_TOKEN":"8","REQUEST":"1"}}]}
        ]}}}
        """#
        let buckets = try PlatformAccountClient.decodeAmount(Data(json.utf8))
        XCTAssertEqual(buckets[100], 45)
        XCTAssertEqual(buckets[200], 999)
    }

    func testUsageCostAddsEverySeriesInChosenCurrency() throws {
        let json = #"""
        {"code":0,"data":{"biz_code":0,"biz_data":{"data":[
          {"currency":"CNY","series":[
            {"buckets":[{"time":100,"cost":"1.25"},{"time":200,"cost":"8.00"}]},
            {"buckets":[{"time":100,"cost":"0.75"}]}]},
          {"currency":"USD","series":[{"buckets":[{"time":100,"cost":"20.00"}]}]}
        ]}}}
        """#
        let buckets = try PlatformAccountClient.decodeCost(Data(json.utf8), currency: "CNY")
        XCTAssertEqual(buckets[100], Decimal(2))
        XCTAssertEqual(buckets[200], Decimal(8))
    }

    func testUsageMalformedPayloadFailsInsteadOfShowingZero() {
        let json = #"""{"code":0,"data":{"biz_code":0,"biz_data":{}}}"""#
        XCTAssertThrowsError(try PlatformAccountClient.decodeAmount(Data(json.utf8)))
    }

    func testUnknownTokenCategoryDoesNotSilentlyBecomeZero() {
        let json = #"""{"code":0,"data":{"biz_code":0,"biz_data":{"series":[{"buckets":[{"time":100,"usage":{"PROMPT_TOKEN":"99","REQUEST":"1"}}]}]}}}"""#
        XCTAssertThrowsError(try PlatformAccountClient.decodeAmount(Data(json.utf8)))
    }
}
