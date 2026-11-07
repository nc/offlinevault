import Foundation
import PDFKit

/// A PDF in `documents/` (field manuals, FEMA guides, USDA publications …).
public struct LibraryDocument: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var fileName: String
    public var title: String
    public var publisher: String?
    public var sourceURL: String?
    public var licence: String?
    public var pageCount: Int
    public var sizeBytes: Int64
    public var addedAt: Date
    public var summary: String?
    public var kind: Kind
    public var subject: Subject?
    public var sha256: String?

    public enum Kind: String, Sendable { case pdf, epub, text }

    init(row: SQLiteDatabase.Row) {
        id = row.string("id") ?? ""; fileName = row.string("file_name") ?? ""; title = row.string("title") ?? ""
        publisher = row.string("publisher"); sourceURL = row.string("source_url"); licence = row.string("licence")
        pageCount = Int(row.int("page_count") ?? 0); sizeBytes = row.int("size_bytes") ?? 0; addedAt = row.date("added_at") ?? Date(); summary = row.string("summary")
        kind = Kind(rawValue: row.string("kind") ?? "pdf") ?? .pdf
        subject = row.string("subject").flatMap(Subject.init(rawValue:)); sha256 = row.string("sha256")
    }

    /// Label for the "page" unit shown in citations: PDF pages, EPUB chapters.
    public var unitLabel: String { kind == .epub ? "chapter" : "page" }
}

/// Sidecar metadata next to each PDF (`<basename>.json`), written by the content pipeline or on import.
public struct DocumentSidecar: Codable, Equatable, Sendable {
    public var title: String
    public var publisher: String?
    public var sourceURL: String?
    public var licence: String?
    public var summary: String?
    public var role: String?
    public var subject: String?
    public init(title: String, publisher: String? = nil, sourceURL: String? = nil, licence: String? = nil, summary: String? = nil, role: String? = nil, subject: String? = nil) {
        self.title = title; self.publisher = publisher; self.sourceURL = sourceURL; self.licence = licence; self.summary = summary; self.role = role; self.subject = subject
    }
}

/// Imports, indexes (page-aware FTS5) and searches PDF documents using PDFKit — no third-party dependency.
public final class DocumentService: @unchecked Sendable {
    public let layout: LibraryLayout
    public let database: IndexDatabase
    var db: SQLiteDatabase { database.db }

    public init(layout: LibraryLayout, database: IndexDatabase) { self.layout = layout; self.database = database }

    public func documents() throws -> [LibraryDocument] {
        try db.query("SELECT * FROM documents ORDER BY title").map(LibraryDocument.init(row:))
    }
    public func document(id: String) throws -> LibraryDocument? {
        try db.query("SELECT * FROM documents WHERE id = ?", [.text(id)]).first.map(LibraryDocument.init(row:))
    }
    public func fileURL(for d: LibraryDocument) -> URL { layout.documents.appendingPathComponent(d.fileName) }

    public static func documentId(forFileName name: String) -> String {
        String(Checksum.sha256Hex(of: Data(name.utf8)).prefix(16))
    }

    public static let supportedExtensions: Set<String> = ["pdf", "epub", "txt", "md", "markdown"]

    /// Copies a user-chosen PDF / EPUB / text file into the library and indexes it. Returns nil when an identical
    /// file (same SHA-256) is already in the library (hoard imports are full of duplicates).
    @discardableResult
    public func importPDF(from source: URL, title: String? = nil, subjectHint: Subject? = nil) throws -> LibraryDocument {
        guard let d = try importDocument(from: source, title: title, subjectHint: subjectHint, skipDuplicates: false) else { throw UserFacingError("Import failed", message: "\(source.lastPathComponent) could not be imported.") }
        return d
    }

