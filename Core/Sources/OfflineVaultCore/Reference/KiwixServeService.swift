import Foundation

/// `ReferenceLibraryService` backed by a managed `kiwix-serve` subprocess on localhost.
///
/// Note: kiwix-tools publishes macOS builds for x86_64 only (3.8.2). Releases bundle an arm64 build from source; when the
/// bundled binary is x86_64 (`fetch_binaries.sh --allow-rosetta`) it runs through `/usr/bin/arch -x86_64` (Rosetta 2).
public final class KiwixServeService: ReferenceLibraryService, @unchecked Sendable {
    public let port: Int
    public let baseURL: URL
    private let lock = NSLock()
    private var process: ManagedProcess?
    private var servedFiles: [URL] = []
    public var engineDescription: String { "kiwix-serve (libkiwix) on 127.0.0.1:\(port)" }
    public var processState: ManagedProcess.State { process?.state ?? .stopped }
    public var recentOutput: String { process?.recentOutput ?? "" }
    public var stateObserver: (@Sendable (ManagedProcess.State) -> Void)?
    /// When sharing to the local network, kiwix-serve binds to all interfaces instead of loopback.
    public var listenOnAllInterfaces = false

    public init(port: Int = Config.kiwixPort) {
        self.port = port
        self.baseURL = URL(string: "http://127.0.0.1:\(port)/")!
    }

    public var isRunning: Bool { process?.state == .running }
    public var currentFiles: [URL] { lock.withLock { servedFiles } }
    /// Files excluded from the last start because they failed validation or kiwix-serve refused them, with the reason.
    public private(set) var damagedFiles: [URL: String] = [:]

    /// Starts kiwix-serve with every ZIM that passes a structural check. If kiwix-serve still rejects a file at
    /// startup, that file is excluded and the server is started again, so one bad book never takes down the rest.
    public func start(zimFiles: [URL]) async throws {
        var files = zimFiles.filter { FileManager.default.fileExists(atPath: $0.path) }.sorted { $0.path < $1.path }
        var damaged: [URL: String] = [:]
        for f in files { if case .damaged(let why) = ZimValidator.validate(f) { damaged[f] = why } }
        files.removeAll { damaged[$0] != nil }
        if isRunning, lock.withLock({ servedFiles }) == files { lock.withLock { damagedFiles = damaged }; return }
        stop()
        var attempts = 0
        while true {
            attempts += 1
            lock.withLock { damagedFiles = damaged }
            guard !files.isEmpty else { return } // nothing to serve; kiwix-serve refuses to start without books
            let exe = try HelperBinary.kiwixServe.require()
            let url = baseURL
            var args = ["--port=\(port)", "--address=\(listenOnAllInterfaces ? "0.0.0.0" : "127.0.0.1")", "--threads=4", "--nodatealiases", "--blockexternal"]
            args += files.map(\.path)
            let spec = ManagedProcess.Spec(name: "kiwix-serve", executable: exe, arguments: args,
                                           healthCheck: { await LocalHTTP.isHealthy(url.appendingPathComponent("catalog/v2/root.xml")) },
                                           startupTimeout: 45, autoRestart: true)
            let p = ManagedProcess(spec: spec)
            if let obs = stateObserver { p.observeState(obs) }
            lock.withLock { process = p; servedFiles = files }
            do {
                try await p.start()
                return
            } catch {
                // kiwix-serve names the file it could not load; drop it and try once more per bad file.
                if let bad = ZimValidator.failedFile(inKiwixOutput: p.recentOutput), let url = files.first(where: { $0.path == bad }), attempts <= zimFiles.count {
                    damaged[url] = "kiwix-serve could not load this file (corrupt or incomplete)"
                    files.removeAll { $0 == url }
                    lock.withLock { process = nil }
                    continue
                }
                throw error
            }
        }
    }

    public func stop() {
        let p: ManagedProcess? = lock.withLock { let x = process; process = nil; servedFiles = []; return x }
        p?.stop()
    }

    // MARK: Catalogue (OPDS)

    public func books() async throws -> [ReferenceBook] {
        guard isRunning else { return [] }
        let (data, http) = try await LocalHTTP.get(baseURL.appendingPathComponent("catalog/v2/entries").appending(queryItems: [URLQueryItem(name: "count", value: "-1")]))
        guard http.statusCode == 200 else { throw UserFacingError("Reference library unavailable", message: "kiwix-serve answered HTTP \(http.statusCode) for its catalogue.", recovery: "Restart the reference library from Settings › Diagnostics.") }
        return OPDSParser.parse(data)
    }

    // MARK: Search

    /// kiwix-serve 3.8.2 corrupts its heap when searches run concurrently, so searches run one at a time.
    private let searchGate = SerialGate()

    public func search(_ query: String, books: [String]?, limit: Int) async throws -> [ReferenceHit] {
        guard isRunning else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let names: [String]
        if let books, !books.isEmpty { names = books } else { names = try await self.books().map(\.name) }
        guard !names.isEmpty else { return [] }
        if let hits = try await searchRequest(trimmed, books: names, limit: limit) { return hits }
        // Multi-book search can fail on mixed-language libraries; fall back to per-book searches.
        guard names.count > 1 else { return [] }
        var all: [ReferenceHit] = []
        for n in names { all += try await searchRequest(trimmed, books: [n], limit: limit) ?? [] }
        return Array(all.prefix(limit))
    }

