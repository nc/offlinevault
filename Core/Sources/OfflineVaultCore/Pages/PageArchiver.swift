import Foundation

/// Captures a webpage into a single self-contained HTML file: stylesheets and images are inlined as data URIs,
/// scripts/iframes/trackers are removed, and a Content-Security-Policy forbids all network access on render.
/// (OfflineVault's own pipeline in the spirit of SingleFile / monolith; see README › Webpage capture.)
public struct PageArchiver: Sendable {
    public struct Options: Sendable {
        public var maxAssetBytes: Int = 8 * 1024 * 1024
        public var maxTotalAssetBytes: Int = 40 * 1024 * 1024
        public var userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 OfflineVault/1.0"
        public var timeout: TimeInterval = 30
        public init() {}
    }

    public struct Capture: Sendable {
        public var html: String
        public var title: String
        public var text: String
        public var finalURL: URL
        public var assetCount: Int
        public var assetBytes: Int
    }

    public let options: Options
    public let fetcher: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(options: Options = Options(), fetcher: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil) {
        self.options = options
        self.fetcher = fetcher ?? { req in try await URLSession.shared.data(for: req) }
    }

    public func capture(_ url: URL) async throws -> Capture {
        let (data, response) = try await fetch(url)
        guard let http = response as? HTTPURLResponse else { throw UserFacingError("Capture failed", message: "\(url.host ?? url.absoluteString) did not return an HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            throw UserFacingError("Capture failed", message: "\(url.host ?? "The site") answered HTTP \(http.statusCode).", recovery: "Check the address opens in a browser, then try again.")
        }
        let finalURL = http.url ?? url
        let encoding = Self.encoding(from: http, data: data)
        guard let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1) else {
            throw UserFacingError("Capture failed", message: "The page could not be decoded as text.")
        }
        return try await archive(html: html, baseURL: finalURL)
    }

    /// Rewrites `html` fetched from `baseURL` into a self-contained document (network fetches for assets go through `fetcher`).
    public func archive(html: String, baseURL: URL) async throws -> Capture {
        let tokens = HTMLTokenizer.tokenize(html)
        var base = baseURL
        if let b = tokens.lazy.compactMap({ t -> String? in if case .startTag("base", let a, _) = t { return a.first { $0.name == "href" }?.value }; return nil }).first, let u = URL(string: b, relativeTo: baseURL) { base = u.absoluteURL }

        var out: [HTMLToken] = []
        out.reserveCapacity(tokens.count)
        var assetCount = 0, assetBytes = 0
        var skipUntil: String? = nil
        var cache: [URL: String] = [:]

        func inline(_ ref: String, allowStylesheet: Bool = false) async -> String? {
            guard let u = Self.resolve(ref, base: base), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return nil }
            if let hit = cache[u] { return hit }
            guard assetBytes < options.maxTotalAssetBytes else { return nil }
            guard let (d, r) = try? await fetch(u), let http = r as? HTTPURLResponse, (200..<300).contains(http.statusCode), d.count <= options.maxAssetBytes else { return nil }
            let mime = Self.mime(from: http, url: u)
            let uri: String
            if mime.hasPrefix("text/css") {
                let css = String(data: d, encoding: .utf8) ?? ""
                let rewritten = await inlineCSS(css, base: u)
                uri = rewritten
            } else {
                uri = "data:\(mime);base64," + d.base64EncodedString()
            }
            assetCount += 1; assetBytes += d.count
            cache[u] = uri
            return uri
        }

