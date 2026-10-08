import AppKit
import CryptoKit
import Foundation
@preconcurrency import Network
import Security

enum PKCE {
    static func randomURLSafeString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PlatformError.invalidResponse
        }
        return Data(bytes).base64URLEncodedString
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
    }
}

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum OAuthCallback {
    static func code(from requestLine: String,
                     expectedState: String,
                     path expectedPath: String = "/oauth/callback") throws -> String {
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1",
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              components.path == expectedPath else { throw PlatformError.invalidResponse }
        let items = components.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        let codes = items.filter { $0.name == "code" }
        guard states.count == 1, codes.count == 1,
              let state = states.first?.value, let code = codes.first?.value,
              !code.isEmpty, state.utf8.elementsEqual(expectedState.utf8) else {
            throw PlatformError.invalidResponse
        }
        return code
    }
}

@MainActor
final class LoopbackCallbackServer {
    private let expectedState: String
    private let callbackPath: String
    private let port: UInt16?
    private let queue = DispatchQueue(label: "com.deepseekisland.oauth.callback")
    private var listener: NWListener?
    private var stopped = false
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var pendingCode: String?
    private var callbackConnection: NWConnection?
    /// 监听成功后确定的回调地址（端口固定时才等于入参）。
    private(set) var redirectURI: URL?

    /// - Parameters:
    ///   - port: 固定端口；`nil` 表示由系统分配（DeepSeek 的授权地址是接口下发的，
    ///     端口不固定）。OpenAI 的 client 只允许白名单端口，必须传固定值。
    init(expectedState: String, path: String = "/oauth/callback", port: UInt16? = nil) {
        self.expectedState = expectedState
        self.callbackPath = path
        self.port = port
    }

    func start() async throws -> URL {
        guard !stopped else { throw PlatformError.cancelled }
        let parameters = NWParameters.tcp
        let endpointPort = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                guard let port = listener?.port?.rawValue else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    let url = URL(string: "http://127.0.0.1:\(port)\(self.callbackPath)")!
                    self.redirectURI = url
                    self.readyContinuation?.resume(returning: url)
                    self.readyContinuation = nil
                }
            case .failed:
                Task { @MainActor [weak self] in
                    self?.readyContinuation?.resume(throwing: PlatformError.invalidResponse)
                    self?.readyContinuation = nil
                }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            let target = self
            connection.start(queue: target?.queue ?? .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                let result = try? OAuthCallback.code(from: line,
                                                     expectedState: target?.expectedState ?? "",
                                                     path: target?.callbackPath ?? "/oauth/callback")
                if let result {
                    Task { @MainActor in target?.receive(code: result, connection: connection) }
                } else {
                    Self.respond(to: connection, status: "400 Bad Request", body: "Invalid callback", type: "text/plain; charset=utf-8")
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            listener.start(queue: queue)
        }
    }

    func waitForCode() async throws -> String {
        guard !stopped else { throw PlatformError.cancelled }
        if let pendingCode { return pendingCode }
        return try await withCheckedThrowingContinuation { codeContinuation = $0 }
    }

    func stop() {
        stopped = true
        pendingCode = nil
        listener?.cancel()
        listener = nil
        callbackConnection?.cancel()
        callbackConnection = nil
        readyContinuation?.resume(throwing: PlatformError.cancelled)
        readyContinuation = nil
        codeContinuation?.resume(throwing: PlatformError.cancelled)
        codeContinuation = nil
    }

    func complete(success: Bool = true, title: String = "已连接 DeepSeek 账号") {
        guard let callbackConnection else { return }
        self.callbackConnection = nil
        if success {
            let html = """
            <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>\(title)</title><style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#10131b;color:#fff;display:grid;min-height:100vh;place-items:center;margin:0;text-align:center}main{padding:28px}p{color:#aeb7c9}a{display:inline-block;margin-top:14px;padding:11px 22px;border-radius:12px;background:#648aff;color:#fff;text-decoration:none}</style></head><body><main><h2>\(title)</h2><p>悬浮窗已展开，你也可以点此重新唤起。</p><a href="deepseekisland://open">打开应用</a></main></body></html>
            """
            Self.respond(to: callbackConnection, status: "200 OK", body: html, type: "text/html; charset=utf-8")
        } else {
            Self.respond(to: callbackConnection, status: "500 Internal Server Error", body: "授权未完成，请返回应用重试。", type: "text/plain; charset=utf-8")
        }
    }