    @discardableResult
    public func importDocument(from source: URL, title: String? = nil, subjectHint: Subject? = nil, skipDuplicates: Bool = true) throws -> LibraryDocument? {
        try layout.ensureDirectories()
        let ext = source.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw UserFacingError("Unsupported file", message: "\(source.lastPathComponent) is not a PDF, EPUB or text file.", recovery: "Convert it to PDF or EPUB and import again.")
        }
        let hash = try Checksum.sha256Hex(ofFileAt: source)
        if skipDuplicates, let existing = try db.query("SELECT * FROM documents WHERE sha256 = ?", [.text(hash)]).first.map(LibraryDocument.init(row:)) {
            return FileManager.default.fileExists(atPath: fileURL(for: existing).path) ? nil : try reindex(existing)
        }
        var name = Self.safeFileName(source.lastPathComponent)
        var dest = layout.documents.appendingPathComponent(name)
        if dest.standardizedFileURL != source.standardizedFileURL {
            var n = 1
            while FileManager.default.fileExists(atPath: dest.path), (try? Checksum.sha256Hex(ofFileAt: dest)) != hash {
                n += 1; name = source.deletingPathExtension().lastPathComponent + "-\(n)." + ext; dest = layout.documents.appendingPathComponent(Self.safeFileName(name))
            }
            if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: source, to: dest) }
        }
        let guessedTitle = title ?? (ext == "pdf" ? Self.titleFromPDF(dest) : nil) ?? (ext == "epub" ? EPUB.title(of: dest) : nil) ?? Self.titleFromFileName(source)
        var sidecar = DocumentSidecar(title: guessedTitle)
        sidecar.subject = subjectHint?.rawValue
        try writeSidecar(sidecar, for: dest)
        return try index(file: dest, sidecar: sidecar, sha256: hash)
    }

    static func safeFileName(_ s: String) -> String {
        s.replacingOccurrences(of: "[/:\\\\]", with: "_", options: .regularExpression)
    }

    /// "FM_21-76_survival-manual.PDF" → "FM 21-76 survival manual"
    static func titleFromFileName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "[_]+", with: " ", options: .regularExpression).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    func reindex(_ d: LibraryDocument) throws -> LibraryDocument {
        let f = fileURL(for: d)
        var side: DocumentSidecar? = nil
        if let data = try? Data(contentsOf: f.deletingPathExtension().appendingPathExtension("json")) { side = try? JSONDecoder().decode(DocumentSidecar.self, from: data) }
        return try index(file: f, sidecar: side ?? DocumentSidecar(title: d.title), sha256: d.sha256)
    }

    func writeSidecar(_ s: DocumentSidecar, for pdf: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: pdf.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
    }

    static func titleFromPDF(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        if let t = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty { return t }
        return nil
    }

    /// Indexes every PDF in `documents/` that is missing or has changed. Returns the number (re)indexed.
    @discardableResult
    public func rescanFolder() throws -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: layout.documents, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var count = 0
        let known = Dictionary(uniqueKeysWithValues: try documents().map { ($0.fileName, $0) })
        for f in files where Self.supportedExtensions.contains(f.pathExtension.lowercased()) {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if let k = known[f.lastPathComponent], k.sizeBytes == size { continue }
            var sidecar: DocumentSidecar?
            if let d = try? Data(contentsOf: f.deletingPathExtension().appendingPathExtension("json")) { sidecar = try? JSONDecoder().decode(DocumentSidecar.self, from: d) }
            let ext = f.pathExtension.lowercased()
            let s = sidecar ?? DocumentSidecar(title: (ext == "pdf" ? Self.titleFromPDF(f) : ext == "epub" ? EPUB.title(of: f) : nil) ?? Self.titleFromFileName(f))
            if sidecar == nil { try? writeSidecar(s, for: f) }
            _ = try index(file: f, sidecar: s)
            count += 1
        }
        // Drop rows whose file disappeared.
        let present = Set(files.map(\.lastPathComponent))
        for (name, d) in known where !present.contains(name) { try delete(d, removeFile: false) }
        return count
    }

    /// Extracts text per unit (PDF page / EPUB chapter / whole text file), chunks it, classifies the subject and
    /// (re)writes the FTS rows.
    func index(file: URL, sidecar: DocumentSidecar, sha256: String? = nil) throws -> LibraryDocument {
        let ext = file.pathExtension.lowercased()
        let id = Self.documentId(forFileName: file.lastPathComponent)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var units: [(page: Int, text: String)] = []
        let kind: LibraryDocument.Kind
        switch ext {
        case "pdf":
            kind = .pdf
            guard let pdf = PDFDocument(url: file) else {
                throw UserFacingError("Not a readable PDF", message: "\(file.lastPathComponent) could not be opened by PDFKit.", recovery: "The file may be corrupt or encrypted. Re-download it and import again.")
            }
            for i in 0..<pdf.pageCount {
                guard let page = pdf.page(at: i), let raw = page.string else { continue }
                units.append((i + 1, HTMLText.normalise(Self.dehyphenate(raw))))
            }
        case "epub":
            kind = .epub
            let book = try EPUB.open(file)
            for (i, ch) in book.chapters.enumerated() { units.append((i + 1, ch.text)) }
        default:
            kind = .text
            let raw = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) ?? ""
            units.append((1, HTMLText.normalise(raw)))
        }
        var chunks: [(page: Int, text: String)] = []
        for u in units { for c in HTMLText.chunk(u.text, targetChars: 900, maxChars: 1400) { chunks.append((u.page, c)) } }
        let sample = sidecar.title + "\n" + chunks.prefix(40).map(\.text).joined(separator: "\n")
        let subject = sidecar.subject.flatMap(Subject.init(rawValue:)) ?? SubjectClassifier.classify(sample)
        let hash = try sha256 ?? Checksum.sha256Hex(ofFileAt: file)
        try db.transaction {
            try db.execute("""
            INSERT INTO documents(id, file_name, title, publisher, source_url, licence, page_count, size_bytes, added_at, summary, kind, subject, sha256) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET file_name=excluded.file_name, title=excluded.title, publisher=excluded.publisher, source_url=excluded.source_url,
                licence=excluded.licence, page_count=excluded.page_count, size_bytes=excluded.size_bytes, summary=excluded.summary, kind=excluded.kind, subject=excluded.subject, sha256=excluded.sha256
            """, [.text(id), .text(file.lastPathComponent), .text(sidecar.title), .from(sidecar.publisher), .from(sidecar.sourceURL), .from(sidecar.licence), .integer(Int64(units.count)), .integer(size), .from(Date()), .from(sidecar.summary), .text(kind.rawValue), .text(subject.rawValue), .text(hash)])
            try db.execute("DELETE FROM doc_chunks_fts WHERE document_id = ?", [.text(id)])
            try db.execute("DELETE FROM doc_chunks WHERE document_id = ?", [.text(id)])
            for (ord, c) in chunks.enumerated() {
                try db.execute("INSERT INTO doc_chunks(document_id, page, ord, text) VALUES (?, ?, ?, ?)", [.text(id), .integer(Int64(c.page)), .integer(Int64(ord)), .text(c.text)])
                let rowid = db.lastInsertRowID()
                try db.execute("INSERT INTO doc_chunks_fts(chunk_id, document_id, title, text) VALUES (?, ?, ?, ?)", [.integer(rowid), .text(id), .text(sidecar.title), .text(c.text)])
            }
        }
        return try document(id: id)!
    }

    /// Plain text of one unit (PDF page / EPUB chapter) for the viewer and for citations.
    public func text(of d: LibraryDocument, unit: Int) -> String {
        (try? db.query("SELECT text FROM doc_chunks WHERE document_id = ? AND page = ? ORDER BY ord", [.text(d.id), .integer(Int64(unit))]).compactMap { $0.string("text") }.joined(separator: "\n\n")) ?? ""
    }

    public func setSubject(_ subject: Subject, for d: LibraryDocument) throws {
        try db.execute("UPDATE documents SET subject = ? WHERE id = ?", [.text(subject.rawValue), .text(d.id)])
        if var side = try? JSONDecoder().decode(DocumentSidecar.self, from: Data(contentsOf: fileURL(for: d).deletingPathExtension().appendingPathExtension("json"))) {
            side.subject = subject.rawValue; try? writeSidecar(side, for: fileURL(for: d))
        }
    }

    /// Counts per subject for the "what's where" overview.
    public func subjectCounts() throws -> [Subject: Int] {
        var out: [Subject: Int] = [:]
        for r in try db.query("SELECT subject, COUNT(*) AS n FROM documents GROUP BY subject") {
            if let s = r.string("subject").flatMap(Subject.init(rawValue:)) { out[s] = Int(r.int("n") ?? 0) }
        }
        return out
    }

    /// PDF text extraction leaves "hyphen-\nated" words and single newlines mid-sentence; repair those.
    static func dehyphenate(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "-\n", with: "")
        t = t.replacingOccurrences(of: "([^.!?:;\\n])\\n(?=[a-z0-9])", with: "$1 ", options: .regularExpression)
        return t
    }

    public func delete(_ d: LibraryDocument, removeFile: Bool = true) throws {
        try db.transaction {
            try db.execute("DELETE FROM doc_chunks_fts WHERE document_id = ?", [.text(d.id)])
            try db.execute("DELETE FROM doc_chunks WHERE document_id = ?", [.text(d.id)])
            try db.execute("DELETE FROM documents WHERE id = ?", [.text(d.id)])
        }
        if removeFile {
            // Move to the Trash so a mistaken delete of a hand-imported manual can be undone in Finder.
            for f in [fileURL(for: d), fileURL(for: d).deletingPathExtension().appendingPathExtension("json"), fileURL(for: d).appendingPathExtension("d")] where FileManager.default.fileExists(atPath: f.path) {
                if (try? FileManager.default.trashItem(at: f, resultingItemURL: nil)) == nil { try? FileManager.default.removeItem(at: f) }
            }
        }
    }

    public struct SearchHit: Equatable, Sendable, Identifiable {
        public var document: LibraryDocument
        public var page: Int
        public var snippet: String
        public var chunkText: String
        public var score: Double
        public var id: String { "\(document.id)#\(page)#\(chunkText.hashValue)" }
    }

    /// BM25 over chunks (title ×3); best chunk per document+page, up to `limit`.
    public func search(_ query: String, limit: Int = 20, anyTerm: Bool = false) throws -> [SearchHit] {
        guard let match = FTSQuery.build(query, prefixLast: !anyTerm, orTerms: anyTerm) else { return [] }
        let rows = try db.query("""
        SELECT c.document_id AS document_id, c.page AS page, c.text AS chunk_text, snippet(doc_chunks_fts, 3, '«', '»', '…', 24) AS snip, bm25(doc_chunks_fts, 0, 0, 3.0, 1.0) AS score
        FROM doc_chunks_fts f JOIN doc_chunks c ON c.id = f.chunk_id WHERE doc_chunks_fts MATCH ? ORDER BY score LIMIT ?
        """, [.text(match), .integer(Int64(limit * 3))])
        var docs: [String: LibraryDocument] = [:]
        var seen = Set<String>()
        var out: [SearchHit] = []
        for r in rows {
            guard let did = r.string("document_id") else { continue }
            let page = Int(r.int("page") ?? 0)
            guard seen.insert("\(did)#\(page)").inserted else { continue }
            if docs[did] == nil { docs[did] = try document(id: did) }
            guard let d = docs[did] else { continue }
            out.append(SearchHit(document: d, page: page, snippet: r.string("snip") ?? "", chunkText: r.string("chunk_text") ?? "", score: -(r.double("score") ?? 0)))
            if out.count >= limit { break }
        }
        return out
    }
}
