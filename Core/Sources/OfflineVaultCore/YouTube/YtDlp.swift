import Foundation

public enum VideoQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case p360 = "360p", p480 = "480p", p720 = "720p"
    public var id: String { rawValue }
    public var maxHeight: Int { switch self { case .p360: return 360; case .p480: return 480; case .p720: return 720 } }
    /// Typical combined bitrate (kbit/s) for YouTube AVC video + 128k AAC audio at this height; used when yt-dlp has no exact size.
    public var estimatedKbps: Double { switch self { case .p360: return 500 + 128; case .p480: return 800 + 128; case .p720: return 1600 + 128 } }
}

/// Builds yt-dlp invocations. Pure functions so they can be unit-tested against expected argument lists.
public enum YtDlpCommand {
    /// Normalises channel URLs to their /videos tab so indexing returns videos instead of a list of tabs.
    public static func normalise(sourceURL: String) -> String {
        var s = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), let host = u.host?.lowercased(), host.contains("youtube.com") else { return s }
        let path = u.path
        let isChannel = path.hasPrefix("/@") || path.hasPrefix("/channel/") || path.hasPrefix("/c/") || path.hasPrefix("/user/")
        let tabs = ["/videos", "/shorts", "/streams", "/playlists", "/live", "/featured", "/about", "/community"]
        if isChannel, !tabs.contains(where: { path.hasSuffix($0) }), u.query == nil {
            var comps = URLComponents(url: u, resolvingAgainstBaseURL: false)!
            comps.path = path.hasSuffix("/") ? path + "videos" : path + "/videos"
            return comps.url!.absoluteString
        }
        return s
    }

    public enum SourceKind: String, Codable, Sendable { case video, playlist, channel
        public static func detect(_ url: String) -> SourceKind {
            guard let u = URL(string: url), let host = u.host?.lowercased() else { return .video }
            if host.contains("youtu.be") { return .video }
            if u.path.hasPrefix("/@") || u.path.hasPrefix("/channel/") || u.path.hasPrefix("/c/") || u.path.hasPrefix("/user/") { return .channel }
            if u.path == "/playlist" || (u.query ?? "").contains("list=") && u.path != "/watch" { return .playlist }
            return .video
        }
    }

    /// Metadata-only indexing: one JSON document, no media download.
    public static func indexArguments(sourceURL: String, playlistLimit: Int? = nil) -> [String] {
        var args = ["--flat-playlist", "--dump-single-json", "--no-warnings", "--ignore-errors", "--skip-download", "--no-colors", "--no-cache-dir", "--extractor-args", "youtubetab:approximate_date"]
        if let n = playlistLimit { args += ["--playlist-end", String(n)] }
        if SourceKind.detect(sourceURL) == .video { args.append("--no-playlist") }
        args += ["--", sourceURL]
        return args
    }

    /// Full metadata for one video (used to refine size estimates); still no download.
    public static func probeArguments(videoURL: String) -> [String] {
        ["--dump-single-json", "--no-playlist", "--no-warnings", "--skip-download", "--no-colors", "--no-cache-dir", "--", videoURL]
    }

    public static func formatSelector(_ q: VideoQuality) -> String {
        let h = q.maxHeight
        return "bv*[height<=\(h)][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=\(h)][ext=mp4]+ba[ext=m4a]/bv*[height<=\(h)]+ba/b[height<=\(h)]/b"
    }

    public static let progressPrefix = "OVPROGRESS"

    /// Download one video into `outputDirectory` as `<id>.mp4` with subtitles, thumbnail and info JSON.
    public static func downloadArguments(videoURL: String, quality: VideoQuality, outputDirectory: URL, archiveFile: URL, ffmpegLocation: URL?, subtitleLanguages: [String] = ["en.*", "en"]) -> [String] {
        var args = [
            "--no-playlist", "--no-warnings", "--no-colors", "--no-cache-dir",
            "--format", formatSelector(quality),
            "--merge-output-format", "mp4",
            "--write-subs", "--write-auto-subs", "--sub-langs", subtitleLanguages.joined(separator: ","), "--sub-format", "vtt/srt/best", "--convert-subs", "vtt",
            "--write-thumbnail", "--convert-thumbnails", "jpg",
            "--write-info-json", "--no-clean-info-json",
            "--download-archive", archiveFile.path,
            "--continue", "--no-overwrites", "--no-mtime", "--retries", "5", "--fragment-retries", "5",
            "--newline", "--progress", "--progress-template", "download:\(progressPrefix) %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s",
            "--paths", outputDirectory.path,
            "--output", "%(id)s.%(ext)s",
        ]
        if let ff = ffmpegLocation { args += ["--ffmpeg-location", ff.path] }
        args += ["--", videoURL]
        return args
    }
}

