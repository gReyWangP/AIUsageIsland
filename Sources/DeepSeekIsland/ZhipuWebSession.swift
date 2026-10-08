import AppKit
import WebKit

@MainActor
final class ZhipuWebSession: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSWindowDelegate {
    private static let usageURL = URL(string: "https://bigmodel.cn/coding-plan/personal/usage")!
    private static let bridgeName = "islandCodingQuota"

    var onQuota: ((Result<ZhipuQuota, Error>) -> Bool)?
    var onAnalysis: ((String, Result<UsageAnalysisSnapshot, Error>) -> Void)?
    var onWindowClosed: (() -> Void)?

    private static var pendingClears: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    private var loadTask: Task<Void, Never>?
    private let profileID: UUID
    init(profileID: UUID) { self.profileID = profileID; super.init() }
    func suspend() {
        loadTask?.cancel(); loadTask = nil
        onQuota = nil; onAnalysis = nil; onWindowClosed = nil; loginWindow?.orderOut(nil); webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "islandCodingAnalysis")
        webView = nil; loginWindow = nil
    }
    static func clearStore(profileID: UUID) {
        let previous = pendingClears[profileID]?.task
        let id = UUID()
        let task = Task { @MainActor in
            await previous?.value
            let store = WKWebsiteDataStore(forIdentifier: storeIdentifier(for: profileID))
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            if pendingClears[profileID]?.id == id { pendingClears[profileID] = nil }
        }
        pendingClears[profileID] = (id, task)
    }

    static func waitForStoreClear(profileID: UUID) async {
        while let pending = pendingClears[profileID] { await pending.task.value }
    }

    private func loadUsage(in browser: WKWebView, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) {
        loadTask?.cancel()
        loadTask = Task { [weak self, weak browser] in
            guard let self else { return }
            await Self.waitForStoreClear(profileID: self.profileID)
            guard !Task.isCancelled, let browser, self.webView === browser else { return }
            browser.load(URLRequest(url: Self.usageURL, cachePolicy: cachePolicy))
        }
    }
    private var webView: WKWebView?
    private var loginWindow: NSWindow?

    func showLogin() {
        let browser = ensureBrowser()
        if loginWindow?.isVisible != true || browser.url == nil {
            loadUsage(in: browser)
        }
        loginWindow?.center()
        loginWindow?.makeKeyAndOrderFront(nil)
        loginWindow?.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @discardableResult func refresh() -> Bool {
        guard loginWindow?.isVisible != true else { return false }
        let browser = ensureBrowser()
        loadUsage(in: browser, cachePolicy: .reloadIgnoringLocalCacheData)
        return true
    }

    func signOut() {
        loadTask?.cancel(); loadTask = nil
        loginWindow?.orderOut(nil)
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "islandCodingAnalysis")
        webView = nil
        loginWindow = nil
        Self.clearStore(profileID: profileID)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "islandCodingAnalysis" {
            guard message.frameInfo.isMainFrame, Self.isBigModel(host:message.frameInfo.securityOrigin.host), message.frameInfo.securityOrigin.protocol == "https",
                  let body = message.body as? String, let data = body.data(using:.utf8), data.count <= 2_000_000,
                  let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let identity = object["accountIdentity"] as? String, !identity.isEmpty, identity.count <= 128,
                  let payload = object["payload"], let compact = try? JSONSerialization.data(withJSONObject:payload) else { return }
            do { onAnalysis?(identity,.success(try UsageAnalysisParser.zhipu(compact))) }
            catch { onAnalysis?(identity,.failure(error)) }
            return
        }
        guard message.name == Self.bridgeName,
              message.frameInfo.isMainFrame,
              Self.isBigModel(host: message.frameInfo.securityOrigin.host),
              let body = message.body as? String,
              let data = body.data(using: .utf8), data.count <= 64_000 else { return }
        do {
            let quota = try ZhipuQuotaParser.parse(data)
            if onQuota?(.success(quota)) == true { loginWindow?.orderOut(nil) }
        } catch {
            _ = onQuota?(.failure(error))
        }
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        _ = onQuota?(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        _ = onQuota?(.failure(error))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           url.scheme == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private func ensureBrowser() -> WKWebView {
        if let webView { return webView }
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Self.observerScript,
                                            injectionTime: .atDocumentStart,
                                            forMainFrameOnly: true,
                                            in: .page))
        content.addUserScript(WKUserScript(source: Self.analysisObserverScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        content.add(self, name: "islandCodingAnalysis")
        content.add(self, name: Self.bridgeName)
        let configuration = Self.configuration(profileID: profileID)
        configuration.userContentController = content
        let browser = WKWebView(frame: NSRect(x: 0, y: 0, width: 850, height: 660), configuration: configuration)
        browser.navigationDelegate = self
        browser.uiDelegate = self
        let window = Self.makeLoginWindow(content: browser)
        window.delegate = self
        webView = browser
        loginWindow = window
        return browser
    }

    // The legacy profile ID is a sentinel, not a WebKit-valid version-4 UUID.
    // Keep its dedicated storage UUID stable across launches without changing account identity.
    static func storeIdentifier(for profileID: UUID) -> UUID {
        profileID == AccountProfileEntry.legacyID
            ? UUID(uuidString: "9E3E3C45-4DF7-4AD9-9207-FA0D6C3D2D81")! : profileID
    }

    static func configuration(profileID: UUID) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeIdentifier(for: profileID))
        return configuration
    }

    static func makeLoginWindow(content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "登录智谱 CodingPlan"
        window.minSize = NSSize(width: 640, height: 520)
        window.isReleasedWhenClosed = false
        window.contentView = content
        // Island: statusBar; settings: statusBar + 1; in-app login: statusBar + 2.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return window
    }

    private static func isBigModel(host: String) -> Bool {
        host == "bigmodel.cn" || host.hasSuffix(".bigmodel.cn")
    }

    static let observerScript = #"""
    (() => {
      if (window.__islandQuotaObserver) return;
      window.__islandQuotaObserver = true;
      const isQuotaURL = value => {
        try {
          const url = new URL(value, location.href);
          return (url.hostname === 'bigmodel.cn' || url.hostname.endsWith('.bigmodel.cn')) &&
            (url.pathname === '/api/monitor/usage/quota/limit' || url.pathname === '/monitor/usage/quota/limit');
        } catch (_) { return false; }
      };
      let reportSequence = 0;
      const customerIdentity = () => {
        const value = window.VueInstance?.$store?.state?.User?.userInfo?.customerNumber;
        if (typeof value !== 'string' && typeof value !== 'number') return null;
        if (typeof value === 'number' && (!Number.isSafeInteger(value) || value < 0)) return null;
        const identity = String(value).trim();
        return identity && identity.length <= 128 ? identity : null;
      };
      const report = value => {
        try {
          const source = typeof value === 'string' ? JSON.parse(value) : value;
          if (!source || typeof source !== 'object') return;
          const payload = source.data && typeof source.data === 'object' ? source.data : {};
          const limits = Array.isArray(payload.limits) ? payload.limits : [];
          const compact = {
            code: source.code, success: source.success,
            data: { level: payload.level,
              limits: limits.map(item => ({
                type: item.type, unit: item.unit, number: item.number,
                percentage: item.percentage, currentValue: item.currentValue,
                usage: item.usage, nextResetTime: item.nextResetTime
              })) }
          };
          const sequence = ++reportSequence;
          const send = identity => {
            compact.data.accountIdentity = identity;
            window.webkit.messageHandlers.islandCodingQuota.postMessage(JSON.stringify(compact));
          };
          const identity = customerIdentity();
          send(identity);
          if (!identity) {
            let attempts = 0;
            const waitForIdentity = () => {
              if (sequence !== reportSequence) return;
              const ready = customerIdentity();
              if (ready) { send(ready); return; }
              if (++attempts < 40) setTimeout(waitForIdentity, 200);
            };
            setTimeout(waitForIdentity, 200);
          }
        } catch (_) {}
      };
      const originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        this.__islandQuotaRequest = isQuotaURL(url);
        return originalOpen.call(this, method, url, ...rest);
      };
      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function(...args) {
        if (this.__islandQuotaRequest) {
          this.addEventListener('loadend', () => {
            try { report(this.responseType === 'json' ? this.response : this.responseText); } catch (_) {}
          }, { once: true });
        }
        return originalSend.apply(this, args);
      };
      const originalFetch = window.fetch;
      if (originalFetch) window.fetch = function(input, options) {
        const url = typeof input === 'string' ? input : input && input.url;
        return originalFetch.call(this, input, options).then(response => {
          if (isQuotaURL(url)) response.clone().text().then(report).catch(() => {});
          return response;
        });
      };
    })();
    """#
    static let analysisObserverScript = #"""
    (() => {
      if (window.__islandAnalysisObserver) return;
      window.__islandAnalysisObserver = true;
      const quotaURL = value => {
        try { const u = new URL(value, location.href);
          return u.protocol === 'https:' && (u.hostname === 'bigmodel.cn' || u.hostname.endsWith('.bigmodel.cn')) &&
            (u.pathname === '/api/monitor/usage/quota/limit' || u.pathname === '/monitor/usage/quota/limit') ? u : null;
        } catch (_) { return null; }
      };
      const identity = () => {
        const x = window.VueInstance?.$store?.state?.User?.userInfo?.customerNumber;
        if (typeof x !== 'string' && typeof x !== 'number') return null;
        if (typeof x === 'number' && (!Number.isSafeInteger(x) || x < 0)) return null;
        const s = String(x).trim(); return s && s.length <= 128 ? s : null;
      };
      const originalOpen = XMLHttpRequest.prototype.open, originalSend = XMLHttpRequest.prototype.send;
      const originalHeader = XMLHttpRequest.prototype.setRequestHeader;
      let started = false;
      const numeric = values => Array.isArray(values) ? values.map(v => {
        if (typeof v === 'string' && /^\d+$/.test(v)) return v;
        return typeof v === 'number' && Number.isSafeInteger(v) && v >= 0 ? v : null;
      }) : undefined;
      const compactUsage = p => ({
        x_time: Array.isArray(p.x_time) ? p.x_time : undefined,
        xTime: Array.isArray(p.xTime) ? p.xTime : undefined,
        tokensUsage: numeric(p.tokensUsage),
        modelDataList: Array.isArray(p.modelDataList) ? p.modelDataList.map(m => ({
          totalTokensUsage: numeric(m.totalTokensUsage), tokensUsage: numeric(m.tokensUsage)
        })) : undefined
      });
      const send = (owner, payload) => {
        const message = JSON.stringify({ accountIdentity: owner, payload });
        if (message.length <= 1900000) window.webkit.messageHandlers.islandCodingAnalysis.postMessage(message);
      };
      const requestHistory = (url, headers, credit, owner) => {
        if (started) return;
        if (!owner || identity() !== owner) return;
        started = true;
        // All authentication stays inside this account's WebKit data store.
        const format = d => new Intl.DateTimeFormat('sv-SE', {timeZone:'Asia/Shanghai', year:'numeric', month:'2-digit', day:'2-digit', hour:'2-digit', minute:'2-digit', second:'2-digit', hourCycle:'h23'}).format(d);
        const start = format(new Date(Date.now()-29*86400000)).slice(0,10) + ' 00:00:00';
        const end = format(new Date()).slice(0,13) + ':59:59';
        const path = credit ? '/monitor/credit-usage/usage-detail' : '/monitor/usage/model-usage';
        const prefix = url.pathname.startsWith('/api/') ? '/api' : '';
        let target = url.origin + prefix + path + '?startTime=' + encodeURIComponent(start) + '&endTime=' + encodeURIComponent(end);
        if (credit) target += '&usageType=MODEL&type=1';
        const request = new XMLHttpRequest();
        originalOpen.call(request, 'GET', target, true); request.timeout = 20000;
        if (originalHeader) for (const [key,value] of Object.entries(headers)) originalHeader.call(request,key,value);
        request.addEventListener('loadend', () => {
          if (identity() !== owner) return;
          try {
            const source = request.responseType === 'json' ? request.response : JSON.parse(request.responseText);
            const p = source.data || {};
            const data = p.modelUsage ? { modelUsage: compactUsage(p.modelUsage) } : compactUsage(p);
            send(owner, {code:source.code,success:source.success,data});
          } catch (_) { send(owner, {success:false,data:{}}); }
        }, {once:true});
        originalSend.call(request);
      };
      let recovering = false;
      const recoverAfterIdentity = (url, attempts=0) => {
        if (started || recovering) return;
        const owner=identity();
        if (!owner) { if (attempts < 40) setTimeout(() => recoverAfterIdentity(url, attempts+1), 200); return; }
        try {
          // Official page's 5f87/22a6 modules read this cookie and these scope keys.
          // Fetch a NEW quota with current browser credentials; never relabel old headers.
          const raw=document.cookie.split(';').map(x=>x.trim()).find(x=>x.startsWith('bigmodel_token_production='));
          const token=raw ? decodeURIComponent(raw.slice('bigmodel_token_production='.length)) : null;
          if (!token || !originalHeader) { send(owner,{success:false,data:{}}); return; }
          recovering=true;
          const request=new XMLHttpRequest();
          request.open('GET',url.origin+url.pathname,true);
          request.timeout=20000;
          request.setRequestHeader('Authorization',token);
          request.setRequestHeader('Content-Type','application/json');
          request.setRequestHeader('Bigmodel-Organization',localStorage.getItem('Bigmodel-Organization') || '');
          request.setRequestHeader('Bigmodel-Project',localStorage.getItem('Bigmodel-Project') || '');
          request.send();
        } catch (_) { send(owner,{success:false,data:{}}); }
      };
      XMLHttpRequest.prototype.open = function(method,url,...rest) {
        this.__islandAnalysisQuota = quotaURL(url); this.__islandAnalysisHeaders = {};
        return originalOpen.call(this,method,url,...rest);
      };
      if (originalHeader) XMLHttpRequest.prototype.setRequestHeader = function(key,value) {
        if (this.__islandAnalysisQuota) this.__islandAnalysisHeaders[key] = value;
        return originalHeader.call(this,key,value);
      };
      XMLHttpRequest.prototype.send = function(...args) {
        const owner = identity();
        if (this.__islandAnalysisQuota) this.addEventListener('loadend', () => {
          try { const p = this.responseType === 'json' ? this.response : JSON.parse(this.responseText);
            if (p.success === false || (p.code !== undefined && p.code !== 200 && p.code !== 0)) return;
            if (!owner) { recoverAfterIdentity(this.__islandAnalysisQuota); return; }
            requestHistory(this.__islandAnalysisQuota, this.__islandAnalysisHeaders, p.data?.limits?.some(x => x.type === 'CREDIT_LIMIT'), owner);
          } catch (_) {}
        }, {once:true});
        return originalSend.apply(this,args);
      };
    })();
    """#
}
