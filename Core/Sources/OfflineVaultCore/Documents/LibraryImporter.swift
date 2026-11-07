import Foundation

/// "Import my hoard": walks a folder, indexes every supported file (PDF, EPUB, text, video + subtitles, saved HTML),
/// de-duplicates by content hash and tags subjects. Reports progress; cancellable.
public final class LibraryImporter: @unchecked Sendable {
    public struct Progress: Sendable, Equatable {
        public var scanned = 0, total = 0, imported = 0, duplicates = 0, skipped = 0, failed = 0
        public var current = ""
        public var bySubject: [Subject: Int] = [:]
        public var errors: [String] = []
        public init() {}
    }

    public let documents: DocumentService
    public let pages: PageService
    public let videos: VideoLibraryService
    public let layout: LibraryLayout

    public init(layout: LibraryLayout, documents: DocumentService, pages: PageService, videos: VideoLibraryService) {
        self.layout = layout; self.documents = documents; self.pages = pages; self.videos = videos
    }

    public static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm"]
    public static let pageExtensions: Set<String> = ["html", "htm"]

    public func scan(_ root: URL) -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }
        let allowed = DocumentService.supportedExtensions.union(Self.videoExtensions).union(Self.pageExtensions)
        for case let f as URL in e where allowed.contains(f.pathExtension.lowercased()) {
            if f.path.hasPrefix(layout.root.path) { continue } // never import the library into itself
            out.append(f)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Imports everything under `root`. `progress` is called on the caller's thread of the importer (not main).
    public func importFolder(_ root: URL, copyVideos: Bool = true, progress: @escaping @Sendable (Progress) -> Void) async -> Progress {
        var p = Progress()
        let files = scan(root)
        p.total = files.count
        progress(p)
        for f in files {
            if Task.isCancelled { break }
            p.scanned += 1; p.current = f.lastPathComponent
            do {
                let ext = f.pathExtension.lowercased()
                if DocumentService.supportedExtensions.contains(ext) {
                    if let d = try documents.importDocument(from: f) { p.imported += 1; p.bySubject[d.subject ?? .general, default: 0] += 1 } else { p.duplicates += 1 }
                } else if Self.videoExtensions.contains(ext) {
                    if try importVideo(f, copy: copyVideos) { p.imported += 1; p.bySubject[.skills, default: 0] += 1 } else { p.duplicates += 1 }
                } else if Self.pageExtensions.contains(ext) {
                    let dest = layout.pages.appendingPathComponent(f.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: f, to: dest) }
                    try pages.indexExistingFile(dest, url: nil, title: nil)
                    p.imported += 1
                } else { p.skipped += 1 }
            } catch {
                p.failed += 1
                if p.errors.count < 25 { p.errors.append("\(f.lastPathComponent): \(error.userFacing.message)") }
            }
            progress(p)
        }
        p.current = ""
        progress(p)
        return p
    }

    /// Copies a video (+ sidecar subtitles if a .vtt/.srt with the same stem exists) into videos/ and indexes it.
    public func importVideo(_ f: URL, copy: Bool) throws -> Bool {
        let stem = f.deletingPathExtension().lastPathComponent
        let id = "local-" + String(Checksum.sha256Hex(of: Data(f.lastPathComponent.utf8)).prefix(12))
        if let existing = try videos.video(id: id), existing.status == .downloaded { return false }
        let destName = id + "." + f.pathExtension.lowercased()
        let dest = layout.videos.appendingPathComponent(destName)
        if !FileManager.default.fileExists(atPath: dest.path) {
            if copy { try FileManager.default.copyItem(at: f, to: dest) } else { try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: f) }
        }
        var subtitleName: String?
        for ext in ["vtt", "srt"] {
            let s = f.deletingLastPathComponent().appendingPathComponent(stem + "." + ext)
            if FileManager.default.fileExists(atPath: s.path) {
                subtitleName = id + ".en." + ext
                let sd = layout.videos.appendingPathComponent(subtitleName!)
                if !FileManager.default.fileExists(atPath: sd.path) { try FileManager.default.copyItem(at: s, to: sd) }
                break
            }
        }
        var thumb: String?
        if let ff = HelperBinary.ffmpeg.locate()?.url {
            let t = layout.videos.appendingPathComponent(id + ".jpg")
            if Thumbnailer.generate(from: dest, to: t, ffmpeg: ff) { thumb = t.lastPathComponent }
        }
        let title = DocumentService.titleFromFileName(f)
        let side = VideoSidecar(id: id, title: title, channel: "Imported", durationSeconds: nil, uploadDate: nil, description: "Imported from \(f.deletingLastPathComponent().lastPathComponent)", webpageURL: nil, quality: nil, fileName: destName, thumbnailFile: thumb, subtitleFile: subtitleName, downloadedAt: Date(), sourceURL: f.path)
        try VideoSidecar.encoder.encode(side).write(to: layout.videos.appendingPathComponent(id + ".json"), options: .atomic)
        try videos.importSidecar(side)
        return true
    }
}
