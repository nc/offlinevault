import Foundation
import CryptoKit

/// A purchasable plan. Raw values are the plan ids in `website/plans.json`, Stripe's `metadata.plan` and the
/// `plan` field of a v2 licence payload. Commerce facts (prices, durations) live in the worker's plan table;
/// this enum owns only what the app needs to decide entitlements.
public enum Plan: String, Codable, CaseIterable, Sendable {
    case core, household, drive, founder

    /// Service level the plan grants on a given date. Founder is household until `householdUntil`, then core.
    public func level(at now: Date, householdUntil: Date?) -> Level {
        switch self {
        case .core: return .core
        case .household, .drive: return .household
        case .founder: return (householdUntil.map { now < $0 } ?? false) ? .household : .core
        }
    }

    /// Wi-Fi sharing is a thing you bought, not a thing you rent: these plans keep it after lapse or step-down.
    public var grantsSharing: Bool { self != .core }

    public var defaultSeats: Int {
        switch self {
        case .core, .drive: return 2
        case .household, .founder: return 6
        }
    }

    public var title: String {
        switch self {
        case .core: return "Core"
        case .household: return "Household"
        case .drive: return "Vault Drive"
        case .founder: return "Founder"
        }
    }
}

/// Service level, independent of billing. `free` is the absence of a usable licence, including one whose refreshes lapsed.
public enum Level: Comparable, CaseIterable, Sendable {
    case free, core, household

    public var title: String {
        switch self {
        case .free: return "Free"
        case .core: return "Core"
        case .household: return "Household"
        }
    }
}

/// The single table that turns a level into rights. Content tier names stay storage tiers; this is the only place
/// in Core that says which storage tiers and model artefacts a level may download from OfflineVault.
public struct Grant: Equatable, Sendable {
    public var tiers: Set<ContentTier>
    public var modelArtefactIds: Set<String>
    public var sharing: Bool

    public static func forLevel(_ level: Level) -> Grant {
        switch level {
        case .free:
            return Grant(tiers: [.free], modelArtefactIds: [], sharing: false)
        case .core:
            return Grant(tiers: [.free, .core], modelArtefactIds: [Config.defaultModelArtefactId], sharing: false)
        case .household:
            return Grant(tiers: [.free, .core, .full, .complete],
                         modelArtefactIds: [Config.defaultModelArtefactId, Config.largeModelArtefactId, Config.glimmerModelArtefactId, Config.glimmerDrafterArtefactId],
                         sharing: true)
        }
    }
}

/// Signed facts about one licence. This is the domain type every caller sees; the wire payloads are below.
public struct Licence: Equatable, Sendable {
    public var licenceId: String
    public var subscriber: String
    public var plan: Plan
    public var seats: Int
    public var issuedAt: Date
    /// When refreshes end: new editions stop, everything installed keeps working. nil = never (founder).
    public var expiresAt: Date?
    /// Founder only: the date the household level steps down to core.
    public var householdUntil: Date?

    public init(licenceId: String, subscriber: String, plan: Plan, seats: Int? = nil, issuedAt: Date, expiresAt: Date?, householdUntil: Date? = nil) {
        self.licenceId = licenceId; self.subscriber = subscriber; self.plan = plan; self.seats = seats ?? plan.defaultSeats
        self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.householdUntil = householdUntil
    }

    public func isExpired(at now: Date) -> Bool { expiresAt.map { $0 < now } ?? false }
    public func level(at now: Date) -> Level { plan.level(at: now, householdUntil: householdUntil) }

    /// nil when the payload names a plan this build does not know.
    public init?(payload p: LicencePayload) {
        guard let plan = Plan(rawValue: p.plan) else { return nil }
        self.init(licenceId: p.licenceId, subscriber: p.subscriber, plan: plan, seats: p.seats, issuedAt: p.issuedAt, expiresAt: p.expiresAt, householdUntil: p.householdUntil)
    }

    /// Everything issued before v2 was the single "standard" tier: one seat of Core.
    init(v1 p: LicencePayloadV1) {
        self.init(licenceId: p.licenceId, subscriber: p.subscriber, plan: .core, seats: 1, issuedAt: p.issuedAt, expiresAt: p.expiresAt)
    }
}

/// Wire shape of `offlinevault-licence/2`. Canonical bytes: keys sorted, ISO-8601 seconds precision, no
/// whitespace, nulls omitted, slashes unescaped. The worker's `canonicalPayload` must byte-match `encoder`.
public struct LicencePayload: Codable, Equatable, Sendable {
    public var licenceId: String
    public var subscriber: String
    public var plan: String
    public var seats: Int
    public var issuedAt: Date
    public var expiresAt: Date?
    public var householdUntil: Date?

    public init(_ l: Licence) {
        licenceId = l.licenceId; subscriber = l.subscriber; plan = l.plan.rawValue; seats = l.seats
        issuedAt = l.issuedAt; expiresAt = l.expiresAt; householdUntil = l.householdUntil
    }

    public init(licenceId: String, subscriber: String, plan: String, seats: Int, issuedAt: Date, expiresAt: Date?, householdUntil: Date? = nil) {
        self.licenceId = licenceId; self.subscriber = subscriber; self.plan = plan; self.seats = seats
        self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.householdUntil = householdUntil
    }