/// Lenient model of yt-dlp JSON (`--dump-single-json`). Flat-playlist entries and full video JSON share these fields.
public struct YtDlpInfo: Codable, Equatable, Sendable {
    public var _type: String?
    public var id: String?
    public var title: String?
    public var description: String?
    public var duration: Double?
    public var uploader: String?
    public var channel: String?
    public var channel_id: String?
    public var upload_date: String?
    public var webpage_url: String?
    public var url: String?
    public var ie_key: String?
    public var thumbnail: String?
    public var thumbnails: [Thumbnail]?
    public var view_count: Int64?
    public var filesize_approx: Int64?
    public var formats: [Format]?
    public var entries: [YtDlpInfo]?
    public var playlist_count: Int?
    public var requested_subtitles: [String: Subtitle]?
    public var subtitles: [String: [Subtitle]]?
    public var automatic_captions: [String: [Subtitle]]?
    public var ext: String?
    public var height: Int?
    public var width: Int?

    public struct Thumbnail: Codable, Equatable, Sendable { public var url: String?; public var width: Int?; public var height: Int? }
    public struct Subtitle: Codable, Equatable, Sendable { public var ext: String?; public var url: String?; public var name: String?; public var filepath: String? }
    public struct Format: Codable, Equatable, Sendable {
        public var format_id: String?
        public var ext: String?
        public var vcodec: String?
        public var acodec: String?
        public var height: Int?
        public var width: Int?
        public var filesize: Int64?
        public var filesize_approx: Int64?
        public var tbr: Double?
        public var protocol_: String?
        enum CodingKeys: String, CodingKey { case format_id, ext, vcodec, acodec, height, width, filesize, filesize_approx, tbr; case protocol_ = "protocol" }
    }

    public static func parse(_ data: Data) throws -> YtDlpInfo {
        do { return try JSONDecoder().decode(YtDlpInfo.self, from: data) }
        catch { throw UserFacingError("Could not read video metadata", message: "yt-dlp returned JSON the app could not parse (\(error.localizedDescription)).", recovery: "Update yt-dlp by running scripts/fetch_binaries.sh, then index the source again.") }
    }

    public var isPlaylist: Bool { _type == "playlist" || entries != nil }
    public var bestThumbnailURL: String? { thumbnail ?? thumbnails?.max(by: { ($0.width ?? 0) < ($1.width ?? 0) })?.url }
    public var channelName: String? { channel ?? uploader }
    public var videoURL: String? { webpage_url ?? url ?? id.map { "https://www.youtube.com/watch?v=\($0)" } }

    /// Flattens nested playlists (channel → tabs → videos) into individual video entries.
    public func flattenedVideos() -> [YtDlpInfo] {
        if let entries {
            return entries.flatMap { e -> [YtDlpInfo] in
                if e.entries != nil { return e.flattenedVideos() }
                guard let id = e.id, !id.isEmpty else { return [] }
                if let t = e._type, t == "playlist" { return [] }
                return [e]
            }
        }
        if let id, !id.isEmpty, _type != "playlist" { return [self] }
        return []
    }
}