    private nonisolated static func respond(to connection: NWConnection, status: String, body: String, type: String) {
        let bytes = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + bytes, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func receive(code: String, connection: NWConnection) {
        guard !stopped, callbackConnection == nil else {
            Self.respond(to: connection, status: "410 Gone", body: "Authorization already received", type: "text/plain; charset=utf-8")
            return
        }
        callbackConnection = connection
        if let codeContinuation {
            codeContinuation.resume(returning: code)
            self.codeContinuation = nil
        } else {
            pendingCode = code
        }
    }
}

protocol PlatformAuthServing: Sendable {
    func initializeAuth(body: [String: String]) async throws -> AuthInitialization
    func exchangeAuth(body: [String: String]) async throws -> AuthExchange
}

@MainActor protocol PlatformAuthorizing {
    func signIn() async throws -> String
    func cancel()
}

@MainActor
final class PlatformAuthFlow: PlatformAuthorizing {
    private let client: any PlatformAuthServing
    private let browserFactory: @MainActor () -> any OAuthBrowserPresenting
    private var activeBrowser: (any OAuthBrowserPresenting)?
    init(client: any PlatformAuthServing = PlatformAccountClient(),
         browserFactory: @escaping @MainActor () -> any OAuthBrowserPresenting = { IsolatedOAuthBrowser() }) {
        self.client = client; self.browserFactory = browserFactory
    }
    private var activeServer: LoopbackCallbackServer?
    private var generation = 0
    func cancel() { generation += 1; activeServer?.stop(); activeServer = nil; activeBrowser?.cancel(); activeBrowser = nil }

    func signIn() async throws -> String {
        cancel(); let version = generation
        let verifier = try PKCE.randomURLSafeString()
        let state = try PKCE.randomURLSafeString()
        let server = LoopbackCallbackServer(expectedState: state)
        activeServer = server
        let browser = browserFactory()
        activeBrowser = browser
        defer {
            server.stop(); browser.cancel()
            if activeServer === server { activeServer = nil }
            if activeBrowser === browser { activeBrowser = nil }
        }
        let callbackURL = try await server.start()
        let redirectURI = callbackURL.absoluteString
        let initialization = try await client.initializeAuth(body: [
            "code_challenge": PKCE.challenge(for: verifier),
            "code_challenge_method": "S256",
            "state": state,
            "redirect_uri": redirectURI,
            "locale": "zh_CN",
            "login_source": "desktop"
        ])
        guard generation == version else { throw PlatformError.cancelled }
        let authorizeURL = try PlatformAccountClient.validateAuthorizeURL(initialization.authorizeURL)
        var browserCancelled = false
        let cancelAttempt: @MainActor () -> Void = {
            browserCancelled = true
            server.stop()
        }
        try browser.start(url: authorizeURL, onCancel: cancelAttempt)

        let timeout = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(min(initialization.expiresIn, 180)))
                cancelAttempt()
            } catch { }
        }
        defer { timeout.cancel() }
        let code = try await server.waitForCode()
        do {
            let exchange = try await client.exchangeAuth(body: [
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": redirectURI,
                "device_id": UUID().uuidString.lowercased(),
                "device_model": "darwin-arm64",
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString
            ])
            guard generation == version, !browserCancelled else { throw PlatformError.cancelled }
            _ = try PlatformAccountClient.validateCompletionURL(exchange.authorizedURL)
            server.complete()
            return exchange.token
        } catch {
            server.complete(success: false)
            throw error
        }
    }
}