    public static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    public static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }
}

/// Wire shape of `offlinevault-licence/1`. Kept to read the committed fixtures and any file signed before v2.
public struct LicencePayloadV1: Codable, Equatable, Sendable {
    public var licenceId: String
    public var subscriber: String
    public var tier: String
    public var issuedAt: Date
    public var expiresAt: Date
    public var features: [String]

    public init(licenceId: String, subscriber: String, tier: String = "standard", issuedAt: Date, expiresAt: Date, features: [String] = ["updates"]) {
        self.licenceId = licenceId; self.subscriber = subscriber; self.tier = tier; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.features = features
    }
}

/// Licences travel in the shared signed envelope. The licence-specific parts (formats, canonical payload bytes,
/// signing helpers) live here so `Licence.swift` stays the one file that knows what a licence payload is.
public typealias LicenceFile = SignedEnvelope

public extension SignedEnvelope {
    static let formatV1 = "offlinevault-licence/1"
    static let formatV2 = "offlinevault-licence/2"

    /// The exact bytes a signer must sign for this licence. `licencetool canon` prints them for the cross-language test.
    static func canonicalPayload(_ payload: LicencePayload) throws -> Data { try LicencePayload.encoder.encode(payload) }
    static func canonicalPayload(_ licence: Licence) throws -> Data { try canonicalPayload(LicencePayload(licence)) }

    static func sign(_ licence: Licence, keyId: String, with privateKey: Curve25519.Signing.PrivateKey) throws -> LicenceFile {
        try sign(payload: LicencePayload(licence), keyId: keyId, with: privateKey)
    }

    /// Signs an arbitrary v2 payload (the tool uses this for the unknown-plan fixture).
    static func sign(payload: LicencePayload, keyId: String, with privateKey: Curve25519.Signing.PrivateKey) throws -> LicenceFile {
        try sign(try canonicalPayload(payload), format: formatV2, keyId: keyId, with: privateKey)
    }

    /// Signs a v1 file. Only `licencetool fixtures` uses it, to keep the back-compat fixtures regenerable.
    static func signV1(_ payload: LicencePayloadV1, with privateKey: Curve25519.Signing.PrivateKey) throws -> LicenceFile {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try sign(try e.encode(payload), format: formatV1, keyId: nil, with: privateKey)
    }
}

public enum LicenceStatus: Equatable, Sendable {
    case none
    case valid(Licence)
    case expired(Licence)
    case invalid(reason: String)

    public var licence: Licence? {
        switch self {
        case .valid(let l), .expired(let l): return l
        default: return nil
        }
    }
    /// Deliberate product rule: the library is always usable, regardless of licence state.
    public var allowsLibraryUse: Bool { true }

    public var summary: String {
        switch self {
        case .none: return "No licence on this Mac"
        case .valid(let l):
            let until = l.expiresAt.map { "refreshes until \(DayFormat.string($0))" } ?? "with no expiry"
            return "\(l.plan.title) plan for \(l.subscriber), \(until)"
        case .expired(let l): return "\(l.plan.title) plan for \(l.subscriber), refreshes ended on \(DayFormat.string(l.expiresAt!))"
        case .invalid(let r): return "Licence file rejected: \(r)"
        }
    }
}

/// Verifies against a keyring. v2 files pick their key by `keyId`; v1 files are tried against every key.
public struct LicenceVerifier: Sendable {
    public let keyring: Keyring

    public init(keyring: Keyring) { self.keyring = keyring }
    public init(publicKeys: [String: Curve25519.Signing.PublicKey]) { keyring = Keyring(publicKeys: publicKeys) }
    /// `keys`: keyId → raw 32-byte Ed25519 public key, base64.
    public init(keys: [String: String]) throws { keyring = try Keyring(keys: keys) }

    public func verify(_ file: LicenceFile, now: Date = Date()) -> LicenceStatus {
        let licence: Licence
        do {
            switch file.format {
            case LicenceFile.formatV2:
                let (payload, _) = try keyring.open(file, format: LicenceFile.formatV2)
                guard let decoded = try? LicencePayload.decoder.decode(LicencePayload.self, from: payload) else { return .invalid(reason: "payload is not a licence") }
                guard let l = Licence(payload: decoded) else { return .invalid(reason: "plan '\(decoded.plan)' needs a newer OfflineVault") }
                licence = l
            case LicenceFile.formatV1:
                let payload = try keyring.openWithAnyKey(file, format: LicenceFile.formatV1)
                guard let decoded = try? LicencePayload.decoder.decode(LicencePayloadV1.self, from: payload) else { return .invalid(reason: "payload is not a licence") }
                licence = Licence(v1: decoded)
            default:
                throw SignatureFailure.wrongFormat(found: file.format, expected: LicenceFile.formatV2)
            }
        } catch let failure as SignatureFailure {
            return .invalid(reason: failure.reason)
        } catch {
            return .invalid(reason: error.localizedDescription)
        }
        return licence.isExpired(at: now) ? .expired(licence) : .valid(licence)
    }

    public func verify(fileData: Data, now: Date = Date()) -> LicenceStatus {
        guard let file = try? JSONDecoder().decode(LicenceFile.self, from: fileData) else { return .invalid(reason: "not a licence file") }
        return verify(file, now: now)
    }
}
