import Foundation

public struct VideoSource: Equatable, Hashable, Sendable, Identifiable {
    public var id: Int64
    public var url: String
    public var kind: YtDlpCommand.SourceKind
    public var title: String?
    public var uploader: String?
    public var addedAt: Date
    public var lastIndexedAt: Date?
    public var itemCount: Int
    public var lastError: String?
    init(row: SQLiteDatabase.Row) {
        id = row.int("id") ?? 0; url = row.string("url") ?? ""; kind = YtDlpCommand.SourceKind(rawValue: row.string("kind") ?? "") ?? .video
        title = row.string("title"); uploader = row.string("uploader"); addedAt = row.date("added_at") ?? Date(); lastIndexedAt = row.date("last_indexed_at")
        itemCount = Int(row.int("item_count") ?? 0); lastError = row.string("last_error")
    }
    public var displayTitle: String { title ?? url }
}

public struct Video: Equatable, Sendable, Identifiable, Hashable {
    public enum Status: String, Sendable { case indexed, queued, downloading, downloaded, failed }
    public var id: String
    public var sourceId: Int64?
    public var title: String
    public var channel: String?
    public var durationSeconds: Double?
    public var uploadDate: String?
    public var description: String?
    public var webpageURL: String?
    public var thumbnailURL: String?
    public var indexedAt: Date?
    public var downloadedAt: Date?
    public var fileName: String?
    public var fileSize: Int64?
    public var thumbnailFile: String?
    public var subtitleFile: String?
    public var quality: VideoQuality?
    public var status: Status

    public init(id: String, sourceId: Int64? = nil, title: String, channel: String? = nil, durationSeconds: Double? = nil, uploadDate: String? = nil, description: String? = nil, webpageURL: String? = nil, thumbnailURL: String? = nil, status: Status = .indexed) {
        self.id = id; self.sourceId = sourceId; self.title = title; self.channel = channel; self.durationSeconds = durationSeconds; self.uploadDate = uploadDate
        self.description = description; self.webpageURL = webpageURL; self.thumbnailURL = thumbnailURL; self.status = status
    }

    init(row: SQLiteDatabase.Row) {
        id = row.string("id") ?? ""; sourceId = row.int("source_id"); title = row.string("title") ?? ""; channel = row.string("channel")
        durationSeconds = row.double("duration_seconds"); uploadDate = row.string("upload_date"); description = row.string("description")
        webpageURL = row.string("webpage_url"); thumbnailURL = row.string("thumbnail_url"); indexedAt = row.date("indexed_at"); downloadedAt = row.date("downloaded_at")
        fileName = row.string("file_name"); fileSize = row.int("file_size"); thumbnailFile = row.string("thumbnail_file"); subtitleFile = row.string("subtitle_file")
        quality = row.string("quality").flatMap(VideoQuality.init(rawValue:)); status = Status(rawValue: row.string("status") ?? "") ?? .indexed
    }

    public var watchURL: String { webpageURL ?? "https://www.youtube.com/watch?v=\(id)" }
    public var formattedUploadDate: String? {
        guard let d = uploadDate, d.count == 8 else { return uploadDate }
        return "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))"
    }
}

/// Sidecar JSON written next to each downloaded video (`<id>.json`).
public struct VideoSidecar: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var channel: String?
    public var durationSeconds: Double?
    public var uploadDate: String?
    public var description: String?
    public var webpageURL: String?
    public var quality: String?
    public var fileName: String
    public var thumbnailFile: String?
    public var subtitleFile: String?
    public var downloadedAt: Date
    public var sourceURL: String?

    public init(id: String, title: String, channel: String?, durationSeconds: Double?, uploadDate: String?, description: String?, webpageURL: String?, quality: String?, fileName: String, thumbnailFile: String?, subtitleFile: String?, downloadedAt: Date, sourceURL: String?) {
        self.id = id; self.title = title; self.channel = channel; self.durationSeconds = durationSeconds; self.uploadDate = uploadDate; self.description = description
        self.webpageURL = webpageURL; self.quality = quality; self.fileName = fileName; self.thumbnailFile = thumbnailFile; self.subtitleFile = subtitleFile; self.downloadedAt = downloadedAt; self.sourceURL = sourceURL
    }

    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// Catalogue + files for videos: sources, indexed entries, downloaded files, FTS over metadata and transcripts.
public final class VideoLibraryService: @unchecked Sendable {
    public let layout: LibraryLayout
    public let database: IndexDatabase
    var db: SQLiteDatabase { database.db }

