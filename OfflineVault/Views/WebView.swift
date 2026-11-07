import SwiftUI
import WebKit
import OfflineVaultCore

/// WKWebView wrapper with two hard offline modes:
///  - `.localFile`: only `file://` content inside `readAccess` may load; every http(s) request is blocked by a content rule list and the navigation delegate.
///  - `.localServer`: only URLs under the given localhost base may load (kiwix-serve).
/// Reader commands (back/forward/find/zoom/print) are driven through `ReaderBridge`.
struct WebView: NSViewRepresentable {
    enum Mode: Equatable { case localFile(readAccess: URL), localServer(base: URL) }
    let url: URL
    let mode: Mode
    var onTitle: ((String) -> Void)? = nil
    var onNavigationState: ((Bool, Bool) -> Void)? = nil
    var bridge: ReaderBridge? = nil
    var zoom: Double = 1.0

    /// Dark-mode treatment for reference pages (ZIM content is styled for light backgrounds).
    static let darkCSS = "@media (prefers-color-scheme: dark) { html { filter: invert(0.92) hue-rotate(180deg); background: #fff !important; } img, video, canvas, picture, [style*=\"background-image\"] { filter: invert(1) hue-rotate(180deg); } }"

    final class Coordinator: NSObject, WKNavigationDelegate {
        var mode: Mode; var onTitle: ((String) -> Void)?; var onNav: ((Bool, Bool) -> Void)?; var lastLoaded: URL?
        init(mode: Mode, onTitle: ((String) -> Void)?, onNav: ((Bool, Bool) -> Void)?) { self.mode = mode; self.onTitle = onTitle; self.onNav = onNav }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let u = navigationAction.request.url else { return decisionHandler(.cancel) }
            switch mode {
            case .localFile: decisionHandler(u.isFileURL || ["about", "data", "blob"].contains(u.scheme ?? "") ? .allow : .cancel)
            case .localServer(let base):
                let ok = u.absoluteString.hasPrefix(base.absoluteString) || ["about", "data", "blob"].contains(u.scheme ?? "")
                decisionHandler(ok ? .allow : .cancel)
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Log.pages.error("page failed to load: \(error.localizedDescription, privacy: .public)")
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log.pages.error("page failed: \(error.localizedDescription, privacy: .public)")
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let t = webView.title, !t.isEmpty { onTitle?(t) }
            onNav?(webView.canGoBack, webView.canGoForward)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(mode: mode, onTitle: onTitle, onNav: onNavigationState) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.preferences.isFraudulentWebsiteWarningEnabled = false
        cfg.defaultWebpagePreferences.allowsContentJavaScript = { if case .localFile = mode { return false }; return true }()
        if case .localServer = mode {
            cfg.userContentController.addUserScript(WKUserScript(source: "var s=document.createElement('style');s.textContent=`\(Self.darkCSS)`;document.documentElement.appendChild(s);", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.underPageBackgroundColor = .windowBackgroundColor
        bridge?.web = web
        // Block every network request except, in local-server mode, the loopback helper that serves the books.
        let allow: URL? = { if case .localServer(let base) = mode { return base }; return nil }()
        RuleListCache.shared.rules(allowing: allow) { list in
            if let list { web.configuration.userContentController.add(list) }
            load(web, context: context)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.mode = mode; context.coordinator.onTitle = onTitle; context.coordinator.onNav = onNavigationState
        bridge?.web = web
        if web.pageZoom != zoom { web.pageZoom = zoom }
        if context.coordinator.lastLoaded != url { load(web, context: context) }
    }

    private func load(_ web: WKWebView, context: Context) {
        context.coordinator.lastLoaded = url
        switch mode {
        case .localFile(let access): web.loadFileURL(url, allowingReadAccessTo: access)
        case .localServer: web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }
}

/// Lets SwiftUI toolbars drive the web view (back, forward, find, print) without recreating it.
final class ReaderBridge: ObservableObject {
    weak var web: WKWebView?
    func back() { web?.goBack() }
    func forward() { web?.goForward() }
    func find(_ text: String) { guard let web, !text.isEmpty else { return }; web.find(text, configuration: WKFindConfiguration()) { _ in } }
    /// Scrolls to and selects `text` with the page focused, so the selection shows in its active colour.
    func highlight(_ text: String?) {
        guard let web, let text, !text.isEmpty else { return }
        web.window?.makeFirstResponder(web)
        web.find(text, configuration: WKFindConfiguration()) { _ in }
    }
    func print() {
        guard let web, let window = web.window else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        let op = web.printOperation(with: info)
        op.view?.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

/// Compiles the network-blocking rule lists once each: one that blocks everything, and one per local base
/// URL that still lets the loopback helper (kiwix-serve) through.
final class RuleListCache {
    static let shared = RuleListCache()
    private var lists: [String: WKContentRuleList] = [:]
    private var pending: [String: [(WKContentRuleList?) -> Void]] = [:]

    static func rules(allowing base: URL?) -> String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": "^https?://.*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^wss?://.*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^ftp://.*"], "action": ["type": "block"]],
        ]
        if let base, let host = base.host, let port = base.port {
            let escapedHost = host.replacingOccurrences(of: ".", with: "\\.")
            rules.append(["trigger": ["url-filter": "^http://\(escapedHost):\(port)/.*"], "action": ["type": "ignore-previous-rules"]])
        }
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }

    func rules(allowing base: URL? = nil, _ completion: @escaping (WKContentRuleList?) -> Void) {
        let id = "offlinevault-block-network" + (base.map { "-" + ($0.host ?? "") + "-\($0.port ?? 0)" } ?? "")
        if let list = lists[id] { completion(list); return }
        pending[id, default: []].append(completion)
        guard pending[id]!.count == 1 else { return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: id, encodedContentRuleList: Self.rules(allowing: base)) { [weak self] list, error in
            if let error { Log.pages.error("content rule list failed: \(error.localizedDescription, privacy: .public)") }
            DispatchQueue.main.async { self?.lists[id] = list; let cbs = self?.pending[id] ?? []; self?.pending[id] = nil; cbs.forEach { $0(list) } }
        }
    }
}
