import Foundation

/// A captured page as stored in the index.
public struct SavedPage: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var url: URL
    public var title: String
    public var fileName: String
    public var capturedAt: Date
    public var sizeBytes: Int64
    public var textLength: Int64
    public var excerpt: String
    public var lastError: String?

    init(row: SQLiteDatabase.Row) {
        id = row.string("id") ?? ""
        url = URL(string: row.string("url") ?? "") ?? URL(string: "about:blank")!
        title = row.string("title") ?? ""
        fileName = row.string("file_name") ?? ""
        capturedAt = row.date("captured_at") ?? Date()
        sizeBytes = row.int("size_bytes") ?? 0
        textLength = row.int("text_length") ?? 0
        excerpt = row.string("excerpt") ?? ""
        lastError = row.string("last_error")
    }
}

/// Sidecar metadata written next to each captured page (`<id>.json`).
public struct PageSidecar: Codable, Equatable, Sendable {
    public var id: String
    public var url: String
    public var title: String
    public var capturedAt: Date
    public var assetCount: Int
    public init(id: String, url: String, title: String, capturedAt: Date, assetCount: Int) { self.id = id; self.url = url; self.title = title; self.capturedAt = capturedAt; self.assetCount = assetCount }
}

/// Captures, stores, indexes and searches user-added webpages.
public final class PageService: @unchecked Sendable {
    public let layout: LibraryLayout
    public let database: IndexDatabase
    public let archiver: PageArchiver

    public init(layout: LibraryLayout, database: IndexDatabase, archiver: PageArchiver = PageArchiver()) {
        self.layout = layout; self.database = database; self.archiver = archiver
    }

    public func pages() throws -> [SavedPage] {
        try database.db.query("SELECT * FROM pages ORDER BY captured_at DESC").map(SavedPage.init(row:))
    }

    public func page(id: String) throws -> SavedPage? {
        try database.db.query("SELECT * FROM pages WHERE id = ?", [.text(id)]).first.map(SavedPage.init(row:))
    }

    public func fileURL(for page: SavedPage) -> URL { layout.pages.appendingPathComponent(page.fileName) }

    public static func pageId(for url: URL) -> String {
        Checksum.sha256Hex(of: Data(url.absoluteString.utf8)).prefix(16).description
    }

