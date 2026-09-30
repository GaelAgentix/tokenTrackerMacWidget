import AppKit
import WebKit

enum SessionError: LocalizedError {
    case signedOut
    case timeout
    case http(Int)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Signed out of claude.ai"
        case .timeout: return "claude.ai took too long to respond"
        case .http(let code): return "claude.ai returned HTTP \(code)"
        case .unexpected(let message): return message
        }
    }
}

/// One signed-in claude.ai browser session. Requests run inside a hidden WKWebView so they
/// carry the account's cookies and pass claude.ai's bot checks like a normal browser tab.
@MainActor
final class ClaudeSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    let profile: Profile
    let dataStore: WKWebsiteDataStore
    /// Latest JSON body the usage page fetched, keyed by API path.
    private(set) var captures: [String: String] = [:]
    /// Full URL (with query) of each captured request, keyed by API path.
    private(set) var capturedURLs: [String: String] = [:]
    var onAccountWindowNavigated: (() -> Void)?

    private var webView: WKWebView?
    private var lastPageLoad: Date?
    private var hostWindow: NSWindow?
    private var navigation: CheckedContinuation<Void, Error>?
    private var accountWindow: AccountWindowController?

    init(profile: Profile) {
        self.profile = profile
        dataStore = WKWebsiteDataStore(forIdentifier: profile.storeID)
        super.init()
    }

    // MARK: Hidden page

    private func hiddenWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.add(WeakScriptHandler(self), name: "tokenTracker")
        config.userContentController = scripts

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: config)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self

        // WebKit only lays pages out properly inside a window, so park one far off-screen.
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1200, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        window.contentView = view
        window.orderBack(nil)

        hostWindow = window
        webView = view
        return view
    }

    /// Makes sure the hidden page is a live, signed-in claude.ai tab. The usage page is only
    /// reloaded every `maxAge` seconds (or after a failure); in between, refreshes are plain
    /// API calls. `waitingFor` holds the reload until the page has made that API request.
    func ensureReady(waitingFor pathSuffix: String? = nil, maxAge: TimeInterval = 3 * 3600) async throws {
        if let lastPageLoad, Date().timeIntervalSince(lastPageLoad) < maxAge,
           webView?.url?.host?.hasSuffix("claude.ai") == true {
            return
        }
        try await load(Profile.usageURL)
        if let pathSuffix {
            for _ in 0..<40 where !captures.keys.contains(where: { $0.hasSuffix(pathSuffix) }) {
                if isOnLoginPage { throw SessionError.signedOut }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        if isOnLoginPage { throw SessionError.signedOut }
        lastPageLoad = Date()
        saveDiagnostics()
    }

    /// Forces a full page reload on the next `ensureReady`.
    func invalidate() { lastPageLoad = nil }

    func capturedURL(endingWith suffix: String) -> String? {
        capturedURLs.first { $0.key.hasSuffix(suffix) }?.value
    }

    func captured(endingWith suffix: String) -> String? {
        captures.first { $0.key.hasSuffix(suffix) }?.value
    }

    func load(_ url: URL, timeout: TimeInterval = 45) async throws {
        let view = hiddenWebView()
        captures.removeAll()
        capturedURLs.removeAll()
        navigation?.resume(throwing: CancellationError())
        navigation = nil

        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            self?.finishNavigation(SessionError.timeout)
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigation = continuation
            view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout))
        }
        if isOnLoginPage { throw SessionError.signedOut }
    }

    var isOnLoginPage: Bool {
        guard let url = webView?.url else { return false }
        if url.host?.hasSuffix("claude.ai") == false { return true }
        return url.path.hasPrefix("/login") || url.path.hasPrefix("/logout") || url.path.hasPrefix("/magic-link")
    }

    func pageText() async throws -> String {
        let result = try await hiddenWebView().callAsyncJavaScript(
            "return document.body ? document.body.innerText : '';",
            arguments: [:], in: nil, contentWorld: .defaultClient)
        return result as? String ?? ""
    }

    /// GET a claude.ai API path with the session's cookies. Retries while a bot check clears.
    func fetchJSON(_ path: String) async throws -> Any {
        var lastStatus = 0
        for attempt in 0..<3 {
            let result = try await hiddenWebView().callAsyncJavaScript(
                """
                const r = await fetch(path, { credentials: 'include', headers: { 'accept': 'application/json' } });
                return [r.status, await r.text()];
                """,
                arguments: ["path": path], in: nil, contentWorld: .defaultClient)
            guard let pair = result as? [Any], pair.count == 2,
                  let status = (pair[0] as? NSNumber)?.intValue, let body = pair[1] as? String
            else { throw SessionError.unexpected("Unreadable response from \(path)") }

            if (200..<300).contains(status), let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) {
                return json
            }
            if status == 401 || (status == 403 && (body.contains("permission_error") || body.contains("authentication_error"))) {
                throw SessionError.signedOut
            }
            lastStatus = status
            try await Task.sleep(for: .seconds(3 * (attempt + 1)))
        }
        throw SessionError.http(lastStatus)
    }

    /// Keeps the most recent API responses on disk for troubleshooting (conversation
    /// traffic is never captured — see `captureScript`).
    func saveDiagnostics(pageText: String? = nil) {
        let dir = Storage.directory.appendingPathComponent("captures/\(profile.rawValue)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, body) in captures {
            let name = path.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            try? body.write(to: dir.appendingPathComponent(name + ".json"), atomically: true, encoding: .utf8)
        }
        if let pageText {
            try? pageText.write(to: dir.appendingPathComponent("page-text.txt"), atomically: true, encoding: .utf8)
        }
    }

    private func finishNavigation(_ error: Error?) {
        guard let continuation = navigation else { return }
        navigation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(error)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let url = payload["url"] as? String, let body = payload["body"] as? String else { return }
        let path = URL(string: url, relativeTo: URL(string: "https://claude.ai"))?.path ?? url
        captures[path] = body
        capturedURLs[path] = url
    }

    // MARK: Visible window (sign-in / usage page)

    func showAccountWindow(url: URL) {
        if accountWindow == nil {
            accountWindow = AccountWindowController(session: self)
        }
        accountWindow?.show(url: url)
    }

    func accountWindowDidNavigate(to url: URL?) {
        guard let url, url.host?.hasSuffix("claude.ai") == true,
              !url.path.hasPrefix("/login"), !url.path.hasPrefix("/magic-link") else { return }
        onAccountWindowNavigated?()
    }

    func signOut() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        webView = nil
        hostWindow?.close()
        hostWindow = nil
        lastPageLoad = nil
        captures.removeAll()
        capturedURLs.removeAll()
    }

    /// Mirrors every JSON response the claude.ai page receives from its own API so the usage
    /// page's chart data can be read. Chat content endpoints are skipped.
    private static let captureScript = """
    (function () {
      if (window.__tokenTrackerHooked) return;
      window.__tokenTrackerHooked = true;
      const skip = /(chat_conversations|completion|append_message|event_logging|statsig|sentry|intercom|artifacts|projects|files)/;
      const want = (u) => typeof u === 'string' && u.includes('/api/') && !skip.test(u);
      const post = (url, body) => {
        try { window.webkit.messageHandlers.tokenTracker.postMessage({ url: String(url), body: String(body).slice(0, 2000000) }); } catch (e) {}
      };
      const originalFetch = window.fetch;
      window.fetch = async function (input, init) {
        const response = await originalFetch.apply(this, arguments);
        try {
          const url = typeof input === 'string' ? input : (input && input.url) || '';
          const type = response.headers.get('content-type') || '';
          if (want(url) && type.includes('json')) response.clone().text().then((t) => post(url, t)).catch(() => {});
        } catch (e) {}
        return response;
      };
      const open = XMLHttpRequest.prototype.open;
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) { this.__tokenTrackerURL = String(url); return open.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () {
        this.addEventListener('load', () => {
          try { if (want(this.__tokenTrackerURL) && typeof this.responseText === 'string') post(this.__tokenTrackerURL, this.responseText); } catch (e) {}
        });
        return send.apply(this, arguments);
      };
    })();
    """
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (NSObject & WKScriptMessageHandler)?
    init(_ target: NSObject & WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// A normal browser window on the account's data store, used to sign in or view the usage page.
@MainActor
final class AccountWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private unowned let session: ClaudeSession
    private let window: NSWindow
    private let webView: WKWebView
    private var popups: [NSWindow] = []

    init(session: ClaudeSession) {
        self.session = session
        let config = WKWebViewConfiguration()
        config.websiteDataStore = session.dataStore
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = ClaudeSession.userAgent

        let hint = NSTextField(labelWithString:
            "Sign in with the account for the \(session.profile.shortTitle) widget. The widget updates once you're signed in; you can close this window afterwards.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2

        let stack = NSStackView(views: [hint, webView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
        hint.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14).isActive = true
        hint.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14).isActive = true
        webView.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        webView.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Token Tracker — \(session.profile.title)"
        window.isReleasedWhenClosed = false
        window.contentView = stack
        window.center()
        super.init()
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func show(url: URL) {
        webView.load(URLRequest(url: url))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        session.accountWindowDidNavigate(to: webView.url)
    }

    /// Sign-in providers (Google, SSO) open pop-ups that report back to the opener.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popupView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popupView.customUserAgent = ClaudeSession.userAgent
        popupView.uiDelegate = self
        let popup = NSWindow(contentRect: popupView.frame, styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false
        popup.contentView = popupView
        popup.center()
        popup.makeKeyAndOrderFront(nil)
        popups.append(popup)
        return popupView
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.removeAll { popup in
            guard popup.contentView === webView else { return false }
            popup.close()
            return true
        }
    }
}
