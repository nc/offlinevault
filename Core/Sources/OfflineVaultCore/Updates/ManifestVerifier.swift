import Foundation

public enum ManifestEnvelope {
    public static let format = "offlinevault-manifest/1"
}

/// Why the app believes, or does not believe, a catalogue is OfflineVault's. Owns the copy, like `Denial`, so the
/// updates sheet and the Library footer cannot drift.
public enum CatalogueTrust: Equatable, Sendable {
    /// Signature verified under a trusted catalogue key. `mirror` is the self-hosted base URL the bytes came from;
    /// nil when they came from the OfflineVault service.
    case verified(keyId: String, publishedAt: Date, mirror: URL?)
    /// A plain manifest from a self-hosted URL. Never produced for the official host; that is an error instead.
    case unverified(host: String)

    public var isVerified: Bool { if case .verified = self { return true } else { return false } }

    public var title: String {
        switch self {
        case .verified: return "Verified OfflineVault catalogue"
        case .unverified: return "Unverified source"
        }
    }

    /// "Published 8 Oct 2026 · release 2026.10.08" / "Published 8 Oct 2026 · release 2026.10.08 · via nas.local" /
    /// "nas.local · release 2026.10.08".
    public func detail(release: String) -> String {
        switch self {
        case .verified(_, let publishedAt, let mirror):
            let base = "Published \(DayFormat.string(publishedAt)) · release \(release)"
            return mirror.map { "\(base) · via \($0.hostAndPort)" } ?? base
        case .unverified(let host):
            return "\(host) · release \(release)"
        }
    }

    public var symbolName: String {
        switch self {
        case .verified: return "checkmark.seal.fill"
        case .unverified: return "exclamationmark.shield"
        }
    }
}

/// What `UpdateService.fetchManifest` returns: a validated manifest with the trust it earned.
public struct FetchedManifest: Equatable, Sendable {
    public var manifest: Manifest
    public var trust: CatalogueTrust
    public init(manifest: Manifest, trust: CatalogueTrust) { self.manifest = manifest; self.trust = trust }
}

/// The whole trust policy, pure. Bytes plus where they came from go in; a manifest with its trust, or a user-facing
/// error, comes out.
///
/// | source          | body      | signature          | result                                          |
/// |-----------------|-----------|--------------------|-------------------------------------------------|
/// | offlineVault    | envelope  | valid trusted key  | verified(keyId, publishedAt, mirror nil)        |
/// | offlineVault    | envelope  | untrusted key      | "Catalogue not trusted" naming the key          |
/// | offlineVault    | envelope  | bad sig or base64  | "Catalogue not trusted"                         |
/// | offlineVault    | plain     | none               | "Unsigned catalogue from the OfflineVault service" |
/// | selfHosted(url) | envelope  | valid trusted key  | verified(keyId, publishedAt, mirror url)        |
/// | selfHosted(url) | envelope  | invalid            | "Catalogue not trusted" (never downgraded)      |
/// | selfHosted(url) | plain     | none               | unverified(host)                                |
///
/// A verified manifest published before `lastVerifiedPublishedAt` is rejected, so a replayed old manifest cannot
/// roll a client back; the operator's rollback re-signs with a fresh `publishedAt`.
public enum ManifestVerifier {
    public static func open(body: Data, from source: UpdateSource, keyring: Keyring, lastVerifiedPublishedAt: Date? = nil) throws -> FetchedManifest {
        let detected: SignedEnvelope.Detected
        do { detected = try SignedEnvelope.detect(body) } catch let failure as SignatureFailure { throw rejection(failure) }

        switch (detected, source) {
        case (.envelope(let envelope), _):
            let opened: (payload: Data, keyId: String)
            do { opened = try keyring.open(envelope, format: ManifestEnvelope.format) } catch let failure as SignatureFailure { throw rejection(failure) }
            let manifest = try Manifest.parse(opened.payload)
            if let seen = lastVerifiedPublishedAt, manifest.publishedAt < seen {
                throw UserFacingError("Catalogue is older than the one already seen",
                                      message: "The service offered a catalogue published \(DayFormat.string(manifest.publishedAt)); this Mac has already accepted one published \(DayFormat.string(seen)).",
                                      recovery: "Try again later. A genuine rollback is republished with a fresh date; nothing already installed is affected.")
            }
            let mirror: URL? = { if case .selfHosted(let url) = source { return url }; return nil }()
            return FetchedManifest(manifest: manifest, trust: .verified(keyId: opened.keyId, publishedAt: manifest.publishedAt, mirror: mirror))

        case (.plain, .offlineVault):
            throw UserFacingError("Unsigned catalogue from the OfflineVault service",
                                  message: "The service answered with a catalogue that carries no signature, so the app cannot tell that it is OfflineVault's.",
                                  recovery: "Try again later; the service may be mid-publish. Nothing already installed is affected.")

        case (.plain(let bytes), .selfHosted(let url)):
            return FetchedManifest(manifest: try Manifest.parse(bytes), trust: .unverified(host: url.hostAndPort))
        }
    }

    static func rejection(_ failure: SignatureFailure) -> UserFacingError {
        switch failure {
        case .untrustedKey(let id):
            return UserFacingError("Catalogue not trusted",
                                   message: "The catalogue is signed with key '\(id)', which this build does not trust.",
                                   recovery: "Update OfflineVault; a newer build knows the current signing key.")
        default:
            return UserFacingError("Catalogue not trusted",
                                   message: "The catalogue's signature could not be verified: \(failure.reason).",
                                   recovery: "Try again later. If it persists the file was altered between the service and this Mac; nothing already installed is affected.")
        }
    }
}

extension URL {
    /// "nas.local:8080" or "offlinevault.dev"; what a user recognises as the source.
    var hostAndPort: String {
        guard let host else { return absoluteString }
        return port.map { "\(host):\($0)" } ?? host
    }
}
