import Foundation

/// The on-disk layout of a library folder chosen by the user.
///
///     Library/
///       zim/      Kiwix ZIM files
///       videos/   Downloaded videos + .json sidecar, .vtt subtitles, .jpg thumbnails
///       pages/    Captured self-contained HTML + .json metadata
///       models/   GGUF models
///       index/    SQLite database, catalogue.json, licence
///       staging/  In-progress downloads; never served from
public struct LibraryLayout: Equatable, Sendable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public var zim: URL { root.appendingPathComponent("zim", isDirectory: true) }
    public var videos: URL { root.appendingPathComponent("videos", isDirectory: true) }
    public var pages: URL { root.appendingPathComponent("pages", isDirectory: true) }
    public var documents: URL { root.appendingPathComponent("documents", isDirectory: true) }
    public var maps: URL { root.appendingPathComponent("maps", isDirectory: true) }
    public var models: URL { root.appendingPathComponent("models", isDirectory: true) }
    public var index: URL { root.appendingPathComponent("index", isDirectory: true) }
    public var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }

    public var databaseURL: URL { index.appendingPathComponent("library.sqlite") }
    public var catalogueURL: URL { index.appendingPathComponent("catalogue.json") }
    public var licenceURL: URL { index.appendingPathComponent("licence.json") }
    public var licenceActivationURL: URL { index.appendingPathComponent("licence-activation.json") }
    public var ytdlpArchiveURL: URL { videos.appendingPathComponent(".yt-dlp-archive.txt") }
    public var markerURL: URL { root.appendingPathComponent(".offlinevault-library") }

    public var allDirectories: [URL] { [root, zim, videos, pages, documents, maps, models, index, staging] }

    public enum Category: String, CaseIterable, Sendable, Identifiable {
        case zim, videos, pages, documents, maps, models, index, staging
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .zim: return "Reference (ZIM)"
            case .videos: return "Videos"
            case .pages: return "Saved pages"
            case .documents: return "Documents (PDF, EPUB)"
            case .maps: return "Offline maps"
            case .models: return "AI models"
            case .index: return "Index & database"
            case .staging: return "In-progress downloads"
            }
        }
    }

    public func directory(for category: Category) -> URL {
        switch category {
        case .zim: return zim
        case .videos: return videos
        case .pages: return pages
        case .documents: return documents
        case .maps: return maps
        case .models: return models
        case .index: return index
        case .staging: return staging
        }
    }

    public func directory(forKind kind: ArtefactKind) -> URL {
        switch kind {
        case .zim: return zim
        case .model: return models
        case .videoPack: return videos
        case .pagePack: return pages
        case .documentPack: return documents
        case .map: return maps
        case .catalogue: return index
        }
    }

    /// Creates every directory and writes a marker file so we can recognise the folder later.
    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in allDirectories {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: markerURL.path) {
            try "OfflineVault library. Do not rename subfolders.\n".write(to: markerURL, atomically: true, encoding: .utf8)
        }
    }

    public static func looksLikeLibrary(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".offlinevault-library").path)
    }

    // MARK: Storage

    public struct StorageReport: Equatable, Sendable {
        public var bytesByCategory: [Category: Int64]
        public var volumeTotalBytes: Int64
        public var volumeFreeBytes: Int64
        public var totalLibraryBytes: Int64 { bytesByCategory.values.reduce(0, +) }
        public init(bytesByCategory: [Category: Int64], volumeTotalBytes: Int64, volumeFreeBytes: Int64) {
            self.bytesByCategory = bytesByCategory
            self.volumeTotalBytes = volumeTotalBytes
            self.volumeFreeBytes = volumeFreeBytes
        }
    }

    public func storageReport() -> StorageReport {
        var by: [Category: Int64] = [:]
        for c in Category.allCases { by[c] = Self.directorySize(directory(for: c)) }
        let (total, free) = volumeCapacity()
        return StorageReport(bytesByCategory: by, volumeTotalBytes: total, volumeFreeBytes: free)
    }

    public func volumeCapacity() -> (total: Int64, free: Int64) {
        do {
            let values = try root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
            return (total, free)
        } catch { return (0, 0) }
    }

    /// Free space check used before starting downloads. Keeps a safety margin so the volume never fills completely.
    public static let lowSpaceMargin: Int64 = 2 * 1024 * 1024 * 1024

    public func hasSpace(forAdditionalBytes bytes: Int64) -> Bool {
        let (_, free) = volumeCapacity()
        return free - bytes > Self.lowSpaceMargin
    }

    public static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }
}
