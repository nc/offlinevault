#!/usr/bin/env swift
// Downloads a file the way Safari would: a hidden WKWebView loads the URL, runs any JavaScript bot-check
// interstitial (Akamai/Cloudflare style), and WKDownload saves the resulting file through the same session.
// Used by the publisher (ovpub.fetch.download_pdf) for US-government PDFs that refuse scripted (curl) downloads.
//
//   swift scripts/content/browser_fetch.swift <url> <output-file> [timeout-seconds]
//   swift scripts/content/browser_fetch.swift --links <page-url> [timeout-seconds]      # print PDF links found on a page
//
// Exit codes: 0 saved, 2 bad arguments, 3 timeout, 4 navigation/download failed, 5 not a PDF/binary (HTML page).
import Foundation
import WebKit

var args = CommandLine.arguments
let linksMode = args.count >= 3 && args[1] == "--links"
if linksMode { args.remove(at: 1); args.insert("-", at: 2) }
guard args.count >= 3, let startURL = URL(string: args[1]) else { FileHandle.standardError.write("usage: browser_fetch.swift <url> <out> [timeout]\n".data(using: .utf8)!); exit(2) }
let outputURL = URL(fileURLWithPath: args[2])
let timeout = args.count > 3 ? Double(args[3]) ?? 120 : 120

final class Fetcher: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    let web: WKWebView
    let url: URL
    let out: URL
    var navigations = 0
    init(url: URL, out: URL) {
        self.url = url; self.out = out
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        super.init()
        web.navigationDelegate = self
    }
    func start() { web.load(URLRequest(url: url)) }

    // Any non-HTML response (PDF, zip, octet-stream) becomes a download, including after a JS challenge redirect.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let mime = navigationResponse.response.mimeType ?? ""
        let http = navigationResponse.response as? HTTPURLResponse
        FileHandle.standardError.write("response \(http?.statusCode ?? 0) \(mime) \(navigationResponse.response.url?.absoluteString ?? "")\n".data(using: .utf8)!)
        if mime != "text/html" && mime != "application/xhtml+xml" && (http?.statusCode ?? 0) == 200 { decisionHandler(.download) } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        try? FileManager.default.removeItem(at: out)
        completionHandler(out)
    }
    func downloadDidFinish(_ download: WKDownload) {
        let head = (try? FileHandle(forReadingFrom: out))?.readData(ofLength: 5) ?? Data()
        if String(decoding: head, as: UTF8.self).hasPrefix("%PDF") || !out.pathExtension.lowercased().hasSuffix("pdf") { print("saved \(out.path)"); exit(0) }
        FileHandle.standardError.write("downloaded file is not a PDF\n".data(using: .utf8)!); exit(5)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { FileHandle.standardError.write("download failed: \(error.localizedDescription)\n".data(using: .utf8)!); exit(4) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigations += 1
        if linksMode {
            // Give client-side rendering a moment, then list every PDF-looking link (href, embed, iframe, object).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let js = """
                Array.from(new Set(Array.from(document.querySelectorAll('a[href], embed[src], iframe[src], object[data]'))
                  .map(e => e.href || e.src || e.data).filter(u => u && /\\.pdf(\\?|#|$)/i.test(u)))).join('\\n')
                """
                webView.evaluateJavaScript(js) { result, _ in
                    print((result as? String) ?? "")
                    exit((result as? String)?.isEmpty == false ? 0 : 5)
                }
            }
            return
        }
        // A challenge page finished loading; its script usually reloads to the real URL within a few seconds.
        FileHandle.standardError.write("page loaded (\(navigations)) \(webView.url?.absoluteString ?? ""), waiting for challenge/redirect…\n".data(using: .utf8)!)
        if navigations >= 6 { FileHandle.standardError.write("too many HTML pages; not a file\n".data(using: .utf8)!); exit(5) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    func report(_ error: Error) {
        let ns = error as NSError
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return } // "Frame load interrupted" = download took over
        FileHandle.standardError.write("navigation failed: \(error.localizedDescription)\n".data(using: .utf8)!); exit(4)
    }
}

let fetcher = Fetcher(url: startURL, out: outputURL)
fetcher.start()
DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { FileHandle.standardError.write("timed out after \(Int(timeout))s\n".data(using: .utf8)!); exit(3) }
RunLoop.main.run()