    public init(layout: LibraryLayout, database: IndexDatabase) { self.layout = layout; self.database = database }

    // MARK: Sources

    public func sources() throws -> [VideoSource] { try db.query("SELECT * FROM video_sources ORDER BY added_at DESC").map(VideoSource.init(row:)) }

    @discardableResult
    public func addSource(url rawURL: String) throws -> VideoSource {
        let url = YtDlpCommand.normalise(sourceURL: rawURL)
        guard let u = URL(string: url), u.host != nil else { throw UserFacingError("Not a valid address", message: "“\(rawURL)” is not a URL yt-dlp can index.", recovery: "Paste a video, playlist or channel link.") }
        let kind = YtDlpCommand.SourceKind.detect(url)
        try db.execute("INSERT INTO video_sources(url, kind, added_at) VALUES (?, ?, ?) ON CONFLICT(url) DO NOTHING", [.text(url), .text(kind.rawValue), .from(Date())])
        return try db.query("SELECT * FROM video_sources WHERE url = ?", [.text(url)]).first.map(VideoSource.init(row:))!
    }

    public func removeSource(_ id: Int64, deleteIndexedEntries: Bool) throws {
        if deleteIndexedEntries { try db.execute("DELETE FROM videos WHERE source_id = ? AND status = 'indexed'", [.integer(id)]) }
        try db.execute("DELETE FROM video_sources WHERE id = ?", [.integer(id)])
    }

    public func recordIndexResult(sourceId: Int64, info: YtDlpInfo) throws -> Int {
        let videos = info.flattenedVideos()
        try db.transaction {
            try db.execute("UPDATE video_sources SET title = COALESCE(?, title), uploader = COALESCE(?, uploader), last_indexed_at = ?, item_count = ?, last_error = NULL WHERE id = ?",
                           [.from(info.title), .from(info.channelName), .from(Date()), .integer(Int64(videos.count)), .integer(sourceId)])
            for v in videos {
                guard let id = v.id else { continue }
                try db.execute("""
                INSERT INTO videos(id, source_id, title, channel, duration_seconds, upload_date, description, webpage_url, thumbnail_url, indexed_at, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'indexed')
                ON CONFLICT(id) DO UPDATE SET source_id = COALESCE(videos.source_id, excluded.source_id), title = excluded.title,
                    channel = COALESCE(excluded.channel, videos.channel), duration_seconds = COALESCE(excluded.duration_seconds, videos.duration_seconds),
                    upload_date = COALESCE(excluded.upload_date, videos.upload_date), description = COALESCE(excluded.description, videos.description),
                    webpage_url = COALESCE(excluded.webpage_url, videos.webpage_url), thumbnail_url = COALESCE(excluded.thumbnail_url, videos.thumbnail_url), indexed_at = excluded.indexed_at
                """, [.text(id), .integer(sourceId), .text(v.title ?? id), .from(v.channelName ?? info.channelName), .from(v.duration), .from(v.upload_date), .from(v.description), .from(v.videoURL), .from(v.bestThumbnailURL), .from(Date())])
                try upsertMetadataFTS(id: id, title: v.title ?? id, channel: v.channelName ?? info.channelName, description: v.description)
            }
        }
        return videos.count
    }

    public func recordIndexError(sourceId: Int64, message: String) throws {
        try db.execute("UPDATE video_sources SET last_error = ? WHERE id = ?", [.text(message), .integer(sourceId)])
    }

    // MARK: Videos

    public func videos(status: Video.Status? = nil, sourceId: Int64? = nil) throws -> [Video] {
        var sql = "SELECT * FROM videos WHERE 1=1"
        var params: [SQLiteDatabase.Value] = []
        if let status { sql += " AND status = ?"; params.append(.text(status.rawValue)) }
        if let sourceId { sql += " AND source_id = ?"; params.append(.integer(sourceId)) }
        sql += " ORDER BY COALESCE(downloaded_at, indexed_at) DESC, upload_date DESC"
        return try db.query(sql, params).map(Video.init(row:))
    }

    public func video(id: String) throws -> Video? { try db.query("SELECT * FROM videos WHERE id = ?", [.text(id)]).first.map(Video.init(row:)) }

    public func setStatus(_ status: Video.Status, for id: String) throws {
        try db.execute("UPDATE videos SET status = ? WHERE id = ?", [.text(status.rawValue), .text(id)])
    }

