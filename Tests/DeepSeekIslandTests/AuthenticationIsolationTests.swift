import AuthenticationServices
import XCTest
import WebKit
@testable import DeepSeekIsland

@MainActor
private final class FakeEphemeralSession: EphemeralAuthenticationSession {
    var prefersEphemeralWebBrowserSession = false
    var startResult = true
    var onStart: (() -> Void)?
    var cancelCount = 0
    func start() -> Bool { onStart?(); return startResult }
    func cancel() { cancelCount += 1 }
}

@MainActor
private final class CallbackTestBrowser: OAuthBrowserPresenting {
    var cancelCount = 0
    var cancelImmediately = false
    var onCancel: (@MainActor () -> Void)?
    var callbackTask: Task<Void, Never>?
    func start(url: URL, onCancel: @escaping @MainActor () -> Void) throws {
        self.onCancel = onCancel
        if cancelImmediately { onCancel(); return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let redirect = query.first { $0.name == "redirect_uri" }!.value!
        let state = query.first { $0.name == "state" }!.value!
        var callback = URLComponents(string: redirect)!
        callback.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "test-code")]
        let request = URLRequest(url: callback.url!, timeoutInterval: 2)
        callbackTask = Task {
            do { _ = try await URLSession.shared.data(for: request) }
            catch { onCancel() }
        }
    }
    func cancel() { cancelCount += 1 }
}

@MainActor
private final class FakeDeepSeekAuthorization: PlatformAuthServing {
    var exchanges = 0
    var holdExchange = false
    var exchangeGate: CheckedContinuation<Void, Never>?
    func initializeAuth(body: [String: String]) async throws -> AuthInitialization {
        var url = URLComponents(string: "https://platform.deepseek.com/dsh/authorize")!
        url.queryItems = [.init(name: "state", value: body["state"]), .init(name: "redirect_uri", value: body["redirect_uri"])]
        return .init(authorizeURL: url.url!.absoluteString, expiresIn: 2)
    }
    func exchangeAuth(body: [String: String]) async throws -> AuthExchange {
        XCTAssertEqual(body["code"], "test-code")
        XCTAssertFalse(body["code_verifier"]?.isEmpty ?? true)
        exchanges += 1
        if holdExchange { await withCheckedContinuation { exchangeGate = $0 } }
        return .init(token: "test-token", authorizedURL: "https://platform.deepseek.com/dsh/authorized")
    }
}

@MainActor
private final class FakeChatGPTExchange: ChatGPTTokenExchanging {
    var exchanges = 0
    var holdExchange = false
    var exchangeGate: CheckedContinuation<Void, Never>?
    func exchange(code: String, verifier: String, redirectURI: String) async throws -> ChatGPTGrant {
        XCTAssertEqual(code, "test-code")
        XCTAssertFalse(verifier.isEmpty)
        exchanges += 1
        if holdExchange { await withCheckedContinuation { exchangeGate = $0 } }
        return .init(accessToken: "test-access", refreshToken: "test-refresh", accountID: "test", savedAt: .now)
    }
}

@MainActor
final class AuthenticationIsolationTests: XCTestCase {
    func testSupportedBrowserPolicyNeverAllowsDeclaredNonEphemeralAuthentication() {
        XCTAssertTrue(IsolatedOAuthBrowser.supportsIsolation(browserID: "com.apple.Safari", authentication: true, ephemeral: nil))
        XCTAssertTrue(IsolatedOAuthBrowser.supportsIsolation(browserID: "test.browser", authentication: true, ephemeral: true))
        XCTAssertFalse(IsolatedOAuthBrowser.supportsIsolation(browserID: "test.browser", authentication: true, ephemeral: false))
        XCTAssertFalse(IsolatedOAuthBrowser.supportsIsolation(browserID: "test.browser", authentication: true, ephemeral: nil))
        XCTAssertFalse(IsolatedOAuthBrowser.supportsIsolation(browserID: nil, authentication: nil, ephemeral: nil))
        // macOS uses Safari when the default browser does not support authentication sessions.
        XCTAssertTrue(IsolatedOAuthBrowser.supportsIsolation(browserID: "test.browser", authentication: false, ephemeral: nil))
    }

