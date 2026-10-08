import AppKit
import AuthenticationServices

@MainActor
protocol OAuthBrowserPresenting: AnyObject {
    func start(url: URL, onCancel: @escaping @MainActor () -> Void) throws
    func cancel()
}

@MainActor
protocol EphemeralAuthenticationSession: AnyObject {
    var prefersEphemeralWebBrowserSession: Bool { get set }
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: EphemeralAuthenticationSession {}

enum IsolatedLoginError: LocalizedError {
    case unsupportedBrowser, cannotStart
    var errorDescription: String? {
        switch self {
        case .unsupportedBrowser:
            "默认浏览器不支持隔离登录。请将默认浏览器改为 Safari 或支持临时授权会话的浏览器后重试。"
        case .cannotStart:
            "无法打开隔离登录会话，请关闭其他授权窗口后重试。"
        }
    }
}

/// One ephemeral session per authorization attempt. OAuth completion stays on the validated
/// loopback server, so the provider's registered redirect URI does not need to change.
@MainActor
final class IsolatedOAuthBrowser: NSObject, OAuthBrowserPresenting, ASWebAuthenticationPresentationContextProviding {
    typealias Factory = @MainActor (URL, @escaping @Sendable (URL?, (any Error)?) -> Void) -> any EphemeralAuthenticationSession
    private let isolationSupported: @MainActor () -> Bool
    private let factory: Factory?
    private var session: (any EphemeralAuthenticationSession)?
    private var activeID: UUID?
    private var fallbackAnchor: NSWindow?

    init(supportsIsolation: @escaping @MainActor () -> Bool = IsolatedOAuthBrowser.defaultBrowserSupportsIsolation,
         factory: Factory? = nil) {
        isolationSupported = supportsIsolation
        self.factory = factory
        super.init()
    }

    func start(url: URL, onCancel: @escaping @MainActor () -> Void) throws {
        cancel()
        guard isolationSupported() else { throw IsolatedLoginError.unsupportedBrowser }
        let id = UUID()
        activeID = id
        let completion: @MainActor () -> Void = { [weak self] in
            guard let self, self.activeID == id else { return }
            self.activeID = nil
            self.session = nil
            onCancel()
        }
        let created: any EphemeralAuthenticationSession
        if let factory {
            created = factory(url, Self.systemCompletion(completion))
        } else {
            let native = ASWebAuthenticationSession(url: url, callbackURLScheme: nil,
                completionHandler: Self.systemCompletion(completion))
            native.presentationContextProvider = self
            created = native
        }
        created.prefersEphemeralWebBrowserSession = true
        session = created
        guard created.start() else {
            cancel()
            throw IsolatedLoginError.cannotStart
        }
    }

    // Construct callbacks outside the actor: Objective-C may invoke them on an XPC queue.
    // Merely putting Task inside an actor-inferred closure still traps before its body runs.
    nonisolated private static func systemCompletion(
        _ completion: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { _, _ in Task { @MainActor in completion() } }
    }

    func cancel() {
        // Invalidate before cancel: some implementations invoke completion during cancellation.
        activeID = nil
        let previous = session
        session = nil
        previous?.cancel()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow { return window }
        if let fallbackAnchor { return fallbackAnchor }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                              styleMask: [], backing: .buffered, defer: false)
        fallbackAnchor = window
        return window
    }

    static func supportsIsolation(browserID: String?, authentication: Bool?, ephemeral: Bool?) -> Bool {
        guard let browserID else { return false }
        if browserID == "com.apple.Safari" { return true }
        // macOS falls back to Safari when the default browser does not handle authentication.
        guard authentication == true else { return true }
        return ephemeral == true
    }

    static func defaultBrowserSupportsIsolation() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return false }
        let capabilities = bundle.object(forInfoDictionaryKey: "ASWebAuthenticationSessionWebBrowserSupportCapabilities") as? [String: Any]
        return supportsIsolation(browserID: id,
                                 authentication: capabilities?["IsSupported"] as? Bool,
                                 ephemeral: capabilities?["EphemeralBrowserSessionIsSupported"] as? Bool)
    }
}