/// Estimates the download size for a quality, from exact format sizes when available.
public enum SizeEstimator {
    public static func estimate(duration: Double?, quality: VideoQuality, formats: [YtDlpInfo.Format]? = nil) -> Int64? {
        if let formats, !formats.isEmpty {
            let video = formats.filter { ($0.vcodec ?? "none") != "none" && ($0.height ?? 0) <= quality.maxHeight && ($0.height ?? 0) > 0 }
            let bestVideo = video.max { a, b in
                if (a.height ?? 0) != (b.height ?? 0) { return (a.height ?? 0) < (b.height ?? 0) }
                let aAvc = (a.vcodec ?? "").hasPrefix("avc1"), bAvc = (b.vcodec ?? "").hasPrefix("avc1")
                if aAvc != bAvc { return !aAvc } // prefer avc1
                return (a.tbr ?? 0) < (b.tbr ?? 0)
            }
            let audio = formats.filter { ($0.vcodec ?? "none") == "none" && ($0.acodec ?? "none") != "none" }
            let bestAudio = audio.filter { $0.ext == "m4a" }.max { ($0.tbr ?? 0) < ($1.tbr ?? 0) } ?? audio.max { ($0.tbr ?? 0) < ($1.tbr ?? 0) }
            func size(_ f: YtDlpInfo.Format?) -> Int64? {
                guard let f else { return nil }
                if let s = f.filesize ?? f.filesize_approx { return s }
                if let tbr = f.tbr, let d = duration { return Int64(tbr * 1000 / 8 * d) }
                return nil
            }
            if let v = bestVideo {
                let vs = size(v) ?? 0
                let isMuxed = (v.acodec ?? "none") != "none"
                let as_ = isMuxed ? 0 : (size(bestAudio) ?? 0)
                if vs > 0 { return vs + as_ }
            }
        }
        guard let duration, duration > 0 else { return nil }
        return Int64(quality.estimatedKbps * 1000 / 8 * duration)
    }
}

/// Parses yt-dlp's progress and status lines.
public enum YtDlpProgressParser {
    public struct Progress: Equatable, Sendable {
        public var downloadedBytes: Int64
        public var totalBytes: Int64?
        public var bytesPerSecond: Double?
        public var etaSeconds: Double?
        public var fraction: Double? { totalBytes.map { $0 > 0 ? Double(downloadedBytes) / Double($0) : 0 } }
    }

    public enum Event: Equatable, Sendable {
        case progress(Progress)
        case status(String)
        case destination(String)
        case alreadyInArchive
        case error(String)
    }

    public static func parse(line: String) -> Event? {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix(YtDlpCommand.progressPrefix) {
            let parts = l.split(separator: " ").dropFirst().map(String.init)
            guard parts.count >= 2 else { return nil }
            func num(_ s: String) -> Double? { s == "NA" || s == "None" ? nil : Double(s) }
            let downloaded = Int64(num(parts[0]) ?? 0)
            let total = num(parts[1]).map(Int64.init) ?? (parts.count > 2 ? num(parts[2]).map(Int64.init) : nil)
            return .progress(Progress(downloadedBytes: downloaded, totalBytes: total, bytesPerSecond: parts.count > 3 ? num(parts[3]) : nil, etaSeconds: parts.count > 4 ? num(parts[4]) : nil))
        }
        if l.hasPrefix("ERROR:") { return .error(String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces)) }
        if l.contains("has already been recorded in the archive") { return .alreadyInArchive }
        if l.hasPrefix("[download] Destination:") { return .destination(String(l.dropFirst("[download] Destination:".count)).trimmingCharacters(in: .whitespaces)) }
        if l.hasPrefix("[Merger]") { return .status("Merging video and audio…") }
        if l.hasPrefix("[info] Writing video subtitles") || l.contains("Writing video subtitles") { return .status("Saving subtitles…") }
        if l.hasPrefix("[info]") && l.contains("thumbnail") { return .status("Saving thumbnail…") }
        if l.hasPrefix("[download]") && l.contains("%") {
            // Fallback for classic progress lines "[download]  45.2% of 12.34MiB at 1.20MiB/s ETA 00:05"
            let re = try! NSRegularExpression(pattern: "([0-9.]+)% of ~?\\s*([0-9.]+)([KMG]i?B)")
            if let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let pr = Range(m.range(at: 1), in: l), let sr = Range(m.range(at: 2), in: l), let ur = Range(m.range(at: 3), in: l),
               let pct = Double(l[pr]), let sz = Double(l[sr]) {
                let table: [String: Double] = ["KiB": 1024, "MiB": 1_048_576, "GiB": 1_073_741_824, "KB": 1000, "MB": 1e6, "GB": 1e9]
                let mult: Double = table[String(l[ur])] ?? 1
                let total = Int64(sz * mult)
                return .progress(Progress(downloadedBytes: Int64(Double(total) * pct / 100), totalBytes: total, bytesPerSecond: nil, etaSeconds: nil))
            }
        }
        return nil
    }
}
