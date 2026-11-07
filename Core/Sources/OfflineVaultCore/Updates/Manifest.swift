import Foundation

/// Artefact kinds published by the update service.
public enum ArtefactKind: String, Codable, CaseIterable, Sendable {
    case zim
    case videoPack = "video-pack"
    case model
    case pagePack = "page-pack"
    case documentPack = "document-pack"
    case map
    case catalogue

    public var title: String {
        switch self {
        case .zim: return "Reference library"
        case .videoPack: return "Video pack"
        case .model: return "AI model"
        case .pagePack: return "Page pack"
        case .documentPack: return "Document pack"
        case .map: return "Offline map"
        case .catalogue: return "Catalogue"
        }
    }
}

/// A file the catalogue offers but OfflineVault neither stores nor vouches for. The app downloads it from `url`
/// and checks the sha256 the publisher copied from Kiwix's own `.meta4`; the signed manifest covers these fields
/// like any other, so a tampered URL is refused with the whole catalogue. Owns its copy, like `CatalogueTrust`.
public struct ExternalSource: Codable, Equatable, Sendable, Hashable {
    public var url: URL
    /// Where `sha256` came from, e.g. `kiwix-meta4`.
    public var shaSource: String
    public var licence: String?
    public var attribution: String?

    public init(url: URL, shaSource: String, licence: String? = nil, attribution: String? = nil) {
        self.url = url; self.shaSource = shaSource; self.licence = licence; self.attribution = attribution
    }

    public static let tag = "From Kiwix"
    public static let help = "Downloaded from Kiwix's own servers, not from the OfflineVault catalogue. Checked against the sha256 Kiwix publishes; not verified by OfflineVault."
    public var host: String { url.hostAndPort }
    /// "Downloaded from download.kiwix.org and checked against the sha256 Kiwix publishes. Not verified by OfflineVault: CC BY-NC-SA 3.0 does not let OfflineVault redistribute it."
    public var explanation: String {
        "Downloaded from \(host) and checked against the sha256 Kiwix publishes. Not verified by OfflineVault: \(licence ?? "its licence") does not let OfflineVault redistribute it."
    }
    /// A failed check is Kiwix's file disagreeing with what Kiwix published, not a catalogue trust problem.
    public func checksumMismatch(label: String) -> UserFacingError {
        UserFacingError("Kiwix download did not match",
                        message: "\(label) did not match the sha256 Kiwix publishes for it. The file on \(host) is corrupt, or Kiwix changed it since this catalogue was published.",
                        recovery: "The partial file has been discarded. Try the download again later. The OfflineVault catalogue itself is unaffected.")
    }
}

/// One downloadable file published in `manifest.json`.
public struct Artefact: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var kind: ArtefactKind
    /// Relative path below the base URL, e.g. `zim/wikipedia_en_medicine_2026-09.zim`.
    public var path: String
    public var sizeBytes: Int64
    /// Lower-case hex SHA-256 of the file.
    public var sha256: String
    /// Minimum app version (semver) that can use this artefact.
    public var minAppVersion: String
    /// Every earlier artefact id this one retires, newest first: its own prior editions plus the current id and
    /// history of any entry it supersedes. Installing it removes the first of these that is installed.
    public var replaces: [String]
    /// Optional human-readable fields (not required by the schema, used by the update screen when present).
    public var title: String?
    public var summary: String?
    /// Optional content tier: "free" (no plan), "core" (fits an internal drive), "full", "complete" (external SSD). Missing = core.
    public var tier: String?
    /// Present when the bytes live on Kiwix's servers rather than OfflineVault's; `path` is then only the local file name.
    public var external: ExternalSource?

    public init(id: String, kind: ArtefactKind, path: String, sizeBytes: Int64, sha256: String, minAppVersion: String = "1.0.0", replaces: [String] = [], title: String? = nil, summary: String? = nil, tier: String? = nil, external: ExternalSource? = nil) {
        self.id = id; self.kind = kind; self.path = path; self.sizeBytes = sizeBytes; self.sha256 = sha256
        self.minAppVersion = minAppVersion; self.replaces = replaces; self.title = title; self.summary = summary; self.tier = tier; self.external = external
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(ArtefactKind.self, forKey: .kind)
        path = try c.decode(String.self, forKey: .path)
        sizeBytes = try c.decode(Int64.self, forKey: .sizeBytes)
        sha256 = try c.decode(String.self, forKey: .sha256)
        minAppVersion = try c.decode(String.self, forKey: .minAppVersion)
        replaces = try c.decodeIfPresent([String].self, forKey: .replaces) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        external = try c.decodeIfPresent(ExternalSource.self, forKey: .external)
    }

    public var contentTier: ContentTier { ContentTier(rawValue: tier ?? "") ?? .core }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var displayTitle: String { title ?? fileName }

    public func url(relativeTo base: URL) -> URL {
        if let external { return external.url }
        if path.contains("://"), let absolute = URL(string: path) { return absolute }
        // Preserve the base path (R2 custom domains may serve from a prefix).
        var s = base.absoluteString
        if !s.hasSuffix("/") { s += "/" }
        return URL(string: path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/"), relativeTo: URL(string: s)!)!.absoluteURL
    }
}

