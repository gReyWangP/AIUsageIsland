import Foundation

@MainActor
protocol AntigravityCloudAuthorizing: AnyObject {
    func signIn() async throws -> AntigravityCloudGrant
    func cancel()
}

@MainActor
final class AntigravityCloudAuthFlow: AntigravityCloudAuthorizing {
    private let client: AntigravityCloudClient
    private let browserFactory: @MainActor () -> any OAuthBrowserPresenting
    private var activeBrowser: (any OAuthBrowserPresenting)?
    private var activeServer: LoopbackCallbackServer?
    private var generation = 0

    init(client: AntigravityCloudClient,
         browserFactory: @escaping @MainActor () -> any OAuthBrowserPresenting = { IsolatedOAuthBrowser() }) {
        self.client = client
        self.browserFactory = browserFactory
    }

    func cancel() {
        generation += 1
        activeServer?.stop(); activeServer = nil
        activeBrowser?.cancel(); activeBrowser = nil
    }

    func signIn() async throws -> AntigravityCloudGrant {
        cancel()
        let version = generation
        guard let oauthClient = await Task.detached(priority: .utility, operation: {
            AntigravityOAuthConfig.resolvedClient()
        }).value else {
            throw AntigravityCloudError.oauthClientUnavailable
        }
        guard generation == version, !Task.isCancelled else { throw PlatformError.cancelled }
        let verifier = try PKCE.randomURLSafeString()
        let state = try PKCE.randomURLSafeString()
        let server = LoopbackCallbackServer(expectedState: state, path: "/callback")
        activeServer = server
        let browser = browserFactory()
        activeBrowser = browser
        defer {
            server.stop(); browser.cancel()
            if activeServer === server { activeServer = nil }
            if activeBrowser === browser { activeBrowser = nil }
        }
        let callbackURL = try await server.start()
        guard generation == version else { throw PlatformError.cancelled }
        let redirectURI = callbackURL.absoluteString
        guard let authorizeURL = Self.authorizationURL(
            clientID: oauthClient.clientID,
            redirectURI: redirectURI,
            state: state,
            challenge: PKCE.challenge(for: verifier)) else {
            throw AntigravityCloudError.invalidResponse
        }
        var browserCancelled = false
        let cancelAttempt: @MainActor () -> Void = {
            browserCancelled = true
            server.stop()
        }
        try browser.start(url: authorizeURL, onCancel: cancelAttempt)
        let timeout = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(300))
                cancelAttempt()
            } catch {}
        }
        defer { timeout.cancel() }
        let code = try await server.waitForCode()
        do {
            let grant = try await client.exchange(code: code, verifier: verifier,
                                                  redirectURI: redirectURI, oauthClient: oauthClient)
            guard generation == version, !browserCancelled, !Task.isCancelled else { throw PlatformError.cancelled }
            guard client.store.saveAntigravityCloudGrant(grant) else { throw AntigravityCloudError.invalidResponse }
            server.complete(title: "已连接 Antigravity 账号")
            return grant
        } catch {
            server.complete(success: false)
            throw error
        }
    }

    nonisolated static func authorizationURL(clientID: String, redirectURI: String,
                                             state: String, challenge: String) -> URL? {
        var components = URLComponents(url: AntigravityOAuthConfig.authURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AntigravityOAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components?.url
    }
}