    /// One `/search` request under the gate; nil when kiwix-serve answered with an error status.
    private func searchRequest(_ pattern: String, books names: [String], limit: Int) async throws -> [ReferenceHit]? {
        var items = [URLQueryItem(name: "pattern", value: pattern), URLQueryItem(name: "pageLength", value: String(limit)), URLQueryItem(name: "format", value: "xml")]
        items += names.map { URLQueryItem(name: "books.name", value: $0) }
        let url = baseURL.appendingPathComponent("search").appending(queryItems: items)
        await searchGate.enter()
        defer { Task { await searchGate.leave() } }
        let (data, http) = try await LocalHTTP.get(url)
        guard http.statusCode == 200 else { return nil }
        return KiwixSearchParser.parse(data, fallbackBook: names.count == 1 ? names[0] : nil)
    }

    public func articleText(bookName: String, path: String) async throws -> String {
        let (data, http) = try await LocalHTTP.get(articleURL(bookName: bookName, path: path))
        guard http.statusCode == 200, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return "" }
        return HTMLText.extract(from: html).body
    }

    public func articleURL(bookName: String, path: String) -> URL {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        let encoded = p.split(separator: "/", omittingEmptySubsequences: false).map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "content/\(bookName)/\(encoded)", relativeTo: baseURL)!.absoluteURL
    }

    public func mainPageURL(bookName: String) -> URL {
        URL(string: "content/\(bookName)/", relativeTo: baseURL)!.absoluteURL
    }
}

/// Parses kiwix-serve's OPDS catalogue (`/catalog/v2/entries`).
public final class OPDSParser: NSObject, XMLParserDelegate {
    private var books: [ReferenceBook] = []
    private var current: [String: String] = [:]
    private var text = ""
    private var inEntry = false
    private var openHref: String?

    public static func parse(_ data: Data) -> [ReferenceBook] {
        let p = OPDSParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.books
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if local == "entry" { inEntry = true; current = [:]; openHref = nil }
        // kiwix-serve exposes the URL book name only through the content link (`/content/<bookName>`);
        // the <name> element is the ZIM's metadata Name, which can differ from the file-derived name.
        if inEntry && local == "link", let href = attributes["href"], href.hasPrefix("/content/") || attributes["rel"] == "http://opds-spec.org/acquisition/open-access" { openHref = href }
        text = ""
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        guard inEntry else { return }
        if local == "entry" {
            inEntry = false
            var bookName = ""
            if let href = openHref {
                bookName = href.replacingOccurrences(of: "/content/", with: "").split(separator: "/").first.map(String.init) ?? ""
            }
            if bookName.isEmpty { bookName = current["name"] ?? "" }
            guard !bookName.isEmpty else { return }
            books.append(ReferenceBook(name: bookName, title: current["title"] ?? bookName, description: current["summary"], language: current["language"],
                                       articleCount: current["articleCount"].flatMap { Int64($0) }, mediaCount: current["mediaCount"].flatMap { Int64($0) },
                                       updated: current["updated"].map { String($0.prefix(10)) }))
        } else {
            current[local] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Parses kiwix-serve's `/search?format=xml` RSS output.
public final class KiwixSearchParser: NSObject, XMLParserDelegate {
    private var hits: [ReferenceHit] = []
    private var current: [String: String] = [:]
    private var text = ""
    private var inItem = false
    private var depthInBook = 0
    private let fallbackBook: String?

    init(fallbackBook: String?) { self.fallbackBook = fallbackBook }

    public static func parse(_ data: Data, fallbackBook: String?) -> [ReferenceHit] {
        let p = KiwixSearchParser(fallbackBook: fallbackBook)
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.hits
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "item" { inItem = true; current = [:] }
        if inItem && name == "book" { depthInBook += 1 }
        text = ""
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "book" && inItem { depthInBook -= 1; return }
        guard inItem else { return }
        if name == "item" {
            inItem = false
            let link = current["link"] ?? ""
            let (book, path) = Self.split(link: link)
            guard let bookName = book ?? fallbackBook else { return }
            hits.append(ReferenceHit(bookName: bookName, title: current["title"] ?? path, path: path, snippet: Self.clean(current["description"] ?? ""), wordCount: current["wordCount"].flatMap { Int($0) }))
        } else if depthInBook == 0 {
            current[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// `/content/<book>/<path>` → (book, path); also accepts `/<book>/<path>` and absolute URLs.
    static func split(link: String) -> (String?, String) {
        var s = link
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]); if let slash = s.firstIndex(of: "/") { s = String(s[slash...]) } }
        if s.hasPrefix("/content/") { s.removeFirst("/content/".count) } else if s.hasPrefix("/") { s.removeFirst() }
        let decoded = s.removingPercentEncoding ?? s
        guard let slash = decoded.firstIndex(of: "/") else { return (nil, decoded) }
        return (String(decoded[..<slash]), String(decoded[decoded.index(after: slash)...]))
    }

    static func clean(_ html: String) -> String {
        HTMLText.decodeEntities(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }
    func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
