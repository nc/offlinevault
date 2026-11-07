import Foundation

/// Runs yt-dlp for indexing and downloading. Media is only ever fetched for sources the user adds; nothing is redistributed.
public final class YouTubeService: @unchecked Sendable {
    public let layout: LibraryLayout
    public let library: VideoLibraryService

    public init(layout: LibraryLayout, library: VideoLibraryService) { self.layout = layout; self.library = library }

    public var ytDlpLocation: HelperBinary.Location? { HelperBinary.ytDlp.locate() }
    public var ffmpegLocation: HelperBinary.Location? { HelperBinary.ffmpeg.locate() }

    /// Indexes a source (metadata only) and stores the entries. Returns the number of videos found.
    @discardableResult
    public func indexSource(_ source: VideoSource, limit: Int? = nil) async throws -> Int {
        let exe = try HelperBinary.ytDlp.require()
        let result = try await ProcessRunner.run(exe, arguments: YtDlpCommand.indexArguments(sourceURL: source.url, playlistLimit: limit), workingDirectory: layout.staging)
        guard let jsonStart = result.stdout.firstIndex(of: "{"), let data = String(result.stdout[jsonStart...]).data(using: .utf8), !data.isEmpty else {
            let msg = Self.friendlyError(result.stderr)
            try library.recordIndexError(sourceId: source.id, message: msg)
            throw UserFacingError("Could not index source", message: msg, recovery: "Check the link opens in a browser and that you are online, then try again.")
        }
        do {
            let info = try YtDlpInfo.parse(data)
            return try library.recordIndexResult(sourceId: source.id, info: info)
        } catch {
            try library.recordIndexError(sourceId: source.id, message: error.userFacing.message)
            throw error
        }
    }

    /// Probes one video for exact format sizes (optional refinement before confirming a batch).
    public func probe(videoURL: String) async throws -> YtDlpInfo {
        let exe = try HelperBinary.ytDlp.require()
        let result = try await ProcessRunner.run(exe, arguments: YtDlpCommand.probeArguments(videoURL: videoURL), workingDirectory: layout.staging)
        guard let s = result.stdout.firstIndex(of: "{"), let data = String(result.stdout[s...]).data(using: .utf8) else {
            throw UserFacingError("Could not read video", message: Self.friendlyError(result.stderr))
        }
        return try YtDlpInfo.parse(data)
    }

    public enum DownloadEvent: Sendable { case progress(YtDlpProgressParser.Progress), status(String) }

    /// Downloads one video with yt-dlp, then finalises files + index. Cancel the Task to pause (yt-dlp `--continue` resumes).
    @discardableResult
    public func download(video: Video, quality: VideoQuality, onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> Video {
        let exe = try HelperBinary.ytDlp.require()
        try layout.ensureDirectories()
        try library.setStatus(.downloading, for: video.id)
        let args = YtDlpCommand.downloadArguments(videoURL: video.watchURL, quality: quality, outputDirectory: layout.videos, archiveFile: layout.ytdlpArchiveURL, ffmpegLocation: ffmpegLocation?.url.deletingLastPathComponent())
        let errors = ErrorBox()
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(exe, arguments: args, workingDirectory: layout.videos) { line, _ in
                guard let ev = YtDlpProgressParser.parse(line: line) else { return }
                switch ev {
                case .progress(let p): onEvent(.progress(p))
                case .status(let s): onEvent(.status(s))
                case .destination(let d): onEvent(.status("Downloading \((d as NSString).lastPathComponent)"))
                case .alreadyInArchive: onEvent(.status("Already downloaded"))
                case .error(let e): errors.append(e)
                }
            }
        } catch is CancellationError {
            try? library.setStatus(.queued, for: video.id)
            throw CancellationError()
        } catch {
            try? library.setStatus(.failed, for: video.id)
            throw error
        }
        if Task.isCancelled { try? library.setStatus(.queued, for: video.id); throw CancellationError() }
        guard result.exitCode == 0 || FileManager.default.fileExists(atPath: layout.videos.appendingPathComponent(video.id + ".mp4").path) else {
            try? library.setStatus(.failed, for: video.id)
            let msg = errors.messages.last.map(Self.friendlyError) ?? Self.friendlyError(result.stderr)
            throw UserFacingError("Download failed", message: "\(video.title): \(msg)", recovery: "Retry from the Downloads tab. If the video needs sign-in or is region-locked, it cannot be fetched.")
        }
        onEvent(.status("Indexing…"))
        do {
            return try library.finalizeDownload(videoId: video.id, quality: quality, sourceURL: nil, ffmpeg: ffmpegLocation?.url)
        } catch {
            try? library.setStatus(.failed, for: video.id)
            throw error
        }
    }

    static func friendlyError(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map(String.init)
        if let e = lines.last(where: { $0.contains("ERROR") }) {
            var m = e.replacingOccurrences(of: "ERROR: ", with: "")
            if m.contains("Sign in to confirm") { m = "YouTube is asking for sign-in (bot check). Try again later or from a different network." }
            if m.contains("Private video") { m = "This video is private." }
            if m.contains("Video unavailable") { m = "This video is unavailable." }
            if m.contains("not a valid URL") || m.contains("Unsupported URL") { m = "yt-dlp does not support this address." }
            return m
        }
        if stderr.contains("Could not resolve host") || stderr.contains("Name or service not known") || stderr.contains("nodename nor servname") { return "No internet connection." }
        return lines.last ?? "yt-dlp exited with an error."
    }

    final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func append(_ s: String) { lock.withLock { items.append(s) } }
        var messages: [String] { lock.withLock { items } }
    }
}
