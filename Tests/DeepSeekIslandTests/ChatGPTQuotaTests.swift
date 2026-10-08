import XCTest
@testable import DeepSeekIsland

/// ChatGPT 额度解析。
///
/// 样例来自真实账号的脱敏响应（`GET /backend-api/wham/usage`），字段名和类型都按实测写，
/// 尤其是「窗口含义不能按 primary/secondary 槽位硬编码」这条。
final class ChatGPTQuotaTests: XCTestCase {

    private let realSample = """
    {
      "user_id": "user-XXXXXXXX",
      "account_id": "00000000-0000-0000-0000-000000000000",
      "email": "user@example.com",
      "plan_type": "plus",
      "rate_limit": {
        "allowed": false,
        "limit_reached": true,
        "primary_window": {
          "used_percent": 100,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 8295,
          "reset_at": 1790832064
        },
        "secondary_window": {
          "used_percent": 63,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 451393,
          "reset_at": 1791275163
        }
      },
      "credits": { "has_credits": false, "balance": "0" }
    }
    """

    private func parse(_ json: String) throws -> ChatGPTQuota {
        try ChatGPTQuotaParser.parse(Data(json.utf8))
    }

    func testProWithOnlyWeeklyWindowKeepsWeekSeparateFromFiveHours() throws {
        let quota = try parse(#"{"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":null,"secondary_window":{"used_percent":42,"limit_window_seconds":604800,"reset_at":1791275163}}}"#)
        XCTAssertNil(quota.session)
        XCTAssertEqual(quota.weekly?.windowSeconds, 604800)
        XCTAssertEqual(quota.weekly?.usedPercent, 42)
    }

    func testMalformedProFiveHourWindowDoesNotBecomeUnlimited() {
        let json = #"{"plan_type":"pro","rate_limit":{"primary_window":{"limit_window_seconds":18000},"secondary_window":{"used_percent":42,"limit_window_seconds":604800}}}"#
        XCTAssertThrowsError(try parse(json))
    }

    func testProFiniteFiveHourWindowUsesActualReturnedAllowance() throws {
        let quota = try parse(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":23,"limit_window_seconds":18000},"secondary_window":{"used_percent":42,"limit_window_seconds":604800}}}"#)
        XCTAssertFalse(quota.hasUnlimitedFiveHour)
        XCTAssertEqual(quota.session?.usedPercent, 23)
        XCTAssertEqual(quota.weekly?.usedPercent, 42)
    }

    func testProNullRateLimitDoesNotImplyUnlimitedAllowance() {
        XCTAssertThrowsError(try parse(#"{"plan_type":"pro","rate_limit":null}"#))
    }

    func testRejectsUnrepresentableWindowLength() {
        for seconds in ["Infinity", "1e309", "1e30", "0.5"] {
            let json = "{\"plan_type\":\"pro\",\"rate_limit\":{\"primary_window\":{\"used_percent\":20,\"limit_window_seconds\":\"\(seconds)\"}}}"
            XCTAssertThrowsError(try parse(json))
        }
    }

    func testParsesRealSample() throws {
        let quota = try parse(realSample)
        XCTAssertEqual(quota.planType, "plus")
        XCTAssertEqual(quota.planName, "ChatGPT Plus")
        XCTAssertEqual(quota.email, "user@example.com")
        XCTAssertEqual(quota.accountID, "00000000-0000-0000-0000-000000000000")
        XCTAssertTrue(quota.limitReached)

        let session = try XCTUnwrap(quota.session)
        XCTAssertEqual(session.windowSeconds, 18_000)
        XCTAssertEqual(session.usedPercent, 100)
        XCTAssertEqual(session.label, "5 小时")
        XCTAssertEqual(session.resetAt, Date(timeIntervalSince1970: 1_790_832_064))

        let weekly = try XCTUnwrap(quota.weekly)
        XCTAssertEqual(weekly.windowSeconds, 604_800)
        XCTAssertEqual(weekly.usedPercent, 63)
        XCTAssertEqual(weekly.label, "本周")
        XCTAssertEqual(weekly.resetAt, Date(timeIntervalSince1970: 1_791_275_163))
    }

    /// 槽位名不代表窗口长度：反着放也要认出来。
    func testClassifiesWindowsByLengthNotBySlot() throws {
        let swapped = """
        { "plan_type": "plus",
          "rate_limit": {
            "primary_window": { "used_percent": 63, "limit_window_seconds": 604800, "reset_at": 1791275163 },
            "secondary_window": { "used_percent": 100, "limit_window_seconds": 18000, "reset_at": 1790832064 } } }
        """
        let quota = try parse(swapped)
        XCTAssertEqual(quota.session?.windowSeconds, 18_000)
        XCTAssertEqual(quota.session?.usedPercent, 100)
        XCTAssertEqual(quota.weekly?.windowSeconds, 604_800)
        XCTAssertEqual(quota.weekly?.usedPercent, 63)
    }

    /// Team 账号返回的是周 + 月窗口，名字要跟着窗口长度走。
    func testMonthlyWindowGetsItsOwnLabel() throws {
        let team = """
        { "plan_type": "business",
          "rate_limit": {
            "primary_window": { "used_percent": 20, "limit_window_seconds": 604800, "reset_at": 1791275163 },
            "secondary_window": { "used_percent": 40, "limit_window_seconds": 2592000, "reset_at": 1793875163 } } }
        """
        let quota = try parse(team)
        XCTAssertEqual(quota.session?.label, "本周")
        XCTAssertEqual(quota.weekly?.label, "本月")
        XCTAssertEqual(quota.planName, "ChatGPT Business")
    }

    func testSingleWindowStillParses() throws {
        let single = """
        { "plan_type": "pro",
          "rate_limit": { "primary_window": { "used_percent": 12, "limit_window_seconds": 18000, "reset_at": 1790832064 } } }
        """
        let quota = try parse(single)
        XCTAssertEqual(quota.session?.usedPercent, 12)
        XCTAssertNil(quota.weekly)
        XCTAssertEqual(quota.planName, "ChatGPT Pro")
    }

    /// 免费账号的 rate_limit 是 null——这是「没有额度」，不是解析失败。
    func testNullRateLimitReportsNoQuota() {
        XCTAssertThrowsError(try parse(#"{ "plan_type": "free", "rate_limit": null }"#)) { error in
            guard case ChatGPTQuotaError.noQuota = error else {
                return XCTFail("应报 noQuota，实际 \(error)")
            }
        }
    }

    func testUnauthorizedResponseReportsAuthorization() {
        XCTAssertThrowsError(try parse(#"{ "detail": "Unauthorized" }"#)) { error in
            guard case ChatGPTQuotaError.authorization = error else {
                return XCTFail("应报 authorization，实际 \(error)")
            }
        }
    }

    func testUsedPercentIsClampedAndMissingResetTolerated() throws {
        let odd = """
        { "plan_type": "plus",
          "rate_limit": { "primary_window": { "used_percent": 130, "limit_window_seconds": 18000 } } }
        """
        let quota = try parse(odd)
        XCTAssertEqual(quota.session?.usedPercent, 100)
        XCTAssertNil(quota.session?.resetAt)
    }

    func testPlanNameFallsBackWhenPlanMissing() throws {
        let bare = """
        { "rate_limit": { "primary_window": { "used_percent": 1, "limit_window_seconds": 18000 } } }
        """
        XCTAssertEqual(try parse(bare).planName, "ChatGPT")
    }

    func testWindowLabels() {
        func label(_ seconds: Int) -> String {
            ChatGPTQuota.Window(windowSeconds: seconds, usedPercent: 0, resetAt: nil).label
        }
        XCTAssertEqual(label(18_000), "5 小时")
        XCTAssertEqual(label(604_800), "本周")
        XCTAssertEqual(label(86_400), "今日")
        XCTAssertEqual(label(2_592_000), "本月")
        XCTAssertEqual(label(172_800), "2 天")
        XCTAssertEqual(label(3_600), "1 小时")
    }
}

/// 授权地址与令牌解析。
final class ChatGPTAuthTests: XCTestCase {

    func testAuthorizeURLMatchesCodexClientRequirements() throws {
        let url = try XCTUnwrap(ChatGPTOAuth.authorizeURL(
            challenge: "challenge-value",
            state: "state-value",
            redirectURI: "http://127.0.0.1:1455/auth/callback"))
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(url.path, "/oauth/authorize")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("client_id"), ChatGPTAccountClient.clientID)
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge"), "challenge-value")
        XCTAssertEqual(value("state"), "state-value")
        XCTAssertEqual(value("redirect_uri"), "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(value("scope"), ChatGPTAccountClient.scope)
    }

    /// 回调端口必须落在 Codex CLI 的白名单里，否则授权页会直接拒绝。
    func testCallbackPortsAreTheAllowListedOnes() {
        XCTAssertEqual(ChatGPTOAuth.callbackPorts, [1455, 1457])
        XCTAssertEqual(ChatGPTOAuth.callbackPath, "/auth/callback")
    }

    func testCallbackPathIsConfigurable() throws {
        let line = "GET /auth/callback?code=abc&state=xyz HTTP/1.1"
        XCTAssertEqual(try OAuthCallback.code(from: line, expectedState: "xyz",
                                              path: "/auth/callback"), "abc")
        // 路径不符要拒绝：DeepSeek 用的是 /oauth/callback。
        XCTAssertThrowsError(try OAuthCallback.code(from: line, expectedState: "xyz"))
        XCTAssertThrowsError(try OAuthCallback.code(from: line, expectedState: "wrong",
                                                    path: "/auth/callback"))
    }

    func testAccountIDIsReadFromJWTClaims() throws {
        let claims = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-123"}}"#
        let token = "header.\(base64URL(claims)).signature"
        XCTAssertEqual(JWTClaim.accountID(in: token), "acct-123")
        XCTAssertNil(JWTClaim.accountID(in: "not-a-jwt"))
        XCTAssertNil(JWTClaim.accountID(in: nil))
    }

    private func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// 本机回调服务器的真实往返：固定端口 + 自定义路径是 ChatGPT 登录新增的能力，
/// 不能只靠 `OAuthCallback` 的字符串解析来证明。
@MainActor
final class LoopbackCallbackServerTests: XCTestCase {

    func testFixedPortAndCustomPathReceiveCode() async throws {
        // 不占用 1455/1457，避免和真实登录或 Codex CLI 抢端口；这里验证的是
        // 「固定端口 + 自定义路径」这条链路本身。
        let port: UInt16 = 45999
        let state = "state-\(UUID().uuidString)"
        let server = LoopbackCallbackServer(expectedState: state, path: "/auth/callback", port: port)
        defer { server.stop() }
        let url = try await server.start()
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:\(port)/auth/callback")
        XCTAssertEqual(server.redirectURI, url)

        let received = Task { try await server.waitForCode() }
        let callback = URL(string: "http://127.0.0.1:\(port)/auth/callback?code=CODE-123&state=\(state)")!
        // 不能在这里等响应：回调连接是**故意**挂着的——应用要先拿 code 去换令牌，
        // 换完才用成功页回应浏览器。所以只发请求，不回等。
        let task = URLSession.shared.dataTask(with: callback)
        task.resume()
        defer { task.cancel() }
        let code = try await received.value
        XCTAssertEqual(code, "CODE-123")
        server.complete(title: "已连接 ChatGPT 账号")
    }

    func testPortConflictSurfacesAsError() async throws {
        let port: UInt16 = 45998
        let first = LoopbackCallbackServer(expectedState: "a", path: "/auth/callback", port: port)
        _ = try await first.start()
        defer { first.stop() }
        let second = LoopbackCallbackServer(expectedState: "b", path: "/auth/callback", port: port)
        defer { second.stop() }
        do {
            _ = try await second.start()
            XCTFail("同一端口第二次监听应当失败，登录流程才能退到备用端口")
        } catch {
            // 预期：端口被占用。
        }
    }
}
