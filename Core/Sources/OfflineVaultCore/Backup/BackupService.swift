import Foundation

/// Clones the library to another volume and verifies it. "Two is one, one is none."
public final class BackupService: @unchecked Sendable {
    public struct Report: Sendable, Equatable {
        public var filesCopied = 0, filesSkipped = 0, filesVerified = 0, bytesCopied: Int64 = 0
        public var mismatches: [String] = []
        public var current = ""
        public var finished = false
        public var error: String?
        public init() {}
    }

    public let layout: LibraryLayout
    public let database: IndexDatabase
    public init(layout: LibraryLayout, database: IndexDatabase) { self.layout = layout; self.database = database }

    public static let lastBackupKey = "backup.lastDate"
    public static let lastBackupPathKey = "backup.lastPath"
    /// Flash storage should be powered up and re-verified at least this often.
    public static let reminderInterval: TimeInterval = 180 * 86400

    public var lastBackupDate: Date? { ((try? database.value(forKey: Self.lastBackupKey)) ?? nil).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } }
    public var lastBackupPath: String? { (try? database.value(forKey: Self.lastBackupPathKey)) ?? nil }
    public var isReminderDue: Bool { lastBackupDate.map { Date().timeIntervalSince($0) > Self.reminderInterval } ?? true }

    /// Mirrors the library into `destination` (a folder on another drive). Files with equal size and modification
    /// date are skipped; everything copied is hash-verified. staging/ is excluded.
    public func clone(to destination: URL, progress: @escaping @Sendable (Report) -> Void) async -> Report {
        var r = Report()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let rootPath = layout.root.resolvingSymlinksInPath().path
            guard let e = fm.enumerator(at: layout.root.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { throw UserFacingError("Backup failed", message: "Could not read the library folder.") }
            let files = e.compactMap { $0 as? URL }
            for f in files {
                if Task.isCancelled { r.error = "Cancelled"; break }
                let rel = f.resolvingSymlinksInPath().path.replacingOccurrences(of: rootPath + "/", with: "")
                if rel.hasPrefix("staging/") { continue }
                let vals = try f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard vals.isRegularFile == true else { continue }
                let dest = destination.appendingPathComponent(rel)
                r.current = rel
                if let dv = try? dest.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), dv.fileSize == vals.fileSize, dv.contentModificationDate == vals.contentModificationDate {
                    r.filesSkipped += 1; progress(r); continue
                }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: f, to: dest)
                r.filesCopied += 1; r.bytesCopied += Int64(vals.fileSize ?? 0)
                if try Checksum.sha256Hex(ofFileAt: f) == Checksum.sha256Hex(ofFileAt: dest) { r.filesVerified += 1 } else { r.mismatches.append(rel) }
                progress(r)
            }
            try "OfflineVault library backup of \(layout.root.path)\n\(ISO8601DateFormatter().string(from: Date()))\n".write(to: destination.appendingPathComponent(".offlinevault-backup"), atomically: true, encoding: .utf8)
            if r.error == nil && r.mismatches.isEmpty {
                try database.setValue(String(Date().timeIntervalSince1970), forKey: Self.lastBackupKey)
                try database.setValue(destination.path, forKey: Self.lastBackupPathKey)
            }
        } catch { r.error = error.userFacing.message }
        r.finished = true; r.current = ""
        progress(r)
        return r
    }

    /// Re-hashes files in an existing backup against the library to confirm the drive still reads correctly.
    public func verify(_ backup: URL, sampleLimit: Int = 200) -> (checked: Int, mismatches: [String]) {
        let fm = FileManager.default
        var checked = 0; var bad: [String] = []
        let rootPath = layout.root.resolvingSymlinksInPath().path
        guard let e = fm.enumerator(at: layout.root.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return (0, []) }
        for case let f as URL in e {
            let rel = f.resolvingSymlinksInPath().path.replacingOccurrences(of: rootPath + "/", with: "")
            if rel.hasPrefix("staging/") || rel.hasPrefix("index/") { continue }
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let dest = backup.appendingPathComponent(rel)
            guard fm.fileExists(atPath: dest.path) else { bad.append(rel + " (missing)"); continue }
            if (try? Checksum.sha256Hex(ofFileAt: f)) != (try? Checksum.sha256Hex(ofFileAt: dest)) { bad.append(rel) }
            checked += 1
            if checked >= sampleLimit { break }
        }
        return (checked, bad)
    }
}