    func testEphemeralFlagIsSetBeforeStartAndSessionLivesUntilCancellation() throws {
        let session = FakeEphemeralSession()
        session.onStart = { XCTAssertTrue(session.prefersEphemeralWebBrowserSession) }
        let browser = IsolatedOAuthBrowser(supportsIsolation: { true }, factory: { _, _ in session })
        try browser.start(url: URL(string: "https://example.com")!, onCancel: { XCTFail("Programmatic cleanup is not user cancellation") })
        browser.cancel()
        browser.cancel()
        XCTAssertEqual(session.cancelCount, 1)
    }

    func testUnsupportedBrowserCannotStartOrFallBackToNormalOpen() {
        var created = false
        let browser = IsolatedOAuthBrowser(supportsIsolation: { false }, factory: { _, _ in
            created = true; return FakeEphemeralSession()
        })
        XCTAssertThrowsError(try browser.start(url: URL(string: "https://example.com")!, onCancel: {}))
        XCTAssertFalse(created)
    }

    func testLateCompletionCannotCancelReplacementSession() async throws {
        var completions: [@Sendable (URL?, (any Error)?) -> Void] = []
        var sessions: [FakeEphemeralSession] = []
        let browser = IsolatedOAuthBrowser(supportsIsolation: { true }, factory: { _, completion in
            completions.append(completion)
            let session = FakeEphemeralSession(); sessions.append(session); return session
        })
        var cancelled = 0
        try browser.start(url: URL(string: "https://example.com/first")!, onCancel: { cancelled += 1 })
        try browser.start(url: URL(string: "https://example.com/second")!, onCancel: { cancelled += 1 })
        completions[0](nil, nil)
        await Task { @MainActor in }.value
        XCTAssertEqual(cancelled, 0)
        XCTAssertEqual(sessions[0].cancelCount, 1)
        completions[1](nil, nil)
        completions[1](nil, nil)
        await Task { @MainActor in }.value
        XCTAssertEqual(cancelled, 1)
    }

    func testAuthenticationCompletionFromBackgroundQueueReturnsToMainActor() async throws {
        let completed = expectation(description: "Cancellation reaches main actor")
        var callback: (@Sendable (URL?, (any Error)?) -> Void)?
        let browser = IsolatedOAuthBrowser(supportsIsolation: { true }, factory: { _, completion in
            callback = completion
            return FakeEphemeralSession()
        })
        try browser.start(url: URL(string: "https://example.com")!, onCancel: {
            MainActor.assertIsolated()
            completed.fulfill()
        })
        let backgroundCallback = try XCTUnwrap(callback)
        await Task.detached { backgroundCallback(nil, nil) }.value
        await fulfillment(of: [completed], timeout: 2)
    }

    func testStartFailureReleasesSession() {
        let session = FakeEphemeralSession(); session.startResult = false
        let browser = IsolatedOAuthBrowser(supportsIsolation: { true }, factory: { _, _ in session })
        XCTAssertThrowsError(try browser.start(url: URL(string: "https://example.com")!, onCancel: {}))
        XCTAssertEqual(session.cancelCount, 1)
    }
    func testDeepSeekUsesNewIsolatedBrowserForEveryLoginAndCleansUp() async throws {
        let client = FakeDeepSeekAuthorization()
        var browsers: [CallbackTestBrowser] = []
        let flow = PlatformAuthFlow(client: client, browserFactory: {
            let browser = CallbackTestBrowser(); browsers.append(browser); return browser
        })
        for _ in 0..<2 {
            let token = try await flow.signIn()
            XCTAssertEqual(token, "test-token")
        }
        for browser in browsers { await browser.callbackTask?.value }
        XCTAssertEqual(client.exchanges, 2)
        XCTAssertEqual(browsers.map(\.cancelCount), [1, 1])
    }