    /// Captures `url` (online) and stores it. If the same URL was captured before, the previous capture is kept until the new one succeeds.
    @discardableResult
    public func capture(_ url: URL) async throws -> SavedPage {
        let id = Self.pageId(for: url)
        let capture = try await archiver.capture(url)
        try layout.ensureDirectories()
        let fileName = id + ".html"
        let dest = layout.pages.appendingPathComponent(fileName)
        let tmp = layout.staging.appendingPathComponent(fileName + ".part")
        try capture.html.write(to: tmp, atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: dest.path) { _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp) } else { try FileManager.default.moveItem(at: tmp, to: dest) }
        let sidecar = PageSidecar(id: id, url: url.absoluteString, title: capture.title, capturedAt: Date(), assetCount: capture.assetCount)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(sidecar).write(to: layout.pages.appendingPathComponent(id + ".json"), options: .atomic)
        try index(id: id, url: url, title: capture.title, text: capture.text, fileName: fileName, capturedAt: sidecar.capturedAt)
        return try page(id: id)!
    }

    /// Refreshes from source; on failure the previous capture stays and the error is recorded.
    @discardableResult
    public func refresh(_ page: SavedPage) async throws -> SavedPage {
        do {
            return try await capture(page.url)
        } catch {
            try? database.db.execute("UPDATE pages SET last_error = ? WHERE id = ?", [.text(error.userFacing.message), .text(page.id)])
            throw error
        }
    }

    /// Indexes a page already present on disk (used when a page-pack is installed or the folder is rescanned).
    public func indexExistingFile(_ file: URL, url: URL?, title: String?, capturedAt: Date = Date()) throws {
        let html = try String(contentsOf: file, encoding: .utf8)
        let ex = HTMLText.extract(from: html)
        let src = url ?? Self.sourceURL(fromHTML: html) ?? URL(string: "file://" + file.path)!
        let id = Self.pageId(for: src)
        if file.lastPathComponent != id + ".html" {
            let dest = layout.pages.appendingPathComponent(id + ".html")
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: file, to: dest)
        }
        try index(id: id, url: src, title: title ?? ex.title, text: ex.body, fileName: id + ".html", capturedAt: capturedAt)
    }

    static func sourceURL(fromHTML html: String) -> URL? {
        guard let r = html.range(of: "name=\"offlinevault-source\" content=\"") else { return nil }
        let rest = html[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return URL(string: String(rest[..<end]))
    }

    /// Scans `pages/` for `.html` files that are not indexed yet (e.g. delivered by a page-pack).
    public func rescanFolder() throws -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: layout.pages, includingPropertiesForKeys: nil) else { return 0 }
        let known = Set(try pages().map(\.fileName))
        var added = 0
        for f in files where f.pathExtension == "html" && !known.contains(f.lastPathComponent) {
            var side: PageSidecar?
            let sidecarURL = f.deletingPathExtension().appendingPathExtension("json")
            if let d = try? Data(contentsOf: sidecarURL) { let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601; side = try? dec.decode(PageSidecar.self, from: d) }
            try indexExistingFile(f, url: side.flatMap { URL(string: $0.url) }, title: side?.title, capturedAt: side?.capturedAt ?? Date())
            if side == nil, let s = try page(id: Self.pageId(for: side.flatMap { URL(string: $0.url) } ?? Self.sourceURL(fromHTML: (try? String(contentsOf: f, encoding: .utf8)) ?? "") ?? URL(string: "file://" + f.path)!)) {
                let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
                try? enc.encode(PageSidecar(id: s.id, url: s.url.absoluteString, title: s.title, capturedAt: s.capturedAt, assetCount: 0)).write(to: layout.pages.appendingPathComponent(s.id + ".json"))
            }
            added += 1
        }
        return added
    }

    func index(id: String, url: URL, title: String, text: String, fileName: String, capturedAt: Date) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: layout.pages.appendingPathComponent(fileName).path)[.size] as? NSNumber)?.int64Value ?? 0
        let chunks = HTMLText.chunk(text)
        try database.db.transaction {
            try database.db.execute("""
            INSERT INTO pages(id, url, title, file_name, captured_at, size_bytes, text_length, excerpt, last_error) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(id) DO UPDATE SET url=excluded.url, title=excluded.title, file_name=excluded.file_name, captured_at=excluded.captured_at,
                size_bytes=excluded.size_bytes, text_length=excluded.text_length, excerpt=excluded.excerpt, last_error=NULL
            """, [.text(id), .text(url.absoluteString), .text(title), .text(fileName), .from(capturedAt), .integer(size), .integer(Int64(text.count)), .text(String(text.prefix(240)).replacingOccurrences(of: "\n", with: " "))])
            try database.db.execute("DELETE FROM page_chunks_fts WHERE page_id = ?", [.text(id)])
            try database.db.execute("DELETE FROM page_chunks WHERE page_id = ?", [.text(id)])
            for (i, c) in chunks.enumerated() {
                try database.db.execute("INSERT INTO page_chunks(page_id, ord, text) VALUES (?, ?, ?)", [.text(id), .integer(Int64(i)), .text(c)])
                let rowid = database.db.lastInsertRowID()
                try database.db.execute("INSERT INTO page_chunks_fts(chunk_id, page_id, title, text) VALUES (?, ?, ?, ?)", [.integer(rowid), .text(id), .text(title), .text(c)])
            }
        }
    }

    public func delete(_ page: SavedPage) throws {
        try database.db.transaction {
            try database.db.execute("DELETE FROM page_chunks_fts WHERE page_id = ?", [.text(page.id)])
            try database.db.execute("DELETE FROM page_chunks WHERE page_id = ?", [.text(page.id)])
            try database.db.execute("DELETE FROM pages WHERE id = ?", [.text(page.id)])
        }
        for f in [fileURL(for: page), layout.pages.appendingPathComponent(page.id + ".json")] where FileManager.default.fileExists(atPath: f.path) {
            if (try? FileManager.default.trashItem(at: f, resultingItemURL: nil)) == nil { try? FileManager.default.removeItem(at: f) }
        }
    }

    public struct SearchHit: Equatable, Sendable, Identifiable {
        public var page: SavedPage
        public var snippet: String
        public var chunkText: String
        public var score: Double
        public var id: String { page.id }
    }

    /// FTS search over page chunks; returns the best chunk per page, ranked by BM25 (title weighted 3×).
    /// `anyTerm: true` ranks chunks matching any of the terms (natural-language questions); `false` requires all (keyword search).
    public func search(_ query: String, limit: Int = 20, anyTerm: Bool = false) throws -> [SearchHit] {
        guard let match = FTSQuery.build(query, prefixLast: !anyTerm, orTerms: anyTerm) else { return [] }
        let rows = try database.db.query("""
        SELECT f.page_id AS page_id, f.text AS chunk_text, snippet(page_chunks_fts, 3, '«', '»', '…', 24) AS snip, bm25(page_chunks_fts, 0, 0, 3.0, 1.0) AS score
        FROM page_chunks_fts f WHERE page_chunks_fts MATCH ? ORDER BY score LIMIT ?
        """, [.text(match), .integer(Int64(limit * 3))])
        var seen = Set<String>()
        var hits: [SearchHit] = []
        for r in rows {
            guard let pid = r.string("page_id"), !seen.contains(pid), let p = try page(id: pid) else { continue }
            seen.insert(pid)
            hits.append(SearchHit(page: p, snippet: r.string("snip") ?? "", chunkText: r.string("chunk_text") ?? "", score: -(r.double("score") ?? 0)))
            if hits.count >= limit { break }
        }
        return hits
    }
}
