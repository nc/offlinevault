import Foundation

/// Owns everything licence-shaped on this Mac. Single writer of `index/licence.json` (the signed file) and
/// `index/licence-activation.json` (the key and refresh bookkeeping). The device id belongs to the Mac, not the
/// library, so it lives in `AppSettings`. AppModel talks only to this type.
public final class EntitlementService: @unchecked Sendable {
    public let verifier: LicenceVerifier
    public let layout: LibraryLayout
    public let issuer: any LicenceIssuing
    public let settings: AppSettings

    struct Activation: Codable, Equatable {
        var key: String
        var activatedAt: Date
        /// When the issuer was last asked, whether or not it answered.
        var lastRefreshAt: Date?
    }

    public init(verifier: LicenceVerifier, layout: LibraryLayout, issuer: any LicenceIssuing, settings: AppSettings = .shared) {
        self.verifier = verifier; self.layout = layout; self.issuer = issuer; self.settings = settings
    }

    public func currentStatus(now: Date = Date()) -> LicenceStatus {
        guard let data = try? Data(contentsOf: layout.licenceURL) else { return .none }
        return verifier.verify(fileData: data, now: now)
    }

    public func entitlements(source: UpdateSource, now: Date = Date()) -> Entitlements {
        Entitlements.resolve(status: currentStatus(now: now), source: source, now: now)
    }

    /// The key this Mac activated with, if any. Refresh and the seat roster use it.
    public var activationKey: LicenceKey? { activation.flatMap { LicenceKey(userInput: $0.key) } }

    private var activation: Activation? {
        guard let data = try? Data(contentsOf: layout.licenceActivationURL) else { return nil }
        return try? JSONDecoder.iso.decode(Activation.self, from: data)
    }

    private var ownDevice: (id: String, name: String?) { (settings.deviceId, Host.current().localizedName) }

    /// Online activation (and refresh: a known device uses no seat). Writes the licence file first, then the
    /// activation record, so a crash between the two leaves a verifiable licence that the next activation repairs.
    /// Throws `ActivationError`, or `UserFacingError` when the issuer's file does not verify.
    @discardableResult
    public func activate(key: LicenceKey, now: Date = Date()) async throws -> LicenceStatus {
        try await activateAndStore(key: key, now: now).status
    }

    /// Activation with a key that may replace the one this Mac already holds. The new key activates first; only
    /// then is this Mac's seat on the old key released, best effort, so a refused activation loses nothing.
    @discardableResult
    public func switchActivation(to key: LicenceKey, now: Date = Date()) async throws -> LicenceStatus {
        let previous = activationKey
        let status = try await activate(key: key, now: now)
        if let previous, previous != key { _ = try? await issuer.deactivate(key: previous, deviceId: settings.deviceId) }
        return status
    }

    /// Who holds this key's seats, from the issuer. A read; it never claims a seat or touches the files here.
    public func seats() async throws -> [Seat] {
        guard let key = activationKey else { throw UserFacingError("Not activated with a key", message: "This Mac's licence came from a file, so there is no seat roster to show.") }
        return try await issuer.seats(key: key, deviceId: settings.deviceId)
    }

    private func activateAndStore(key: LicenceKey, now: Date) async throws -> (status: LicenceStatus, seats: [Seat]) {
        let device = ownDevice
        let response = try await issuer.activate(ActivationRequest(key: key, deviceId: device.id, deviceName: device.name, appVersion: Config.appVersion))
        let status = verifier.verify(response.licence, now: now)
        if case .invalid(let reason) = status {
            throw UserFacingError("Licence not accepted", message: "OfflineVault sent a licence this version of the app cannot verify (\(reason)).", recovery: "Update OfflineVault and try again.")
        }
        try write(response.licence)
        try write(Activation(key: key.rawValue, activatedAt: activation?.activatedAt ?? now, lastRefreshAt: now))
        return (status, response.seats)
    }

    /// Offline import of a file chosen or dropped by the user. Rejected files are not stored. A file for a different
    /// licence than the activated one ends that activation's bookkeeping.
    @discardableResult
    public func importLicence(fileData: Data, now: Date = Date()) throws -> LicenceStatus {
        let status = verifier.verify(fileData: fileData, now: now)
        guard let l = status.licence else {
            let reason = if case .invalid(let r) = status { r } else { "unreadable" }
            throw UserFacingError("Licence not accepted", message: "This file is not a valid OfflineVault licence (\(reason)).", recovery: "Use the file exactly as it was sent to you, or activate with your key instead.")
        }
        if let previous = currentStatus(now: now).licence, previous.licenceId != l.licenceId { try? FileManager.default.removeItem(at: layout.licenceActivationURL) }
        try FileManager.default.createDirectory(at: layout.index, withIntermediateDirectories: true)
        try fileData.write(to: layout.licenceURL, options: .atomic)
        return status
    }

    @discardableResult
    public func importLicence(from url: URL, now: Date = Date()) throws -> LicenceStatus {
        try importLicence(fileData: try Data(contentsOf: url), now: now)
    }

    /// Silent renewal. Runs when a key is stored and the licence is within `window` of expiry, already expired, or
    /// missing (a crash between the two writes). A licence that is not valid is asked about at most once per
    /// `backoff`, counted from the last attempt, so a lapsed or ended plan does not call home on every launch.
    /// A failed call leaves the licence and key as they were.
    public func refreshIfDue(now: Date = Date(), window: TimeInterval = Config.licenceRefreshWindow, backoff: TimeInterval = Config.licenceRefreshBackoff) async {
        guard let record = activation, let key = activationKey else { return }
        switch currentStatus(now: now) {
        case .valid(let l):
            if l.expiresAt.map({ $0.timeIntervalSince(now) > window }) ?? true { return }
        case .expired, .invalid:
            if let last = record.lastRefreshAt, now.timeIntervalSince(last) < backoff { return }
        case .none:
            break
        }
        try? write(Activation(key: record.key, activatedAt: record.activatedAt, lastRefreshAt: now))
        _ = try? await activate(key: key, now: now)
    }

    /// Frees a seat on the server. Deactivating this Mac also removes both local files; server failure keeps them.
    @discardableResult
    public func deactivate(deviceId: String) async throws -> [Seat] {
        guard let key = activationKey else { throw UserFacingError("Not activated with a key", message: "This Mac's licence came from a file. Use Remove licence instead.") }
        let seats = try await issuer.deactivate(key: key, deviceId: deviceId)
        if deviceId == settings.deviceId { removeLicence() }
        return seats
    }

    /// Local removal only. Nothing is sent to the issuer, so this Mac stays on the roster and keeps its seat until
    /// someone removes it there or `deactivate(deviceId:)` runs here.
    public func removeLicence() {
        try? FileManager.default.removeItem(at: layout.licenceURL)
        try? FileManager.default.removeItem(at: layout.licenceActivationURL)
    }

    private func write(_ file: LicenceFile) throws {
        try FileManager.default.createDirectory(at: layout.index, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(file).write(to: layout.licenceURL, options: .atomic)
    }

    private func write(_ record: Activation) throws {
        try JSONEncoder.iso.encode(record).write(to: layout.licenceActivationURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
}
private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