    public func fileURL(for v: Video) -> URL? { v.fileName.map { layout.videos.appendingPathComponent($0) } }
    public func thumbnailURL(for v: Video) -> URL? { v.thumbnailFile.map { layout.videos.appendingPathComponent($0) } }
    public func subtitleURL(for v: Video) -> URL? { v.subtitleFile.map { layout.videos.appendingPathComponent($0) } }

    func upsertMetadataFTS(id: String, title: String, channel: String?, description: String?) throws {
        try db.execute("DELETE FROM videos_fts WHERE video_id = ?", [.text(id)])
        try db.execute("INSERT INTO videos_fts(video_id, title, channel, description) VALUES (?, ?, ?, ?)", [.text(id), .text(title), .from(channel), .from(description)])
    }

    /// Called after yt-dlp finishes: finds the produced files, writes the sidecar, indexes subtitles, generates a thumbnail if needed.
    @discardableResult
    public func finalizeDownload(videoId: String, quality: VideoQuality, sourceURL: String?, ffmpeg: URL?) throws -> Video {
        let fm = FileManager.default
        let dir = layout.videos
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let mine = files.filter { $0.lastPathComponent.hasPrefix(videoId + ".") }
        guard let media = mine.first(where: { ["mp4", "mkv", "webm", "mov", "m4v"].contains($0.pathExtension.lowercased()) }) else {
            throw UserFacingError("Download incomplete", message: "yt-dlp finished but no video file for \(videoId) was found in the videos folder.", recovery: "Retry the download. If it fails again, run scripts/fetch_binaries.sh to update yt-dlp.")
        }
        var info: YtDlpInfo?
        if let infoFile = mine.first(where: { $0.lastPathComponent.hasSuffix(".info.json") }), let d = try? Data(contentsOf: infoFile) {
            info = try? YtDlpInfo.parse(d)
            try? fm.removeItem(at: infoFile) // replaced by our compact sidecar
        }
        let existing = try video(id: videoId)
        let subtitle = mine.filter { $0.pathExtension.lowercased() == "vtt" || $0.pathExtension.lowercased() == "srt" }
            .sorted { a, b in (a.lastPathComponent.contains(".en") ? 0 : 1) < (b.lastPathComponent.contains(".en") ? 0 : 1) }.first
        var thumb = mine.first { ["jpg", "jpeg", "png", "webp"].contains($0.pathExtension.lowercased()) }
        if thumb == nil, let ffmpeg {
            let out = dir.appendingPathComponent(videoId + ".jpg")
            if Thumbnailer.generate(from: media, to: out, ffmpeg: ffmpeg) { thumb = out }
        }
        let size = (try? media.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let title = info?.title ?? existing?.title ?? videoId
        let sidecar = VideoSidecar(id: videoId, title: title, channel: info?.channelName ?? existing?.channel, durationSeconds: info?.duration ?? existing?.durationSeconds,
                                   uploadDate: info?.upload_date ?? existing?.uploadDate, description: info?.description ?? existing?.description, webpageURL: info?.webpage_url ?? existing?.webpageURL,
                                   quality: quality.rawValue, fileName: media.lastPathComponent, thumbnailFile: thumb?.lastPathComponent, subtitleFile: subtitle?.lastPathComponent, downloadedAt: Date(), sourceURL: sourceURL)
        try VideoSidecar.encoder.encode(sidecar).write(to: dir.appendingPathComponent(videoId + ".json"), options: .atomic)
        try importSidecar(sidecar, fileSize: size, sourceId: existing?.sourceId)
        return try video(id: videoId)!
    }

    /// Registers a video described by a sidecar (download result or video-pack install) and indexes its transcript.
    public func importSidecar(_ s: VideoSidecar, fileSize: Int64? = nil, sourceId: Int64? = nil) throws {
        let size = fileSize ?? ((try? layout.videos.appendingPathComponent(s.fileName).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
        try db.transaction {
            try db.execute("""
            INSERT INTO videos(id, source_id, title, channel, duration_seconds, upload_date, description, webpage_url, downloaded_at, file_name, file_size, thumbnail_file, subtitle_file, quality, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'downloaded')
            ON CONFLICT(id) DO UPDATE SET source_id = COALESCE(videos.source_id, excluded.source_id), title = excluded.title, channel = COALESCE(excluded.channel, videos.channel),
                duration_seconds = COALESCE(excluded.duration_seconds, videos.duration_seconds), upload_date = COALESCE(excluded.upload_date, videos.upload_date),
                description = COALESCE(excluded.description, videos.description), webpage_url = COALESCE(excluded.webpage_url, videos.webpage_url),
                downloaded_at = excluded.downloaded_at, file_name = excluded.file_name, file_size = excluded.file_size, thumbnail_file = excluded.thumbnail_file,
                subtitle_file = excluded.subtitle_file, quality = excluded.quality, status = 'downloaded'
            """, [.text(s.id), .from(sourceId), .text(s.title), .from(s.channel), .from(s.durationSeconds), .from(s.uploadDate), .from(s.description), .from(s.webpageURL), .from(s.downloadedAt), .text(s.fileName), .integer(size), .from(s.thumbnailFile), .from(s.subtitleFile), .from(s.quality)])
            try upsertMetadataFTS(id: s.id, title: s.title, channel: s.channel, description: s.description)
            try db.execute("DELETE FROM transcript_fts WHERE video_id = ?", [.text(s.id)])
            try db.execute("DELETE FROM transcript_segments WHERE video_id = ?", [.text(s.id)])
            if let sub = s.subtitleFile, let content = try? String(contentsOf: layout.videos.appendingPathComponent(sub), encoding: .utf8) {
                for w in SubtitleParser.windows(SubtitleParser.parse(content)) {
                    try db.execute("INSERT INTO transcript_segments(video_id, start_seconds, end_seconds, text) VALUES (?, ?, ?, ?)", [.text(s.id), .real(w.start), .real(w.end), .text(w.text)])
                    let rowid = db.lastInsertRowID()
                    try db.execute("INSERT INTO transcript_fts(segment_id, video_id, text) VALUES (?, ?, ?)", [.integer(rowid), .text(s.id), .text(w.text)])
                }
            }
        }
    }

    /// Scans `videos/` for sidecars not yet in the index (e.g. after a video-pack install).
    @discardableResult
    public func rescanFolder() throws -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: layout.videos, includingPropertiesForKeys: nil) else { return 0 }
        var added = 0
        for f in files where f.pathExtension == "json" && !f.lastPathComponent.hasSuffix(".info.json") && !f.lastPathComponent.hasPrefix(".") {
            guard let d = try? Data(contentsOf: f), let s = try? VideoSidecar.decoder.decode(VideoSidecar.self, from: d) else { continue }
            guard fm.fileExists(atPath: layout.videos.appendingPathComponent(s.fileName).path) else { continue }
            if let v = try video(id: s.id), v.status == .downloaded, v.fileName == s.fileName { continue }
            try importSidecar(s)
            added += 1
        }
        return added
    }

    public func deleteDownloadedFiles(_ v: Video, keepCatalogueEntry: Bool) throws {
        let fm = FileManager.default
        for f in [v.fileName, v.thumbnailFile, v.subtitleFile, v.id + ".json"].compactMap({ $0 }) { try? fm.removeItem(at: layout.videos.appendingPathComponent(f)) }
        try db.transaction {
            try db.execute("DELETE FROM transcript_fts WHERE video_id = ?", [.text(v.id)])
            try db.execute("DELETE FROM transcript_segments WHERE video_id = ?", [.text(v.id)])
            if keepCatalogueEntry {
                try db.execute("UPDATE videos SET status = 'indexed', file_name = NULL, file_size = NULL, thumbnail_file = NULL, subtitle_file = NULL, downloaded_at = NULL WHERE id = ?", [.text(v.id)])
            } else {
                try db.execute("DELETE FROM videos_fts WHERE video_id = ?", [.text(v.id)])
                try db.execute("DELETE FROM videos WHERE id = ?", [.text(v.id)])
            }
        }
        // Allow re-download later by removing the archive line.
        if let content = try? String(contentsOf: layout.ytdlpArchiveURL, encoding: .utf8) {
            let kept = content.split(separator: "\n").filter { !$0.hasSuffix(" " + v.id) }.joined(separator: "\n")
            try? (kept + (kept.isEmpty ? "" : "\n")).write(to: layout.ytdlpArchiveURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Search

    public struct MetadataHit: Equatable, Sendable { public var video: Video; public var score: Double }
    public struct TranscriptHit: Equatable, Sendable, Identifiable {
        public var video: Video; public var startSeconds: Double; public var text: String; public var score: Double
        public var id: String { "\(video.id)@\(startSeconds)" }
    }

    public func searchMetadata(_ query: String, limit: Int = 50, downloadedOnly: Bool = false, anyTerm: Bool = false) throws -> [MetadataHit] {
        guard let match = FTSQuery.build(query, prefixLast: !anyTerm, orTerms: anyTerm) else { return [] }
        let rows = try db.query("SELECT video_id, bm25(videos_fts, 0, 4.0, 2.0, 1.0) AS score FROM videos_fts WHERE videos_fts MATCH ? ORDER BY score LIMIT ?", [.text(match), .integer(Int64(limit))])
        var out: [MetadataHit] = []
        for r in rows {
            guard let id = r.string("video_id"), let v = try video(id: id) else { continue }
            if downloadedOnly && v.status != .downloaded { continue }
            out.append(MetadataHit(video: v, score: -(r.double("score") ?? 0)))
        }
        return out
    }

    public func searchTranscripts(_ query: String, limit: Int = 20, anyTerm: Bool = false) throws -> [TranscriptHit] {
        guard let match = FTSQuery.build(query, prefixLast: !anyTerm, orTerms: anyTerm) else { return [] }
        let rows = try db.query("""
        SELECT s.video_id AS video_id, s.start_seconds AS start_seconds, s.text AS text, bm25(transcript_fts) AS score
        FROM transcript_fts f JOIN transcript_segments s ON s.id = f.segment_id WHERE transcript_fts MATCH ? ORDER BY score LIMIT ?
        """, [.text(match), .integer(Int64(limit))])
        var cache: [String: Video] = [:]
        var out: [TranscriptHit] = []
        for r in rows {
            guard let id = r.string("video_id") else { continue }
            if cache[id] == nil { cache[id] = try video(id: id) }
            guard let v = cache[id] else { continue }
            out.append(TranscriptHit(video: v, startSeconds: r.double("start_seconds") ?? 0, text: r.string("text") ?? "", score: -(r.double("score") ?? 0)))
        }
        return out
    }

    /// Combined search for the Videos tab: metadata and transcript hits merged per video.
    public func search(_ query: String, downloadedOnly: Bool = true) throws -> [Video] {
        var seen = Set<String>(); var out: [Video] = []
        for h in try searchMetadata(query, limit: 100, downloadedOnly: downloadedOnly) where seen.insert(h.video.id).inserted { out.append(h.video) }
        for h in try searchTranscripts(query, limit: 100) where seen.insert(h.video.id).inserted && (!downloadedOnly || h.video.status == .downloaded) { out.append(h.video) }
        return out
    }

    public func transcript(for videoId: String) throws -> [SubtitleCue] {
        try db.query("SELECT start_seconds, end_seconds, text FROM transcript_segments WHERE video_id = ? ORDER BY start_seconds", [.text(videoId)]).map {
            SubtitleCue(start: $0.double("start_seconds") ?? 0, end: $0.double("end_seconds") ?? 0, text: $0.string("text") ?? "")
        }
    }

    // MARK: Playback positions

    public func playbackPosition(for videoId: String) throws -> Double? {
        try db.query("SELECT position_seconds FROM playback_positions WHERE video_id = ?", [.text(videoId)]).first?.double("position_seconds")
    }
    public func savePlaybackPosition(_ seconds: Double, for videoId: String) throws {
        try db.execute("INSERT INTO playback_positions(video_id, position_seconds, updated_at) VALUES (?, ?, ?) ON CONFLICT(video_id) DO UPDATE SET position_seconds = excluded.position_seconds, updated_at = excluded.updated_at", [.text(videoId), .real(seconds), .from(Date())])
    }
}

public enum Thumbnailer {
    /// Grabs a frame a few seconds in, scaled to 480px wide.
    @discardableResult
    public static func generate(from media: URL, to output: URL, ffmpeg: URL, atSeconds: Double = 3) -> Bool {
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-y", "-loglevel", "error", "-ss", String(atSeconds), "-i", media.path, "-frames:v", "1", "-vf", "scale=480:-2", output.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        if p.terminationStatus != 0 || !FileManager.default.fileExists(atPath: output.path) {
            // Very short clips: retry at 0s.
            let q = Process(); q.executableURL = ffmpeg
            q.arguments = ["-y", "-loglevel", "error", "-i", media.path, "-frames:v", "1", "-vf", "scale=480:-2", output.path]
            q.standardOutput = FileHandle.nullDevice; q.standardError = FileHandle.nullDevice
            try? q.run(); q.waitUntilExit()
            return q.terminationStatus == 0
        }
        return true
    }
}
