import Foundation

/// Fetches the manifest, diffs it against the installed library, downloads into staging and installs atomically.
/// A failed or interrupted update never touches the live library: files move into place only after checksum verification.
public final class UpdateService: @unchecked Sendable {
    public let layout: LibraryLayout
    public let database: IndexDatabase
    public let downloader: ResumableDownloader
    public let session: URLSession
    public let keyring: Keyring
    public let settings: AppSettings
    public var baseURL: URL
    public var appVersion: String

    /// The bundled catalogue keys. A test asserts the `Config` table parses, so this cannot fail at runtime.
    public static let catalogueKeyring = try! Keyring(keys: Config.cataloguePublicKeys)

    public init(layout: LibraryLayout, database: IndexDatabase, baseURL: URL = Config.updatesBaseURL, appVersion: String = Config.appVersion, session: URLSession = .shared, downloader: ResumableDownloader? = nil, keyring: Keyring = UpdateService.catalogueKeyring, settings: AppSettings = .shared) {
        self.layout = layout; self.database = database; self.baseURL = baseURL; self.appVersion = appVersion
        self.session = session; self.downloader = downloader ?? ResumableDownloader(); self.keyring = keyring; self.settings = settings
    }

    // MARK: Manifest

    /// Fetches, verifies and parses `manifest.json`. The trust decision is `ManifestVerifier`'s; this only records the
    /// newest verified `publishedAt` so a replayed older catalogue is refused next time.
    public func fetchManifest() async throws -> FetchedManifest {
        var request = URLRequest(url: baseURL.appendingPathComponent(Config.manifestFileName))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UserFacingError("Update check failed", message: "The update service answered HTTP \(http.statusCode) for manifest.json.", recovery: "Try again in a few minutes. A developer build can check the service URL in Settings › Updates.")
        }
        let fetched = try ManifestVerifier.open(body: data, from: UpdateSource(baseURL: baseURL), keyring: keyring, lastVerifiedPublishedAt: settings.lastVerifiedPublishedAt)
        if case .verified(_, let publishedAt, _) = fetched.trust { settings.lastVerifiedPublishedAt = publishedAt }
        return fetched
    }

    public func diff(_ manifest: Manifest) throws -> ManifestDiff {
        ManifestDiff.compute(manifest: manifest, installed: try database.installedArtefacts(), appVersion: appVersion)
    }

    // MARK: Install

    public enum Phase: Equatable, Sendable {
        case downloading(DownloadProgress)
        /// 0…1 while the SHA-256 is computed (a 100 GB ZIM takes minutes).
        case verifying(Double)
        case installing
        case done
    }

    /// Downloads and installs one change. Safe to call repeatedly (resumes partial downloads).
    public func apply(_ change: ManifestDiff.Change, manifestVersion: String, progress: @escaping @Sendable (Phase) -> Void) async throws {
        let artefact = change.artefact
        guard layout.hasSpace(forAdditionalBytes: artefact.sizeBytes) else {
            throw UserFacingError("Not enough space", message: "\(artefact.displayTitle) needs \(ByteFormat.string(artefact.sizeBytes)) but the library volume is nearly full.", recovery: "Free up space or move the library to a larger drive in Settings › Storage.")
        }
        let verified = try await downloader.download(artefact, from: baseURL, staging: layout.staging, progress: { p in progress(.downloading(p)) }, verifyProgress: { f in progress(.verifying(f)) })
        progress(.installing)
        try install(verifiedFile: verified, artefact: artefact, removingInstalledId: change.removesInstalledId, manifestVersion: manifestVersion)
        progress(.done)
    }

    /// Moves a verified file from staging into its final location and updates the index. Atomic per artefact:
    /// the previous file (same name or replaced id) is parked in staging until the new one is in place, then deleted.
    public func install(verifiedFile: URL, artefact: Artefact, removingInstalledId: String?, manifestVersion: String) throws {
        let fm = FileManager.default
        let destDir = layout.directory(forKind: artefact.kind)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        switch artefact.kind {
        case .zim, .model, .map:
            let dest = destDir.appendingPathComponent(artefact.fileName)
            let parked = layout.staging.appendingPathComponent(".previous-" + artefact.fileName)
            try? fm.removeItem(at: parked)
            let hadPrevious = fm.fileExists(atPath: dest.path)
            if hadPrevious { try fm.moveItem(at: dest, to: parked) }
            do {
                try fm.moveItem(at: verifiedFile, to: dest)
            } catch {
                if hadPrevious { try? fm.moveItem(at: parked, to: dest) }
                throw UserFacingError("Install failed", message: "Could not move \(artefact.displayTitle) into the library: \(error.localizedDescription)", recovery: "Check the library volume is writable and try again.")
            }
            try? fm.removeItem(at: parked)
            try finalizeIndex(artefact: artefact, fileName: artefact.fileName, removingInstalledId: removingInstalledId, manifestVersion: manifestVersion)
            if artefact.kind == .zim {
                let name = (artefact.fileName as NSString).deletingPathExtension
                let cat = Catalogue.load(from: layout.catalogueURL)?.entry(forArtefact: artefact.id)
                try database.upsertZimBook(ZimBook(name: name, artefactId: artefact.id, fileName: artefact.fileName, title: cat?.title ?? artefact.title, description: cat?.description ?? artefact.summary, language: cat?.language, articleCount: cat?.articleCount, sizeBytes: artefact.sizeBytes, licence: cat?.licence, role: cat?.bookRole, tier: artefact.contentTier, isExternal: artefact.external != nil))
            }

        case .catalogue:
            let dest = layout.catalogueURL
            _ = try? fm.replaceItemAt(dest, withItemAt: verifiedFile) ?? { try fm.moveItem(at: verifiedFile, to: dest); return dest }()
            try finalizeIndex(artefact: artefact, fileName: dest.lastPathComponent, removingInstalledId: removingInstalledId, manifestVersion: manifestVersion)
            // Enrich any already-installed ZIM rows with catalogue metadata.
            if let cat = Catalogue.load(from: dest) {
                for book in try database.zimBooks() {
                    if let aid = book.artefactId, let e = cat.entry(forArtefact: aid) {
                        var b = book; b.title = e.title; b.description = e.description ?? b.description; b.language = e.language ?? b.language; b.licence = e.licence ?? b.licence
                        b.role = e.bookRole; b.tier = e.tier.flatMap(ContentTier.init(rawValue:)) ?? b.tier
                        try database.upsertZimBook(b)
                    }
                }
            }

        case .videoPack, .pagePack, .documentPack:
            // Archives (tar.gz / zip) extracted into the category folder. Extract to a staging folder first.
            let extractDir = layout.staging.appendingPathComponent(".extract-" + artefact.id, isDirectory: true)
            try? fm.removeItem(at: extractDir)
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try Archive.extract(verifiedFile, to: extractDir)
            // Move each top-level entry (file or folder) into place, overwriting same-named entries.
            let entries = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
            var moved: [String] = []
            for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
                let dest = destDir.appendingPathComponent(entry.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try fm.moveItem(at: entry, to: dest)
                moved.append(entry.lastPathComponent)
            }
            try? fm.removeItem(at: extractDir)
            try? fm.removeItem(at: verifiedFile)
            try finalizeIndex(artefact: artefact, fileName: moved.joined(separator: "\n"), removingInstalledId: removingInstalledId, manifestVersion: manifestVersion)
        }
    }

    private func finalizeIndex(artefact: Artefact, fileName: String, removingInstalledId: String?, manifestVersion: String) throws {
        try database.db.transaction {
            if let old = removingInstalledId, old != artefact.id, let oldInstalled = try database.installedArtefact(id: old) {
                removeFiles(of: oldInstalled, keepingFileNamed: fileName)
                try database.removeInstalled(id: old)
                if oldInstalled.kind == .zim { try database.removeZimBook(fileName: oldInstalled.fileName) }
            }
            try database.recordInstalled(InstalledArtefact(id: artefact.id, kind: artefact.kind, path: artefact.path, fileName: fileName, sizeBytes: artefact.sizeBytes, sha256: artefact.sha256.lowercased(), installedAt: Date(), manifestVersion: manifestVersion))
        }
    }

    private func removeFiles(of installed: InstalledArtefact, keepingFileNamed keep: String) {
        let dir = layout.directory(forKind: installed.kind)
        for name in installed.fileName.split(separator: "\n").map(String.init) where name != keep && !name.isEmpty {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Removes an installed artefact and its files (user-initiated).
    public func uninstall(id: String) throws {
        guard let installed = try database.installedArtefact(id: id) else { return }
        removeFiles(of: installed, keepingFileNamed: "")
        try database.removeInstalled(id: id)
        if installed.kind == .zim { try database.removeZimBook(fileName: installed.fileName) }
    }

    /// Deletes stale partial downloads that no longer correspond to any manifest artefact.
    public func cleanStaging(keeping artefacts: [Artefact]) {
        let fm = FileManager.default
        let keep = Set(artefacts.map { ResumableDownloader.partFileURL(for: $0, staging: layout.staging).lastPathComponent })
        guard let items = try? fm.contentsOfDirectory(at: layout.staging, includingPropertiesForKeys: nil) else { return }
        for item in items {
            let n = item.lastPathComponent
            if n.hasSuffix(".part") && !keep.contains(n) { try? fm.removeItem(at: item); try? fm.removeItem(at: ResumableDownloadState.stateURL(forPartFile: item)) }
            if n.hasPrefix(".extract-") || n.hasPrefix(".previous-") { try? fm.removeItem(at: item) }
        }
    }
}

/// Archive extraction via the system `tar` (bsdtar handles .tar, .tar.gz and .zip).
public enum Archive {
    public static func extract(_ archive: URL, to directory: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xf", archive.path, "-C", directory.path]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UserFacingError("Could not unpack", message: "The archive \(archive.lastPathComponent) could not be extracted. \(msg.trimmingCharacters(in: .whitespacesAndNewlines))", recovery: "Delete it from Downloads and fetch it again.")
        }
    }
}