/// Storage tiers used to group artefacts in the setup and update screens. `free` needs no plan; each tier above it
/// comes with the plan that includes it (Grant.forLevel).
public enum ContentTier: String, Codable, CaseIterable, Sendable, Comparable {
    case free, core, full, complete
    public var title: String {
        switch self {
        case .free: return "Free"
        case .core: return "Core"
        case .full: return "Full text"
        case .complete: return "Complete"
        }
    }
    public var summary: String {
        switch self {
        case .free: return "The Field Guide, the CDC and FEMA packs, the US government manuals and an overview map. No plan needed."
        case .core: return "Medical and survival references, top articles, manuals. Fits an internal drive."
        case .full: return "Every Wikipedia article as text, plus everything in Core. Tens of gigabytes."
        case .complete: return "Full Wikipedia with images and large collections. Plan on an external SSD."
        }
    }
    private var order: Int { ContentTier.allCases.firstIndex(of: self)! }
    public static func < (a: ContentTier, b: ContentTier) -> Bool { a.order < b.order }
}

/// `manifest.json` as published at `<UPDATES_BASE_URL>/manifest.json`.
public struct Manifest: Codable, Equatable, Sendable {
    public var version: String
    public var publishedAt: Date
    public var artefacts: [Artefact]
    public var catalogueVersion: String

    public init(version: String, publishedAt: Date, artefacts: [Artefact], catalogueVersion: String) {
        self.version = version; self.publishedAt = publishedAt; self.artefacts = artefacts; self.catalogueVersion = catalogueVersion
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = iso.date(from: s) ?? isoFrac.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO-8601 date: \(s)")
        }
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func parse(_ data: Data) throws -> Manifest {
        do {
            let m = try decoder().decode(Manifest.self, from: data)
            try m.validate()
            return m
        } catch let e as UserFacingError {
            throw e
        } catch {
            throw UserFacingError("Invalid manifest", message: "The update service returned a manifest the app cannot read (\(error.localizedDescription)).", recovery: "Try again later; if it persists the service may be mid-publish.")
        }
    }

    public func validate() throws {
        var seen = Set<String>()
        for a in artefacts {
            guard !a.id.isEmpty, seen.insert(a.id).inserted else {
                throw UserFacingError("Invalid manifest", message: "Duplicate or empty artefact id '\(a.id)'.")
            }
            guard a.sha256.count == 64, a.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw UserFacingError("Invalid manifest", message: "Artefact '\(a.id)' has a malformed SHA-256.")
            }
            guard !a.path.isEmpty, !a.path.hasPrefix("/"), !a.path.contains("..") else {
                throw UserFacingError("Invalid manifest", message: "Artefact '\(a.id)' has an invalid path.")
            }
            guard a.sizeBytes >= 0 else { throw UserFacingError("Invalid manifest", message: "Artefact '\(a.id)' has a negative size.") }
            if let e = a.external {
                guard ["http", "https"].contains(e.url.scheme ?? ""), e.url.host != nil else {
                    throw UserFacingError("Invalid manifest", message: "Artefact '\(a.id)' has an invalid external URL.")
                }
            }
        }
    }
}

/// Simple semantic version comparison ("1.2.3" style; missing components are zero).
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public init(_ string: String) {
        let core = string.split(separator: "-").first.map(String.init) ?? string
        components = core.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
    }
    public var description: String { components.map(String.init).joined(separator: ".") }
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let n = max(lhs.components.count, rhs.components.count)
        for i in 0..<n {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }
    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The result of comparing a manifest against what is installed.
public struct ManifestDiff: Equatable, Sendable {
    public struct Change: Equatable, Sendable, Identifiable {
        public enum Reason: String, Sendable { case new, changed, replaces }
        public var artefact: Artefact
        public var reason: Reason
        /// Installed artefact id that will be removed once this one is installed.
        public var removesInstalledId: String?
        public var id: String { artefact.id }
    }

    public var changes: [Change]
    public var unchanged: [Artefact]
    /// Artefacts the current app version cannot use (minAppVersion too high).
    public var incompatible: [Artefact]
    /// Installed artefacts no longer present in the manifest (kept on disk; reported only).
    public var orphanedInstalledIds: [String]

    public var totalDownloadBytes: Int64 { changes.reduce(0) { $0 + $1.artefact.sizeBytes } }
    public var isEmpty: Bool { changes.isEmpty }

    public static func compute(manifest: Manifest, installed: [InstalledArtefact], appVersion: String) -> ManifestDiff {
        let app = SemanticVersion(appVersion)
        let byId = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
        var changes: [Change] = []
        var unchanged: [Artefact] = []
        var incompatible: [Artefact] = []
        var referenced = Set<String>()

        for a in manifest.artefacts {
            referenced.insert(a.id)
            if SemanticVersion(a.minAppVersion) > app { incompatible.append(a); continue }
            if let have = byId[a.id] {
                if have.sha256.lowercased() == a.sha256.lowercased() {
                    unchanged.append(a)
                } else {
                    changes.append(Change(artefact: a, reason: .changed, removesInstalledId: nil))
                }
            } else if let old = a.replaces.first(where: { byId[$0] != nil }) {
                referenced.insert(old)
                changes.append(Change(artefact: a, reason: .replaces, removesInstalledId: old))
            } else {
                changes.append(Change(artefact: a, reason: .new, removesInstalledId: nil))
            }
        }
        let orphaned = installed.map(\.id).filter { !referenced.contains($0) }.sorted()
        return ManifestDiff(changes: changes, unchanged: unchanged, incompatible: incompatible, orphanedInstalledIds: orphaned)
    }
}