    func testChatGPTUsesIsolatedBrowserAndPreservesRegisteredCallback() async throws {
        let client = FakeChatGPTExchange(), browser = CallbackTestBrowser()
        let flow = ChatGPTAuthFlow(client: client, browserFactory: { browser })
        let timeout = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled { flow.cancel() } }
        defer { timeout.cancel() }
        let grant = try await flow.signIn()
        await browser.callbackTask?.value
        XCTAssertEqual(grant.accessToken, "test-access")
        XCTAssertEqual(client.exchanges, 1)
        XCTAssertEqual(browser.cancelCount, 1)
    }

    func testBrowserCancellationStopsCallbackWaitWithoutExchangingCredentials() async {
        let client = FakeDeepSeekAuthorization(), browser = CallbackTestBrowser()
        browser.cancelImmediately = true
        let flow = PlatformAuthFlow(client: client, browserFactory: { browser })
        do { _ = try await flow.signIn(); XCTFail("Cancelled browser cannot authorize") }
        catch { }
        XCTAssertEqual(client.exchanges, 0)
        XCTAssertEqual(browser.cancelCount, 1)
    }

    func testZhipuLegacyAndAdditionalAccountsUseDifferentExplicitStores() {
        let id = UUID()
        let legacy = ZhipuWebSession.configuration(profileID: AccountProfileEntry.legacyID)
        let other = ZhipuWebSession.configuration(profileID: id)
        XCTAssertEqual(legacy.websiteDataStore.identifier, ZhipuWebSession.storeIdentifier(for: AccountProfileEntry.legacyID))
        XCTAssertEqual(other.websiteDataStore.identifier, id)
        XCTAssertNotEqual(legacy.websiteDataStore.identifier, other.websiteDataStore.identifier)
    }

    func testZhipuCookieStoresAndCleanupAreAccountScoped() async throws {
        let leftID = UUID(), rightID = UUID()
        let left = ZhipuWebSession.configuration(profileID: leftID).websiteDataStore
        let right = ZhipuWebSession.configuration(profileID: rightID).websiteDataStore
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "isolation-test", .value: "left"]))
        await left.httpCookieStore.setCookie(cookie)
        let untouched = await right.httpCookieStore.allCookies()
        XCTAssertFalse(untouched.contains { $0.name == "isolation-test" })
        let rightCookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "isolation-test", .value: "right"]))
        await right.httpCookieStore.setCookie(rightCookie)
        ZhipuWebSession.clearStore(profileID: leftID)
        await ZhipuWebSession.waitForStoreClear(profileID: leftID)
        let cleared = await left.httpCookieStore.allCookies()
        let retained = await right.httpCookieStore.allCookies()
        XCTAssertFalse(cleared.contains { $0.name == "isolation-test" })
        XCTAssertEqual(retained.first { $0.name == "isolation-test" }?.value, "right")
        ZhipuWebSession.clearStore(profileID: rightID)
        await ZhipuWebSession.waitForStoreClear(profileID: rightID)
    }

    func testClosingBrowserDuringTokenExchangeCannotReturnCredentials() async throws {
        for useChatGPT in [false, true] {
            let deepSeek = FakeDeepSeekAuthorization(), chatGPT = FakeChatGPTExchange()
            deepSeek.holdExchange = true; chatGPT.holdExchange = true
            let browser = CallbackTestBrowser()
            let deepSeekFlow = PlatformAuthFlow(client: deepSeek, browserFactory: { browser })
            let chatGPTFlow = ChatGPTAuthFlow(client: chatGPT, browserFactory: { browser })
            let login = Task {
                if useChatGPT { _ = try await chatGPTFlow.signIn() }
                else { _ = try await deepSeekFlow.signIn() }
            }
            for _ in 0..<500 {
                if deepSeek.exchangeGate != nil || chatGPT.exchangeGate != nil { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertTrue(deepSeek.exchangeGate != nil || chatGPT.exchangeGate != nil)
            browser.onCancel?()
            deepSeek.exchangeGate?.resume(); deepSeek.exchangeGate = nil
            chatGPT.exchangeGate?.resume(); chatGPT.exchangeGate = nil
            do { try await login.value; XCTFail("Browser cancellation must invalidate exchanged credentials") }
            catch { }
            await browser.callbackTask?.value
        }
    }

}
