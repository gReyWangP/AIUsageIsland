import XCTest
@testable import DeepSeekIsland

final class OAuthTests: XCTestCase {
    func testCallbackAcceptsCodeWithMatchingState() throws {
        let line = "GET /oauth/callback?state=known&code=abc123 HTTP/1.1"
        XCTAssertEqual(try OAuthCallback.code(from: line, expectedState: "known"), "abc123")
    }

    func testCallbackRejectsMismatchedOrDuplicateState() {
        XCTAssertThrowsError(try OAuthCallback.code(from: "GET /oauth/callback?state=wrong&code=abc HTTP/1.1", expectedState: "known"))
        XCTAssertThrowsError(try OAuthCallback.code(from: "GET /oauth/callback?state=known&state=known&code=abc HTTP/1.1", expectedState: "known"))
    }

    func testPKCEChallengeUsesSHA256Base64URL() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @MainActor
    func testLoopbackServerReceivesValidatedCode() async throws {
        let server = LoopbackCallbackServer(expectedState: "known")
        let callback = try await server.start()
        defer { server.stop() }
        var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "state", value: "known"),
            URLQueryItem(name: "code", value: "abc123")
        ]
        let browser = Task { try await URLSession.shared.data(from: components.url!) }
        let code = try await server.waitForCode()
        XCTAssertEqual(code, "abc123")
        server.complete()
        let (page, response) = try await browser.value
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let html = String(decoding: page, as: UTF8.self)
        XCTAssertTrue(html.contains("deepseekisland://open"))
        XCTAssertTrue(html.contains("打开应用"))
    }
}