        func inlineCSS(_ css: String, base cssBase: URL) async -> String {
            var result = css
            // url(...) references
            let pattern = try! NSRegularExpression(pattern: "url\\(\\s*['\"]?([^'\")]+)['\"]?\\s*\\)", options: [])
            let matches = pattern.matches(in: css, range: NSRange(css.startIndex..., in: css))
            var replacements: [(Range<String.Index>, String)] = []
            for m in matches {
                guard let r = Range(m.range(at: 1), in: css), let whole = Range(m.range, in: css) else { continue }
                let ref = String(css[r])
                if ref.hasPrefix("data:") { continue }
                guard let u = Self.resolve(ref, base: cssBase), let (d, resp) = try? await fetch(u), let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), d.count <= options.maxAssetBytes, assetBytes < options.maxTotalAssetBytes else {
                    replacements.append((whole, "url(about:blank)")); continue
                }
                assetCount += 1; assetBytes += d.count
                replacements.append((whole, "url(data:\(Self.mime(from: http, url: u));base64,\(d.base64EncodedString()))"))
            }
            for (range, rep) in replacements.reversed() { result.replaceSubrange(range, with: rep) }
            // @import rules (one level)
            let imp = try! NSRegularExpression(pattern: "@import\\s+(?:url\\()?['\"]?([^'\");]+)['\"]?\\)?[^;]*;", options: [])
            let imps = imp.matches(in: result, range: NSRange(result.startIndex..., in: result))
            var impReps: [(Range<String.Index>, String)] = []
            for m in imps {
                guard let r = Range(m.range(at: 1), in: result), let whole = Range(m.range, in: result), let u = Self.resolve(String(result[r]), base: cssBase) else { continue }
                if let (d, resp) = try? await fetch(u), let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), let s = String(data: d, encoding: .utf8) {
                    assetCount += 1; assetBytes += d.count
                    impReps.append((whole, "/* imported from \(u.absoluteString) */\n" + s))
                } else { impReps.append((whole, "")) }
            }
            for (range, rep) in impReps.reversed() { result.replaceSubrange(range, with: rep) }
            return result
        }

        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            defer { i += 1 }
            if let s = skipUntil {
                if case .endTag(let n) = t, n == s { skipUntil = nil }
                continue
            }
            switch t {
            case .comment: continue
            case .rawText(let el, let content):
                if el == "style" { out.append(.rawText(element: el, content: await inlineCSS(content, base: base))) } else { out.append(t) }
            case .startTag(let name, var attrs, let selfClosing):
                switch name {
                case "script", "iframe", "object", "embed", "noscript", "template", "applet":
                    if !selfClosing { skipUntil = name }
                    continue
                case "base": continue
                case "link":
                    let rel = (attrs.first { $0.name == "rel" }?.value ?? "").lowercased()
                    if rel.contains("stylesheet"), let href = attrs.first(where: { $0.name == "href" })?.value {
                        if let css = await inline(href, allowStylesheet: true) {
                            let media = attrs.first { $0.name == "media" }?.value
                            out.append(.startTag(name: "style", attributes: media.map { [.init(name: "media", value: $0)] } ?? [], selfClosing: false))
                            out.append(.rawText(element: "style", content: css))
                            out.append(.endTag(name: "style"))
                        }
                        continue
                    }
                    if rel.contains("icon"), let href = attrs.first(where: { $0.name == "href" })?.value, let d = await inline(href) {
                        attrs = attrs.map { $0.name == "href" ? .init(name: "href", value: d) : $0 }
                        out.append(.startTag(name: name, attributes: attrs, selfClosing: true)); continue
                    }
                    continue // preload, prefetch, dns-prefetch, manifest, alternate, canonical … all dropped
                case "meta":
                    let he = (attrs.first { $0.name == "http-equiv" }?.value ?? "").lowercased()
                    if he == "refresh" || he == "content-security-policy" { continue }
                    if let n = attrs.first(where: { $0.name == "name" })?.value?.lowercased(), n == "referrer" { continue }
                case "img", "source", "video", "audio", "track", "input":
                    attrs.removeAll { $0.name == "srcset" || $0.name == "sizes" || $0.name.hasPrefix("data-src") && false }
                    if let src = attrs.first(where: { $0.name == "src" })?.value {
                        if name == "img" || name == "input" || name == "track" || name == "source" {
                            if let d = await inline(src) { attrs = attrs.map { $0.name == "src" ? .init(name: "src", value: d) : $0 } }
                            else if let abs = Self.resolve(src, base: base) { attrs = attrs.map { $0.name == "src" ? .init(name: "src", value: abs.absoluteString) : $0 } }
                        } else if let abs = Self.resolve(src, base: base) {
                            attrs = attrs.map { $0.name == "src" ? .init(name: "src", value: abs.absoluteString) : $0 }
                        }
                    }
                    if let poster = attrs.first(where: { $0.name == "poster" })?.value, let d = await inline(poster) { attrs = attrs.map { $0.name == "poster" ? .init(name: "poster", value: d) : $0 } }
                    if name == "img", let ds = attrs.first(where: { $0.name == "data-src" })?.value, attrs.first(where: { $0.name == "src" }) == nil, let d = await inline(ds) { attrs.append(.init(name: "src", value: d)) }
                case "a", "area":
                    if let href = attrs.first(where: { $0.name == "href" })?.value, !href.hasPrefix("#"), let abs = Self.resolve(href, base: base) {
                        attrs = attrs.map { $0.name == "href" ? .init(name: "href", value: abs.absoluteString) : $0 }
                    }
                    attrs.removeAll { $0.name == "ping" }
                case "form":
                    attrs.removeAll { $0.name == "action" }
                default: break
                }
                // strip inline event handlers and javascript: URLs
                attrs.removeAll { $0.name.hasPrefix("on") }
                attrs = attrs.filter { !($0.value?.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix("javascript:") ?? false) }
                // inline style url()s
                if let idx = attrs.firstIndex(where: { $0.name == "style" }), let v = attrs[idx].value, v.contains("url(") {
                    attrs[idx].value = await inlineCSS(v, base: base)
                }
                out.append(.startTag(name: name, attributes: attrs, selfClosing: selfClosing))
                if name == "head" {
                    out.append(.text("\n"))
                    out.append(.startTag(name: "meta", attributes: [.init(name: "http-equiv", value: "Content-Security-Policy"), .init(name: "content", value: Self.csp)], selfClosing: true))
                    out.append(.startTag(name: "meta", attributes: [.init(name: "name", value: "offlinevault-source"), .init(name: "content", value: base.absoluteString)], selfClosing: true))
                    out.append(.startTag(name: "meta", attributes: [.init(name: "name", value: "offlinevault-captured"), .init(name: "content", value: ISO8601DateFormatter().string(from: Date()))], selfClosing: true))
                    out.append(.text("\n"))
                }
            default:
                out.append(t)
            }
        }
        if !out.contains(where: { if case .startTag("head", _, _) = $0 { return true }; return false }) {
            out.insert(.startTag(name: "meta", attributes: [.init(name: "http-equiv", value: "Content-Security-Policy"), .init(name: "content", value: Self.csp)], selfClosing: true), at: 0)
        }
        let result = HTMLTokenizer.serialize(out)
        let extraction = HTMLText.extract(from: html)
        return Capture(html: result, title: extraction.title.isEmpty ? (baseURL.host ?? baseURL.absoluteString) : extraction.title, text: extraction.body, finalURL: baseURL, assetCount: assetCount, assetBytes: assetBytes)
    }

    public static let csp = "default-src 'none'; img-src data: blob:; style-src 'unsafe-inline' data:; font-src data:; media-src data: blob:; frame-src 'none'; connect-src 'none'; form-action 'none'"

    private func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.timeoutInterval = options.timeout
        req.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return try await fetcher(req)
    }

    static func resolve(_ ref: String, base: URL) -> URL? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("data:"), !trimmed.hasPrefix("javascript:"), !trimmed.hasPrefix("blob:"), !trimmed.hasPrefix("#") else { return nil }
        if trimmed.hasPrefix("//") { return URL(string: (base.scheme ?? "https") + ":" + trimmed) }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL ?? URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed, relativeTo: base)?.absoluteURL
    }

    static func mime(from http: HTTPURLResponse, url: URL) -> String {
        if let ct = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }), !ct.isEmpty, ct != "application/octet-stream" { return ct }
        switch url.pathExtension.lowercased() {
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }

    static func encoding(from http: HTTPURLResponse, data: Data) -> String.Encoding {
        if let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(), let r = ct.range(of: "charset=") {
            let cs = ct[r.upperBound...].split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") } ?? ""
            if cs.contains("8859-1") || cs == "latin1" { return .isoLatin1 }
            if cs.contains("1252") { return .windowsCP1252 }
        }
        if let head = String(data: data.prefix(2048), encoding: .ascii)?.lowercased(), head.contains("charset=iso-8859-1") { return .isoLatin1 }
        return .utf8
    }
}
