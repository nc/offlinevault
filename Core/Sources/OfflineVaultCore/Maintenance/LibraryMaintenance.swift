import Foundation

/// Integrity checks and repairs that keep the library usable after power loss, bit rot or a bad drive.
public final class LibraryMaintenance: @unchecked Sendable {
    public let layout: LibraryLayout
    public let database: IndexDatabase
    public init(layout: LibraryLayout, database: IndexDatabase) { self.layout = layout; self.database = database }

    // MARK: SQLite

    /// `PRAGMA quick_check` — returns problems (empty = healthy).
    public func quickCheck() -> [String] {
        guard let rows = try? database.db.query("PRAGMA quick_check") else { return ["database could not be read"] }
        let msgs = rows.compactMap { $0.columns.values.first.flatMap { v -> String? in if case .text(let s) = v { return s }; return nil } }
        return msgs == ["ok"] ? [] : msgs
    }

    /// Rebuilds every derived table from the files on disk. Conversations, settings and playback positions are kept.
    public struct RebuildReport: Sendable, Equatable { public var books = 0, documents = 0, pages = 0, videos = 0; public var problems: [String] = []; public init() {} }

    public func rebuildIndex(progress: @escaping @Sendable (String) -> Void) -> RebuildReport {
        var r = RebuildReport()
        let db = database.db
        do {
            progress("Clearing derived tables…")
            try db.transaction {
                for t in ["doc_chunks_fts", "doc_chunks", "documents", "page_chunks_fts", "page_chunks", "pages", "transcript_fts", "transcript_segments", "videos_fts"] { try db.execute("DELETE FROM \(t)") }
                try db.execute("UPDATE videos SET status = 'indexed', file_name = NULL, file_size = NULL, thumbnail_file = NULL, subtitle_file = NULL WHERE status = 'downloaded'")
            }
            progress("Re-reading reference books…")
            let zims = ((try? FileManager.default.contentsOfDirectory(at: layout.zim, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "zim" }
            let cat = Catalogue.load(from: layout.catalogueURL)
            let installed = try database.installedArtefacts()
            for z in zims {
                let name = z.deletingPathExtension().lastPathComponent
                let art = installed.first { $0.kind == .zim && $0.fileName == z.lastPathComponent }
                let entry = art.flatMap { cat?.entry(forArtefact: $0.id) }
                try database.upsertZimBook(ZimBook(name: name, artefactId: art?.id, fileName: z.lastPathComponent, title: entry?.title, description: entry?.description, language: entry?.language, articleCount: entry?.articleCount, sizeBytes: (try? z.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init), licence: entry?.licence, role: entry?.bookRole, tier: art?.id == nil ? nil : (entry?.tier.flatMap(ContentTier.init(rawValue:)))))
                r.books += 1
            }
            progress("Re-indexing documents…")
            r.documents = try DocumentService(layout: layout, database: database).rescanFolder()
            progress("Re-indexing saved pages…")
            r.pages = try PageService(layout: layout, database: database).rescanFolder()
            progress("Re-indexing videos and transcripts…")
            r.videos = try VideoLibraryService(layout: layout, database: database).rescanFolder()
            progress("Compacting…")
            _ = try? db.execute("INSERT INTO doc_chunks_fts(doc_chunks_fts) VALUES('optimize')")
            _ = try? db.execute("VACUUM")
        } catch { r.problems.append(error.userFacing.message) }
        progress("")
        return r
    }

    // MARK: Artefacts

    public struct VerifyReport: Sendable, Equatable {
        public struct Item: Sendable, Equatable, Identifiable { public var id: String; public var title: String; public var ok: Bool; public var detail: String }
        public var items: [Item] = []
        public var current = ""
        public var fraction: Double = 0
        public var finished = false
        public init() {}
        public var failures: [Item] { items.filter { !$0.ok } }
    }

    /// Re-hashes every installed artefact against the checksum recorded at install time (detects bit rot / truncation).
    public func verifyInstalledArtefacts(progress: @escaping @Sendable (VerifyReport) -> Void) -> VerifyReport {
        var rep = VerifyReport()
        let installed = (try? database.installedArtefacts()) ?? []
        let total = Double(max(installed.reduce(0) { $0 + $1.sizeBytes }, 1))
        var done: Int64 = 0
        for a in installed {
            if Task.isCancelled { break }
            rep.current = a.fileName.split(separator: "\n").first.map(String.init) ?? a.id
            progress(rep)
            switch a.kind {
            case .zim, .model, .map:
                let f = layout.directory(forKind: a.kind).appendingPathComponent(a.fileName)
                if !FileManager.default.fileExists(atPath: f.path) {
                    rep.items.append(.init(id: a.id, title: rep.current, ok: false, detail: "file is missing"))
                } else {
                    let base = done
                    let hash = (try? Checksum.sha256Hex(ofFileAt: f) { n in let frac = Double(base + n) / total; progress({ var r = rep; r.fraction = frac; return r }()) }) ?? ""
                    let ok = hash == a.sha256.lowercased()
                    rep.items.append(.init(id: a.id, title: rep.current, ok: ok, detail: ok ? "checksum matches" : (hash.isEmpty ? "could not read file" : "checksum differs — file is damaged, re-download or restore from backup")))
                }
            case .videoPack, .pagePack, .documentPack:
                // Packs were extracted; verify the extracted entries still exist.
                let dir = layout.directory(forKind: a.kind)
                let missing = a.fileName.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
                rep.items.append(.init(id: a.id, title: a.id, ok: missing.isEmpty, detail: missing.isEmpty ? "all \(a.fileName.split(separator: "\n").count) files present" : "\(missing.count) file(s) missing: \(missing.prefix(3).joined(separator: ", "))"))
            case .catalogue:
                rep.items.append(.init(id: a.id, title: "Catalogue", ok: FileManager.default.fileExists(atPath: layout.catalogueURL.path), detail: "catalogue.json"))
            }
            done += a.sizeBytes
            rep.fraction = Double(done) / total
            progress(rep)
        }
        rep.finished = true; rep.current = ""; rep.fraction = 1
        progress(rep)
        return rep
    }
}

/// Volume facts the app needs to warn about unsafe or missing storage.
public enum VolumeInfo {
    public static func isMounted(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public static func isLocal(_ url: URL) -> Bool? { try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal }
    public static func isRemovable(_ url: URL) -> Bool? { try? url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey]).volumeIsEjectable }
    public static func volumeName(_ url: URL) -> String? { try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName }
    public static func volumeURL(_ url: URL) -> URL? { (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume }
}

/// Rosetta 2 is the one dependency macOS can only install from the internet; kiwix-serve needs it on Apple Silicon.
public enum RosettaStatus {
    public static var isAppleSilicon: Bool { MachO.isAppleSilicon }
    public static func isInstalled() -> Bool {
        guard isAppleSilicon else { return true }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/arch"); p.arguments = ["-x86_64", "/usr/bin/true"]
        p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }
    public static var neededByHelpers: Bool {
        guard isAppleSilicon, let k = HelperBinary.kiwixServe.locate()?.url else { return false }
        let a = MachO.architectures(of: k); return a.contains("x86_64") && !a.contains("arm64")
    }
}

/// Memory pressure watcher: on critical pressure the heaviest helper (llama-server) is unloaded with a notice.
public final class MemoryPressureMonitor: @unchecked Sendable {
    public enum Level: String, Sendable { case normal, warning, critical }
    private var source: DispatchSourceMemoryPressure?
    public private(set) var level: Level = .normal
    public init() {}
    public static var physicalMemoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }
    public static var isLowMemoryMachine: Bool { physicalMemoryBytes <= 8 * 1024 * 1024 * 1024 }
    public func start(_ onChange: @escaping @Sendable (Level) -> Void) {
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .global(qos: .utility))
        s.setEventHandler { [weak self] in
            let ev = s.data
            let l: Level = ev.contains(.critical) ? .critical : ev.contains(.warning) ? .warning : .normal
            self?.level = l; onChange(l)
        }
        s.resume(); source = s
    }
    public func stop() { source?.cancel(); source = nil }
}

/// Clock sanity: an offline Mac with a dead clock would make a valid licence look expired.
public enum ClockSanity {
    public static func looksWrong(licence: Licence?, buildDate: Date = Config.buildDate) -> String? {
        let now = Date()
        if now < buildDate.addingTimeInterval(-86400) { return "This Mac's clock (\(now.formatted(date: .abbreviated, time: .shortened))) is earlier than the date this app was built. Set the date and time; licence expiry and update dates depend on it." }
        if let l = licence, now < l.issuedAt.addingTimeInterval(-86400) { return "This Mac's clock is earlier than your licence's issue date — the clock is probably wrong." }
        return nil
    }
}
