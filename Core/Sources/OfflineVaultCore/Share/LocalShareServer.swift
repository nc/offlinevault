import Foundation
import Network

/// Serves the library to phones and tablets on the local Wi-Fi: a landing page, documents, pages and videos
/// (with HTTP range support so video scrubs), plus a link to kiwix-serve for the reference books. Read-only, GET
/// only, no directory traversal. Off by default; the user turns it on in Settings › Share.
public final class LocalShareServer: @unchecked Sendable {
    public let layout: LibraryLayout
    public let database: IndexDatabase
    public let kiwixPort: Int
    public let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.offlinevault.share")
    private let lock = NSLock()
    private var _isRunning = false
    public var isRunning: Bool { lock.withLock { _isRunning } }

    public init(layout: LibraryLayout, database: IndexDatabase, kiwixPort: Int = Config.kiwixPort, port: UInt16 = 8780) {
        self.layout = layout; self.database = database; self.kiwixPort = kiwixPort; self.port = port
    }

    public func start() throws {
        guard !isRunning else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.lock.withLock { self?._isRunning = true } }
            if case .failed = state { self?.lock.withLock { self?._isRunning = false } }
            if case .cancelled = state { self?.lock.withLock { self?._isRunning = false } }
        }
        l.start(queue: queue)
        listener = l
        lock.withLock { _isRunning = true }
    }

    public func stop() { listener?.cancel(); listener = nil; lock.withLock { _isRunning = false } }

    /// IPv4 addresses of this Mac on local interfaces (Wi-Fi / Ethernet), for the "open this on your phone" URL.
    public static func localAddresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let name = String(cString: ptr.pointee.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") { out.append(String(cString: host)) }
            }
        }
        return out
    }

    // MARK: Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                self.respond(conn, requestHead: head)
            } else if error != nil || isComplete || buf.count > 64 * 1024 {
                conn.cancel()
            } else {
                self.receiveRequest(conn, buffer: buf)
            }
        }
    }

    struct Response { var status: Int; var headers: [String: String]; var body: Data?; var file: URL?; var range: Range<Int64>?; var fileSize: Int64 = 0 }

    private func respond(_ conn: NWConnection, requestHead: String) {
        let lines = requestHead.split(separator: "\r\n").map(String.init)
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return send(conn, Response(status: 405, headers: ["Content-Type": "text/plain"], body: Data("Method not allowed".utf8))); }
        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }?.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
        var resp = route(path: parts[1], rangeHeader: rangeHeader)
        if parts[0] == "HEAD" { resp.body = nil; resp.file = nil }
        send(conn, resp)
    }

    func route(path rawPath: String, rangeHeader: String?) -> Response {
        let path = (rawPath.split(separator: "?").first.map(String.init) ?? rawPath).removingPercentEncoding ?? rawPath
        if path == "/" || path == "/index.html" { return Response(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(landingPage().utf8)) }
        if path.hasPrefix("/search") {
            let q = rawPath.split(separator: "?").dropFirst().joined().split(separator: "&").first { $0.hasPrefix("q=") }.map { String($0.dropFirst(2)).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" } ?? ""
            return Response(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(searchPage(q).utf8))
        }
        let folders: [(String, URL)] = [("/documents/", layout.documents), ("/pages/", layout.pages), ("/videos/", layout.videos), ("/maps/", layout.maps)]
        for (prefix, dir) in folders where path.hasPrefix(prefix) {
            let name = String(path.dropFirst(prefix.count))
            guard !name.contains("..") && !name.isEmpty && !name.hasPrefix(".") else { return Response(status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not found".utf8)) }
            let file = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path), let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) else { return Response(status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not found".utf8)) }
            var headers = ["Content-Type": Self.mime(for: file), "Accept-Ranges": "bytes"]
            if let rh = rangeHeader, rh.hasPrefix("bytes="), let r = Self.parseRange(rh, size: size) {
                headers["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(size)"
                return Response(status: 206, headers: headers, body: nil, file: file, range: r, fileSize: size)
            }
            return Response(status: 200, headers: headers, body: nil, file: file, range: 0..<size, fileSize: size)
        }
        return Response(status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not found".utf8))
    }

    public static func parseRange(_ h: String, size: Int64) -> Range<Int64>? {
        let spec = h.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        if let s = Int64(parts[0]) { let e = Int64(parts[1]) ?? (size - 1); guard s < size else { return nil }; return s..<min(e + 1, size) }
        if let suffix = Int64(parts[1]) { return max(0, size - suffix)..<size }
        return nil
    }

    static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"; case "html", "htm": return "text/html; charset=utf-8"; case "mp4", "m4v": return "video/mp4"; case "mov": return "video/quicktime"; case "webm": return "video/webm"; case "mkv": return "video/x-matroska"
        case "vtt": return "text/vtt"; case "jpg", "jpeg": return "image/jpeg"; case "png": return "image/png"; case "json": return "application/json"; case "epub": return "application/epub+zip"; case "txt", "md": return "text/plain; charset=utf-8"; case "pmtiles": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }

    private func send(_ conn: NWConnection, _ r: Response) {
        var head = "HTTP/1.1 \(r.status) \(r.status == 200 ? "OK" : r.status == 206 ? "Partial Content" : r.status == 404 ? "Not Found" : "Error")\r\n"
        var headers = r.headers
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        let length: Int64 = r.body.map { Int64($0.count) } ?? r.range.map { $0.upperBound - $0.lowerBound } ?? 0
        headers["Content-Length"] = String(length)
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            if let body = r.body { conn.send(content: body, completion: .contentProcessed { _ in conn.cancel() }); return }
            guard let file = r.file, let range = r.range, let h = try? FileHandle(forReadingFrom: file) else { conn.cancel(); return }
            self.stream(h, from: range.lowerBound, remaining: range.upperBound - range.lowerBound, over: conn)
        })
    }

    private func stream(_ h: FileHandle, from offset: Int64, remaining: Int64, over conn: NWConnection) {
        guard remaining > 0 else { try? h.close(); conn.cancel(); return }
        do { try h.seek(toOffset: UInt64(offset)) } catch { conn.cancel(); return }
        let chunkSize = Int(min(remaining, 1 << 20))
        guard let chunk = try? h.read(upToCount: chunkSize), !chunk.isEmpty else { try? h.close(); conn.cancel(); return }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil { try? h.close(); conn.cancel(); return }
            self?.stream(h, from: offset + Int64(chunk.count), remaining: remaining - Int64(chunk.count), over: conn)
        })
    }

    // MARK: Pages

    func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;") }
    static let css = "body{font-family:-apple-system,system-ui,sans-serif;max-width:52em;margin:1.5em auto;padding:0 1em;line-height:1.5;background:#fafaf7;color:#222} h1{font-size:1.4em} h2{font-size:1.1em;margin-top:1.5em;border-bottom:1px solid #ddd} a{color:#0a5} li{margin:.25em 0} .meta{color:#666;font-size:.9em} input{width:100%;padding:.6em;font-size:1em} .card{background:#fff;border:1px solid #e5e5e0;border-radius:8px;padding:.8em 1em;margin:.6em 0}"

    func landingPage() -> String {
        let docs = (try? database.db.query("SELECT file_name, title, publisher, page_count, kind FROM documents ORDER BY title")) ?? []
        let pages = (try? database.db.query("SELECT file_name, title, url FROM pages ORDER BY title")) ?? []
        let videos = (try? database.db.query("SELECT file_name, title, channel, subtitle_file FROM videos WHERE status = 'downloaded' ORDER BY title")) ?? []
        let books = (try? database.zimBooks()) ?? []
        var h = "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>OfflineVault</title><style>\(Self.css)</style></head><body>"
        h += "<h1>OfflineVault library</h1><p class=meta>Shared read-only from this Mac over the local network. Nothing here needs the internet.</p>"
        h += "<form action=/search><input name=q placeholder='Search manuals, pages and transcripts…' autofocus></form>"
        if !books.isEmpty {
            h += "<h2>Reference books</h2><ul>" + books.map { "<li><a href=\"http://HOST:\(kiwixPort)/content/\(esc($0.name))/\">\(esc($0.displayTitle))</a>" + ($0.freshnessLabel.map { " <span class=meta>· \($0)</span>" } ?? "") + "</li>" }.joined() + "</ul>"
        }
        h += "<h2>Manuals and documents (\(docs.count))</h2><ul>" + docs.map { r in "<li><a href=\"/documents/\(esc(r.string("file_name") ?? ""))\">\(esc(r.string("title") ?? ""))</a> <span class=meta>\(esc(r.string("publisher") ?? "")) · \(r.int("page_count") ?? 0) \(r.string("kind") == "epub" ? "chapters" : "pages")</span></li>" }.joined() + "</ul>"
        h += "<h2>Saved pages (\(pages.count))</h2><ul>" + pages.map { r in "<li><a href=\"/pages/\(esc(r.string("file_name") ?? ""))\">\(esc(r.string("title") ?? ""))</a></li>" }.joined() + "</ul>"
        h += "<h2>Videos (\(videos.count))</h2><ul>" + videos.map { r in "<li><a href=\"/videos/\(esc(r.string("file_name") ?? ""))\">\(esc(r.string("title") ?? ""))</a> <span class=meta>\(esc(r.string("channel") ?? ""))</span></li>" }.joined() + "</ul>"
        h += "<p class=meta>Reference-book links open the Kiwix engine on port \(kiwixPort) of this Mac.</p></body></html>"
        return h.replacingOccurrences(of: "HOST", with: Self.localAddresses().first ?? "127.0.0.1")
    }

    func searchPage(_ q: String) -> String {
        var h = "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Search – OfflineVault</title><style>\(Self.css)</style></head><body><h1><a href=/>OfflineVault</a> › Search</h1><form action=/search><input name=q value=\"\(esc(q))\"></form>"
        let docs = DocumentService(layout: layout, database: database)
        let pages = PageService(layout: layout, database: database)
        let videos = VideoLibraryService(layout: layout, database: database)
        if let hits = try? docs.search(q, limit: 15), !hits.isEmpty {
            h += "<h2>Documents</h2>" + hits.map { "<div class=card><a href=\"/documents/\(esc($0.document.fileName))#page=\($0.page)\"><b>\(esc($0.document.title))</b> · \($0.document.unitLabel) \($0.page)</a><br><span class=meta>\($0.snippet.replacingOccurrences(of: "«", with: "<b>").replacingOccurrences(of: "»", with: "</b>"))</span></div>" }.joined()
        }
        if let hits = try? pages.search(q, limit: 10), !hits.isEmpty {
            h += "<h2>Saved pages</h2>" + hits.map { "<div class=card><a href=\"/pages/\(esc($0.page.fileName))\"><b>\(esc($0.page.title))</b></a><br><span class=meta>\($0.snippet.replacingOccurrences(of: "«", with: "<b>").replacingOccurrences(of: "»", with: "</b>"))</span></div>" }.joined()
        }
        if let hits = try? videos.searchTranscripts(q, limit: 10), !hits.isEmpty {
            h += "<h2>Video transcripts</h2>" + hits.map { "<div class=card><a href=\"/videos/\(esc($0.video.fileName ?? ""))#t=\(Int($0.startSeconds))\"><b>\(esc($0.video.title))</b> · \(DurationFormat.string($0.startSeconds))</a><br><span class=meta>\(esc(String($0.text.prefix(220))))</span></div>" }.joined()
        }
        if !q.isEmpty && !h.contains("<div class=card>") { h += "<p>No matches in manuals, pages or transcripts. Try the <a href=\"http://\(Self.localAddresses().first ?? "127.0.0.1"):\(kiwixPort)/search?pattern=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)\">reference books</a>.</p>" }
        return h + "</body></html>"
    }
}
