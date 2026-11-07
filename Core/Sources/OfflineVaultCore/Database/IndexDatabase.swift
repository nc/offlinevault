import Foundation

/// The library index: catalogue of installed artefacts, ZIM books, videos, pages, FTS indexes, chat history.
public final class IndexDatabase: @unchecked Sendable {
    public let db: SQLiteDatabase
    public static let schemaVersion = 1

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try migrate()
    }

    public convenience init(url: URL) throws { try self.init(path: url.path) }

    public static func inMemory() throws -> IndexDatabase { try IndexDatabase(path: ":memory:") }

    private func migrate() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS installed_artefacts(
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            path TEXT NOT NULL,
            file_name TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            installed_at REAL NOT NULL,
            manifest_version TEXT
        );
        CREATE TABLE IF NOT EXISTS zim_books(
            name TEXT PRIMARY KEY,
            artefact_id TEXT,
            file_name TEXT NOT NULL,
            title TEXT,
            description TEXT,
            language TEXT,
            article_count INTEGER,
            media_count INTEGER,
            size_bytes INTEGER,
            licence TEXT
        );
        CREATE TABLE IF NOT EXISTS video_sources(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL,
            title TEXT,
            uploader TEXT,
            added_at REAL NOT NULL,
            last_indexed_at REAL,
            item_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT
        );
        CREATE TABLE IF NOT EXISTS videos(
            id TEXT PRIMARY KEY,
            source_id INTEGER REFERENCES video_sources(id) ON DELETE SET NULL,
            title TEXT NOT NULL,
            channel TEXT,
            duration_seconds REAL,
            upload_date TEXT,
            description TEXT,
            webpage_url TEXT,
            thumbnail_url TEXT,
            indexed_at REAL,
            downloaded_at REAL,
            file_name TEXT,
            file_size INTEGER,
            thumbnail_file TEXT,
            subtitle_file TEXT,
            quality TEXT,
            status TEXT NOT NULL DEFAULT 'indexed'
        );
        CREATE INDEX IF NOT EXISTS idx_videos_source ON videos(source_id);
        CREATE INDEX IF NOT EXISTS idx_videos_status ON videos(status);
        CREATE VIRTUAL TABLE IF NOT EXISTS videos_fts USING fts5(video_id UNINDEXED, title, channel, description, tokenize='porter unicode61');
        CREATE TABLE IF NOT EXISTS transcript_segments(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            video_id TEXT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
            start_seconds REAL NOT NULL,
            end_seconds REAL,
            text TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_segments_video ON transcript_segments(video_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(segment_id UNINDEXED, video_id UNINDEXED, text, tokenize='porter unicode61');
        CREATE TABLE IF NOT EXISTS pages(
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            title TEXT,
            file_name TEXT NOT NULL,
            captured_at REAL NOT NULL,
            size_bytes INTEGER,
            text_length INTEGER,
            excerpt TEXT,
            last_error TEXT
        );
        CREATE TABLE IF NOT EXISTS page_chunks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
            ord INTEGER NOT NULL,
            text TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_chunks_page ON page_chunks(page_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS page_chunks_fts USING fts5(chunk_id UNINDEXED, page_id UNINDEXED, title, text, tokenize='porter unicode61');
        CREATE TABLE IF NOT EXISTS documents(
            id TEXT PRIMARY KEY,
            file_name TEXT NOT NULL,
            title TEXT NOT NULL,
            publisher TEXT,
            source_url TEXT,
            licence TEXT,
            page_count INTEGER,
            size_bytes INTEGER,
            added_at REAL NOT NULL,
            summary TEXT
        );
        CREATE TABLE IF NOT EXISTS doc_chunks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            page INTEGER NOT NULL,
            ord INTEGER NOT NULL,
            text TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_doc_chunks_doc ON doc_chunks(document_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS doc_chunks_fts USING fts5(chunk_id UNINDEXED, document_id UNINDEXED, title, text, tokenize='porter unicode61');
        CREATE TABLE IF NOT EXISTS conversations(
            id TEXT PRIMARY KEY,
            title TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            model TEXT
        );
        CREATE TABLE IF NOT EXISTS messages(
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at REAL NOT NULL,
            sources_json TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, created_at);
        CREATE TABLE IF NOT EXISTS playback_positions(
            video_id TEXT PRIMARY KEY,
            position_seconds REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT);
        """)
        // Additive migrations (ignore "duplicate column" on databases that already have them).
        _ = try? db.execute("ALTER TABLE messages ADD COLUMN used_library INTEGER NOT NULL DEFAULT 1")
        _ = try? db.execute("ALTER TABLE messages ADD COLUMN leading_label INTEGER")
        _ = try? db.execute("ALTER TABLE zim_books ADD COLUMN role TEXT")
        _ = try? db.execute("ALTER TABLE zim_books ADD COLUMN tier TEXT")
        _ = try? db.execute("ALTER TABLE zim_books ADD COLUMN updated_at TEXT")
        _ = try? db.execute("ALTER TABLE zim_books ADD COLUMN external INTEGER NOT NULL DEFAULT 0")
        _ = try? db.execute("ALTER TABLE documents ADD COLUMN kind TEXT NOT NULL DEFAULT 'pdf'")
        _ = try? db.execute("ALTER TABLE documents ADD COLUMN subject TEXT")
        _ = try? db.execute("ALTER TABLE documents ADD COLUMN sha256 TEXT")
        _ = try? db.execute("ALTER TABLE pages ADD COLUMN subject TEXT")
        _ = try? db.execute("ALTER TABLE videos ADD COLUMN subject TEXT")
        _ = try? db.execute("CREATE INDEX IF NOT EXISTS idx_documents_sha ON documents(sha256)")
        let v = try db.scalar("SELECT version FROM schema_version LIMIT 1")
        if case .integer = v {
            try db.execute("UPDATE schema_version SET version = ?", [.integer(Int64(Self.schemaVersion))])
        } else {
            try db.execute("INSERT INTO schema_version(version) VALUES (?)", [.integer(Int64(Self.schemaVersion))])
        }
    }

    // MARK: Key/value

    public func setValue(_ value: String?, forKey key: String) throws {
        if let value {
            try db.execute("INSERT INTO kv(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)])
        } else {
            try db.execute("DELETE FROM kv WHERE key = ?", [.text(key)])
        }
    }

    public func value(forKey key: String) throws -> String? {
        try db.query("SELECT value FROM kv WHERE key = ?", [.text(key)]).first?.string("value")
    }

    /// Set-valued preference (e.g. ticked scenario items), stored as JSON in the kv table.
    public func stringSet(forKey key: String) -> Set<String> {
        guard let s = (try? value(forKey: key)) ?? nil, let d = s.data(using: .utf8), let arr = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(arr)
    }
    public func setStringSet(_ set: Set<String>, forKey key: String) {
        if let d = try? JSONEncoder().encode(Array(set).sorted()), let s = String(data: d, encoding: .utf8) { try? setValue(s, forKey: key) }
    }

    // MARK: Installed artefacts

    public func installedArtefacts() throws -> [InstalledArtefact] {
        try db.query("SELECT * FROM installed_artefacts ORDER BY kind, id").map(InstalledArtefact.init(row:))
    }

    public func installedArtefact(id: String) throws -> InstalledArtefact? {
        try db.query("SELECT * FROM installed_artefacts WHERE id = ?", [.text(id)]).first.map(InstalledArtefact.init(row:))
    }

    public func recordInstalled(_ a: InstalledArtefact) throws {
        try db.execute("""
        INSERT INTO installed_artefacts(id, kind, path, file_name, size_bytes, sha256, installed_at, manifest_version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, path=excluded.path, file_name=excluded.file_name,
            size_bytes=excluded.size_bytes, sha256=excluded.sha256, installed_at=excluded.installed_at, manifest_version=excluded.manifest_version
        """, [.text(a.id), .text(a.kind.rawValue), .text(a.path), .text(a.fileName), .integer(a.sizeBytes), .text(a.sha256), .from(a.installedAt), .from(a.manifestVersion)])
    }

    public func removeInstalled(id: String) throws {
        try db.execute("DELETE FROM installed_artefacts WHERE id = ?", [.text(id)])
    }

    // MARK: ZIM books

    public func zimBooks() throws -> [ZimBook] {
        try db.query("SELECT * FROM zim_books ORDER BY title").map(ZimBook.init(row:))
    }

    public func upsertZimBook(_ b: ZimBook) throws {
        try db.execute("""
        INSERT INTO zim_books(name, artefact_id, file_name, title, description, language, article_count, media_count, size_bytes, licence, role, tier, updated_at, external)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(name) DO UPDATE SET artefact_id=COALESCE(excluded.artefact_id, zim_books.artefact_id), file_name=excluded.file_name,
            title=COALESCE(excluded.title, zim_books.title), description=COALESCE(excluded.description, zim_books.description),
            language=COALESCE(excluded.language, zim_books.language), article_count=COALESCE(excluded.article_count, zim_books.article_count),
            media_count=COALESCE(excluded.media_count, zim_books.media_count), size_bytes=COALESCE(excluded.size_bytes, zim_books.size_bytes),
            licence=COALESCE(excluded.licence, zim_books.licence), role=COALESCE(excluded.role, zim_books.role), tier=COALESCE(excluded.tier, zim_books.tier),
            updated_at=COALESCE(excluded.updated_at, zim_books.updated_at), external=MAX(excluded.external, zim_books.external)
        """, [.text(b.name), .from(b.artefactId), .text(b.fileName), .from(b.title), .from(b.description), .from(b.language), .from(b.articleCount), .from(b.mediaCount), .from(b.sizeBytes), .from(b.licence), .from(b.role?.rawValue), .from(b.tier?.rawValue), .from(b.updatedAt), .integer(b.isExternal ? 1 : 0)])
    }

    public func removeZimBook(fileName: String) throws {
        try db.execute("DELETE FROM zim_books WHERE file_name = ?", [.text(fileName)])
    }
}

public struct InstalledArtefact: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: ArtefactKind
    /// Manifest path the artefact was fetched from.
    public var path: String
    /// File (or folder) name inside the library category directory.
    public var fileName: String
    public var sizeBytes: Int64
    public var sha256: String
    public var installedAt: Date
    public var manifestVersion: String?

    public init(id: String, kind: ArtefactKind, path: String, fileName: String, sizeBytes: Int64, sha256: String, installedAt: Date = Date(), manifestVersion: String? = nil) {
        self.id = id; self.kind = kind; self.path = path; self.fileName = fileName
        self.sizeBytes = sizeBytes; self.sha256 = sha256; self.installedAt = installedAt; self.manifestVersion = manifestVersion
    }

    init(row: SQLiteDatabase.Row) {
        id = row.string("id") ?? ""
        kind = ArtefactKind(rawValue: row.string("kind") ?? "") ?? .catalogue
        path = row.string("path") ?? ""
        fileName = row.string("file_name") ?? ""
        sizeBytes = row.int("size_bytes") ?? 0
        sha256 = row.string("sha256") ?? ""
        installedAt = row.date("installed_at") ?? Date()
        manifestVersion = row.string("manifest_version")
    }
}

public struct ZimBook: Equatable, Hashable, Sendable, Identifiable {
    /// kiwix-serve book name (file name without `.zim` unless overridden by metadata).
    public var name: String
    public var id: String { name }
    public var artefactId: String?
    public var fileName: String
    public var title: String?
    public var description: String?
    public var language: String?
    public var articleCount: Int64?
    public var mediaCount: Int64?
    public var sizeBytes: Int64?
    public var licence: String?
    public var role: BookRole?
    public var tier: ContentTier?
    /// The OfflineVault Field Guide, identified by its catalogue artefact id (`zim-fieldguide-2026-10b`).
    public var isFieldGuide: Bool { artefactId?.hasPrefix("zim-fieldguide") == true }
    /// Content date reported by the engine (ZIM "Date" metadata, ISO yyyy-MM-dd). Drives the freshness badge.
    public var updatedAt: String?
    /// Installed from Kiwix's servers rather than the catalogue (`Artefact.external`); shown with the From Kiwix tag.
    public var isExternal: Bool

    public init(name: String, artefactId: String? = nil, fileName: String, title: String? = nil, description: String? = nil, language: String? = nil, articleCount: Int64? = nil, mediaCount: Int64? = nil, sizeBytes: Int64? = nil, licence: String? = nil, role: BookRole? = nil, tier: ContentTier? = nil, updatedAt: String? = nil, isExternal: Bool = false) {
        self.name = name; self.artefactId = artefactId; self.fileName = fileName; self.title = title; self.description = description
        self.language = language; self.articleCount = articleCount; self.mediaCount = mediaCount; self.sizeBytes = sizeBytes; self.licence = licence
        self.role = role; self.tier = tier; self.updatedAt = updatedAt; self.isExternal = isExternal
    }

    /// Snapshots dated before ChatGPT's release (Nov 2022) are prized by preppers as "pre-LLM" text.
    public var isPreLLMSnapshot: Bool { (updatedAt ?? "") < "2022-11-30" && !(updatedAt ?? "").isEmpty }
    public var freshnessLabel: String? {
        guard let u = updatedAt, u.count >= 7 else { return nil }
        return "Snapshot \(u.prefix(7))" + (isPreLLMSnapshot ? " · pre-LLM" : "")
    }

    init(row: SQLiteDatabase.Row) {
        name = row.string("name") ?? ""
        artefactId = row.string("artefact_id")
        fileName = row.string("file_name") ?? ""
        title = row.string("title")
        description = row.string("description")
        language = row.string("language")
        articleCount = row.int("article_count")
        mediaCount = row.int("media_count")
        isExternal = row.bool("external")
        sizeBytes = row.int("size_bytes")
        licence = row.string("licence")
        role = row.string("role").flatMap(BookRole.init(rawValue:))
        tier = row.string("tier").flatMap(ContentTier.init(rawValue:))
        updatedAt = row.string("updated_at")
    }

    public var displayTitle: String { title ?? fileName }
}
