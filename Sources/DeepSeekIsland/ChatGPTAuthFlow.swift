import AppKit
import Foundation

/// 纯数据与 URL 拼接，和窗口/网络无关，所以不放在 `@MainActor` 的流程类里。
enum ChatGPTOAuth {
    /// Codex CLI 的 client 只允许白名单回调端口：1455，被占用时退到 1457。
    static let callbackPorts: [UInt16] = [1455, 1457]
    static let callbackPath = "/auth/callback"

    static func authorizeURL(challenge: String, state: String, redirectURI: String) -> URL? {
        var components = URLComponents(url: ChatGPTAccountClient.issuer.appending(path: "/oauth/authorize"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: ChatGPTAccountClient.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: ChatGPTAccountClient.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // 与 Codex CLI 保持一致的两个开关。
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        return components?.url
    }
}

/// ChatGPT 登录：系统临时授权会话 + PKCE + 本机回调，和 DeepSeek 一条路子。
///
/// 用的是 Codex CLI 那个公开 client，所以回调地址必须落在它的白名单端口上。
/// 自己登录换来的是自己那份 refresh token，刷新只影响自己，不会动用户的 Codex CLI 登录。
protocol ChatGPTTokenExchanging: Sendable {
    func exchange(code: String, verifier: String, redirectURI: String) async throws -> ChatGPTGrant
}

extension ChatGPTAccountClient: ChatGPTTokenExchanging {}

@MainActor protocol ChatGPTAuthorizing {
    func signIn() async throws -> ChatGPTGrant
    func cancel()
}

@MainActor
final class ChatGPTAuthFlow: ChatGPTAuthorizing {
    private let client: any ChatGPTTokenExchanging
    private let browserFactory: @MainActor () -> any OAuthBrowserPresenting
    private var activeBrowser: (any OAuthBrowserPresenting)?
    init(client: any ChatGPTTokenExchanging = ChatGPTAccountClient(),
         browserFactory: @escaping @MainActor () -> any OAuthBrowserPresenting = { IsolatedOAuthBrowser() }) {
        self.client = client; self.browserFactory = browserFactory
    }
    private var activeServer: LoopbackCallbackServer?
    private var generation = 0
    func cancel() { generation += 1; activeServer?.stop(); activeServer = nil; activeBrowser?.cancel(); activeBrowser = nil }

    func signIn() async throws -> ChatGPTGrant {
        cancel(); let version = generation
        let verifier = try PKCE.randomURLSafeString()
        let state = try PKCE.randomURLSafeString()
        let server = try await startServer(state: state, generation: version)
        guard generation == version else { server.stop(); throw PlatformError.cancelled }
        let browser = browserFactory()
        activeBrowser = browser
        defer {
            server.stop(); browser.cancel()
            if activeServer === server { activeServer = nil }
            if activeBrowser === browser { activeBrowser = nil }
        }
        guard generation == version else { throw PlatformError.cancelled }
        guard let redirectURI = server.redirectURI?.absoluteString,
              let authorizeURL = ChatGPTOAuth.authorizeURL(challenge: PKCE.challenge(for: verifier),
                                                           state: state,
                                                           redirectURI: redirectURI) else {
            throw ChatGPTAccountError.invalidResponse
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
            } catch { }
        }
        defer { timeout.cancel() }
        let code = try await server.waitForCode()
        do {
            let grant = try await client.exchange(code: code, verifier: verifier, redirectURI: redirectURI)
            guard generation == version, !browserCancelled else { throw PlatformError.cancelled }
            server.complete(title: "已连接 ChatGPT 账号")
            return grant
        } catch {
            server.complete(success: false)
            throw error
        }
    }

    /// 端口被占用就换下一个；都不行才报错。
    private func startServer(state: String, generation version: Int) async throws -> LoopbackCallbackServer {
        var lastError: Error = PlatformError.invalidResponse
        for port in ChatGPTOAuth.callbackPorts {
            let server = LoopbackCallbackServer(expectedState: state,
                                                path: ChatGPTOAuth.callbackPath,
                                                port: port)
            guard generation == version else { throw PlatformError.cancelled }
            activeServer = server
            do {
                _ = try await server.start()
                return server
            } catch {
                lastError = error
                server.stop()
                guard generation == version else { throw PlatformError.cancelled }
            }
        }
        throw lastError
    }
}
