import Foundation

/// A buyer's key, `OV-XXXX-XXXX-XXXX-XXXX`: 16 symbols from an alphabet without 0/O/1/I. Normalised once at the
/// boundary (case, spaces, dashes, the OV prefix) and trusted after.
public struct LicenceKey: Hashable, Sendable, CustomStringConvertible {
    public static let alphabet = Set("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    /// Display form, `OV-XXXX-XXXX-XXXX-XXXX`. This is also what the issuer receives.
    public let rawValue: String

    public init?(userInput: String) {
        var symbols = userInput.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "–" }
        if symbols.hasPrefix("OV") { symbols.removeFirst(2) }
        guard symbols.count == 16, symbols.allSatisfy(LicenceKey.alphabet.contains) else { return nil }
        let groups = stride(from: 0, to: 16, by: 4).map { String(symbols.dropFirst($0).prefix(4)) }
        rawValue = "OV-" + groups.joined(separator: "-")
    }

    public var description: String { rawValue }
    /// For Settings: the first and last groups only.
    public var masked: String { "OV-\(rawValue.dropFirst(3).prefix(4))-····-····-\(rawValue.suffix(4))" }
}

/// One Mac registered against a key, as the issuer reports it.
public struct Seat: Codable, Equatable, Sendable {
    public var deviceId: String
    public var deviceName: String?
    public var activatedAt: Date
    public var lastSeenAt: Date
    public init(deviceId: String, deviceName: String?, activatedAt: Date, lastSeenAt: Date) {
        self.deviceId = deviceId; self.deviceName = deviceName; self.activatedAt = activatedAt; self.lastSeenAt = lastSeenAt
    }
}

/// Body of `POST /api/licence/activate`. Activation and refresh are the same call: a known device uses no seat.
public struct ActivationRequest: Encodable, Equatable, Sendable {
    public var key: String
    public var deviceId: String
    public var deviceName: String?
    public var appVersion: String
    public init(key: LicenceKey, deviceId: String, deviceName: String?, appVersion: String) {
        self.key = key.rawValue; self.deviceId = deviceId; self.deviceName = deviceName; self.appVersion = appVersion
    }
}

public struct ActivationResponse: Decodable, Equatable, Sendable {
    public var licence: LicenceFile
    public var seats: [Seat]
    public var seatLimit: Int
    public init(licence: LicenceFile, seats: [Seat], seatLimit: Int) { self.licence = licence; self.seats = seats; self.seatLimit = seatLimit }
}

/// What the issuer can say no with.
public enum ActivationError: Error, Equatable, Sendable {
    case unknownKey
    case seatsExhausted([Seat])
    case ended(Date)
    case offline
    case server(String)

    public var userFacing: UserFacingError {
        switch self {
        case .unknownKey: return UserFacingError("Key not recognised", message: "That key is not on file with OfflineVault.", recovery: "Check it against the one on your receipt page. Keys use no 0, O, 1 or I.")
        case .seatsExhausted(let seats): return UserFacingError("All Macs in use", message: "This key is already active on \(seats.count) Mac\(seats.count == 1 ? "" : "s"): \(seats.compactMap(\.deviceName).joined(separator: ", ")).", recovery: "Deactivate one of them from Settings › Licence on that Mac, or remove it from the roster here.")
        case .ended(let d): return UserFacingError("Plan ended", message: "This plan ended on \(DayFormat.string(d)). Everything already installed keeps working.", recovery: "Buy a plan to resume downloads beyond the free tier.")
        case .offline: return UserFacingError("Could not reach OfflineVault", message: "Activation needs internet once. Nothing on this Mac changed.", recovery: "Check the connection and try again, or import a licence file instead.")
        case .server(let s): return UserFacingError("Activation failed", message: s, recovery: "Try again in a minute. If it keeps failing, reply to your receipt email.")
        }
    }
}

/// The wire to the issuer. One production implementation; tests pass closures.
public protocol LicenceIssuing: Sendable {
    func activate(_ request: ActivationRequest) async throws -> ActivationResponse
    /// A missing device row is a success.
    func deactivate(key: LicenceKey, deviceId: String) async throws -> [Seat]
    /// The roster as it stands. Reads only; never claims a seat.
    func seats(key: LicenceKey, deviceId: String) async throws -> [Seat]
}

/// POSTs JSON to `Config.licenceServiceURL`. Transport and status-code mapping only; no policy.
public struct LicenceActivationClient: LicenceIssuing {
    /// Resolved per call, so flipping the fixture-server toggle takes effect without rebuilding the service.
    public let baseURL: @Sendable () -> URL
    public let session: URLSession

    public init(session: URLSession = .shared) { baseURL = { Config.licenceServiceURL }; self.session = session }
    public init(baseURL: URL, session: URLSession = .shared) { self.baseURL = { baseURL }; self.session = session }

    public func activate(_ request: ActivationRequest) async throws -> ActivationResponse {
        try await post("api/licence/activate", body: request)
    }

    public func deactivate(key: LicenceKey, deviceId: String) async throws -> [Seat] {
        try await roster("api/licence/deactivate", key: key, deviceId: deviceId)
    }

    public func seats(key: LicenceKey, deviceId: String) async throws -> [Seat] {
        try await roster("api/licence/seats", key: key, deviceId: deviceId)
    }

    private func roster(_ path: String, key: LicenceKey, deviceId: String) async throws -> [Seat] {
        struct Body: Encodable { let key: String; let deviceId: String }
        let roster: SeatRoster = try await post(path, body: Body(key: key.rawValue, deviceId: deviceId))
        return roster.seats
    }

    struct SeatRoster: Decodable { var seats: [Seat]; var seatLimit: Int }
    struct Ended: Decodable { var endedAt: Date }

    private func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        var req = URLRequest(url: baseURL().appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONEncoder().encode(body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch { throw ActivationError.offline }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // The issuer's dates come from JavaScript and may carry milliseconds; the manifest decoder accepts both forms.
        let decoder = Manifest.decoder()
        switch code {
        case 200..<300:
            do { return try decoder.decode(T.self, from: data) } catch { throw ActivationError.server("The issuer returned a response this version of OfflineVault cannot read.") }
        case 404: throw ActivationError.unknownKey
        case 409: throw ActivationError.seatsExhausted((try? decoder.decode(SeatRoster.self, from: data))?.seats ?? [])
        case 410: throw ActivationError.ended((try? decoder.decode(Ended.self, from: data))?.endedAt ?? Date())
        default: throw ActivationError.server("The licence service answered HTTP \(code).")
        }
    }
}
