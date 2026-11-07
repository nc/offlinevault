import Foundation
import WebKit
import OfflineVaultCore

/// Downloads a file the way Safari would: a hidden WKWebView loads the URL, runs any JavaScript interstitial, and
/// WKDownload saves the result through the same session. Used for "Import from URL" when sites refuse plain
/// HTTP clients. Only ever fetches what the user explicitly asked for.
@MainActor
final class BrowserFetcher: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    private var web: WKWebView?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?
    private var htmlPages = 0
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    /// Resolves to the saved file (in `directory`) or throws a user-facing error. Also accepts HTML pages that link a
    /// single PDF: if the page itself is HTML, its first `.pdf` link is followed automatically.
    func download(_ url: URL, into directory: URL, timeout: TimeInterval = 90) async throws -> URL {
        // Reset per call: a fetcher may be reused by the Documents screen.
        finished = false; htmlPages = 0; destination = nil; timeoutTask?.cancel(); cleanup()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        w.navigationDelegate = self
        web = w
        destination = directory.appendingPathComponent(Self.safeName(url.lastPathComponent.isEmpty ? "download.pdf" : url.lastPathComponent))
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.fail(UserFacingError("Download timed out", message: "\(url.host ?? "The site") did not deliver a file within \(Int(timeout)) seconds.", recovery: "Open the link in Safari, save the PDF, then use Import PDF…"))
            }
            w.load(URLRequest(url: url))
        }
    }

    static func safeName(_ s: String) -> String {
        var n = s.removingPercentEncoding ?? s
        n = n.replacingOccurrences(of: "[/:\\\\]", with: "_", options: .regularExpression)
        return n.isEmpty ? "download.pdf" : n
    }

    private func finish(_ url: URL) { guard !finished else { return }; finished = true; timeoutTask?.cancel(); continuation?.resume(returning: url); cleanup() }
    private func fail(_ e: Error) { guard !finished else { return }; finished = true; timeoutTask?.cancel(); continuation?.resume(throwing: e); cleanup() }
    private func cleanup() { web?.stopLoading(); web?.navigationDelegate = nil; web = nil; continuation = nil }
    func cancel() { fail(UserFacingError("Cancelled", message: "The download was cancelled.")) }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let mime = navigationResponse.response.mimeType ?? ""
        let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 404 { fail(UserFacingError("Not found", message: "The server says this file no longer exists (404).", recovery: "The agency may have moved it; search their site for the current link.")); decisionHandler(.cancel); return }
        if mime != "text/html" && mime != "application/xhtml+xml" && mime != "text/plain" && (200..<300).contains(status) {
            if let name = navigationResponse.response.suggestedFilename, !name.isEmpty, let dir = destination?.deletingLastPathComponent() { destination = dir.appendingPathComponent(Self.safeName(name)) }
            decisionHandler(.download)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        htmlPages += 1
        // An HTML page: either a bot-check interstitial (it will redirect by itself) or a landing page. After a short
        // wait, follow the first PDF link on it; give up after a few hops.
        if htmlPages > 4 { fail(UserFacingError("No file found", message: "The address shows a web page, not a downloadable file.", recovery: "Open it in Safari and copy the direct PDF link, or save the PDF and use Import PDF….")); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.finished, let web = self.web else { return }
            let js = "Array.from(document.querySelectorAll('a[href], embed[src], iframe[src], object[data]')).map(e => e.href || e.src || e.data).filter(u => u && /\\.pdf(\\?|#|$)/i.test(u))[0] || ''"
            web.evaluateJavaScript(js) { result, _ in
                if let s = result as? String, let u = URL(string: s) { web.load(URLRequest(url: u)) }
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    private func report(_ error: Error) {
        let ns = error as NSError
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return } // frame load interrupted: the download took over
        fail(error.userFacing)
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = destination?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        let dest = dir.appendingPathComponent(Self.safeName(suggestedFilename.isEmpty ? destination?.lastPathComponent ?? "download.pdf" : suggestedFilename))
        destination = dest
        try? FileManager.default.removeItem(at: dest)
        completionHandler(dest)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let d = destination else { return }
        if let h = try? FileHandle(forReadingFrom: d), let head = try? h.read(upToCount: 5), String(decoding: head, as: UTF8.self).hasPrefix("%PDF") || !d.pathExtension.lowercased().hasSuffix("pdf") { finish(d) }
        else { try? FileManager.default.removeItem(at: d); fail(UserFacingError("Not a PDF", message: "The downloaded file is not a PDF.", recovery: "Check the link points at the document itself.")) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { fail(error.userFacing) }
}
