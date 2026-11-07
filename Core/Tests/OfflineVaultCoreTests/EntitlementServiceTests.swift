import XCTest
import CryptoKit
@testable import OfflineVaultCore

/// Issuer stand-in: each test hands it closures and reads back what it was asked.
final class StubIssuer: LicenceIssuing, @unchecked Sendable {
    var onActivate: (ActivationRequest) async throws -> ActivationResponse = { _ in throw ActivationError.offline }
    var onDeactivate: (LicenceKey, String) async throws -> [Seat] = { _, _ in [] }
    var onSeats: (LicenceKey, String) async throws -> [Seat] = { _, _ in [] }
    var activations: [ActivationRequest] = []
    var deactivations: [(LicenceKey, String)] = []
    var rosters: [(LicenceKey, String)] = []
    func activate(_ request: ActivationRequest) async throws -> ActivationResponse { activations.append(request); return try await onActivate(request) }
    func deactivate(key: LicenceKey, deviceId: String) async throws -> [Seat] { deactivations.append((key, deviceId)); return try await onDeactivate(key, deviceId) }
    func seats(key: LicenceKey, deviceId: String) async throws -> [Seat] { rosters.append((key, deviceId)); return try await onSeats(key, deviceId) }
}

final class EntitlementServiceTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
    let signing = Curve25519.Signing.PrivateKey()
    let key = LicenceKey(userInput: "OV-DEVC-2345-6789-ABCD")!
    var verifier: LicenceVerifier { LicenceVerifier(publicKeys: ["t": signing.publicKey]) }
    var layout: LibraryLayout!
    var settings: AppSettings!
    var suite = ""
    var issuer: StubIssuer!
    var svc: EntitlementService!

    override func setUpWithError() throws {
        layout = try makeTempLibrary(self)
        suite = "ov-tests-" + UUID().uuidString
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        addTeardownBlock { [suite] in UserDefaults.standard.removePersistentDomain(forName: suite) }
        issuer = StubIssuer()
        svc = EntitlementService(verifier: verifier, layout: layout, issuer: issuer, settings: settings)
    }

    func file(_ plan: Plan, id: String = "L1", expires: Date? = nil, keyId: String = "t") throws -> LicenceFile {
        try LicenceFile.sign(Licence(licenceId: id, subscriber: "s", plan: plan, issuedAt: now.addingTimeInterval(-86400), expiresAt: expires ?? now.addingTimeInterval(400 * 86400)), keyId: keyId, with: signing)
    }
    func seat(_ id: String, _ name: String) -> Seat { Seat(deviceId: id, deviceName: name, activatedAt: now, lastSeenAt: now) }
    var hasLicence: Bool { FileManager.default.fileExists(atPath: layout.licenceURL.path) }
    var hasActivation: Bool { FileManager.default.fileExists(atPath: layout.licenceActivationURL.path) }

    func testActivateWritesBothFilesAndSendsThisMacsDeviceId() async throws {
        let file = try file(.household)
        issuer.onActivate = { _ in ActivationResponse(licence: file, seats: [self.seat("d1", "Study")], seatLimit: 6) }
        let status = try await svc.activate(key: key, now: now)
        XCTAssertEqual(status.licence?.plan, .household)
        XCTAssertTrue(hasLicence && hasActivation)
        XCTAssertEqual(svc.activationKey, key)
        XCTAssertEqual(svc.currentStatus(now: now).licence?.plan, .household)
        XCTAssertEqual(issuer.activations.map(\.key), ["OV-DEVC-2345-6789-ABCD"])
        XCTAssertEqual(issuer.activations.first?.deviceId, settings.deviceId)
        XCTAssertFalse(settings.deviceId.isEmpty)
        XCTAssertEqual(AppSettings(defaults: UserDefaults(suiteName: suite)!).deviceId, settings.deviceId, "the device id is minted once and read back")
        XCTAssertEqual(svc.entitlements(source: .offlineVault, now: now).level, .household)
    }

    func testSeatsExhaustedLeavesDiskUntouched() async throws {
        issuer.onActivate = { _ in throw ActivationError.seatsExhausted([self.seat("a", "Kitchen"), self.seat("b", "Van")]) }
        do { _ = try await svc.activate(key: key, now: now); XCTFail("must throw") }
        catch let e as ActivationError { XCTAssertEqual(e, .seatsExhausted([seat("a", "Kitchen"), seat("b", "Van")])); XCTAssertTrue(e.userFacing.message.contains("Kitchen, Van")) }
        XCTAssertFalse(hasLicence || hasActivation)
        XCTAssertNil(svc.activationKey)
    }

    func testExpiredFileFromIssuerIsStoredSoALapsedMacLearnsTheDate() async throws {
        let lapsed = now.addingTimeInterval(-86400)
        let file = try file(.core, expires: lapsed)
        issuer.onActivate = { _ in ActivationResponse(licence: file, seats: [], seatLimit: 2) }
        let status = try await svc.activate(key: key, now: now)
        if case .expired(let l) = status { XCTAssertEqual(l.expiresAt, lapsed) } else { XCTFail("\(status)") }
        XCTAssertEqual(svc.entitlements(source: .offlineVault, now: now).lapsedOn, lapsed)
    }

    func testUntrustedFileFromIssuerIsRejectedAndNothingStored() async throws {
        let rogue = try LicenceFile.sign(Licence(licenceId: "x", subscriber: "s", plan: .core, issuedAt: now, expiresAt: nil), keyId: "t", with: Curve25519.Signing.PrivateKey())
        issuer.onActivate = { _ in ActivationResponse(licence: rogue, seats: [], seatLimit: 2) }
        await XCTAssertThrowsErrorAsync { try await self.svc.activate(key: self.key, now: self.now) }
        XCTAssertFalse(hasLicence || hasActivation)
    }

    func testImportOfADifferentLicenceEndsActivationBookkeeping() async throws {
        let activated = try file(.core, id: "L1")
        issuer.onActivate = { _ in ActivationResponse(licence: activated, seats: [], seatLimit: 2) }
        try await svc.activate(key: key, now: now)
        let enc = JSONEncoder()
        _ = try svc.importLicence(fileData: try enc.encode(try file(.core, id: "L1", expires: now.addingTimeInterval(800 * 86400))), now: now)
        XCTAssertEqual(svc.activationKey, key, "a newer file for the same licence keeps the key")
        _ = try svc.importLicence(fileData: try enc.encode(try file(.household, id: "L2")), now: now)
        XCTAssertNil(svc.activationKey, "a file for another licence ends the activation")
        XCTAssertEqual(svc.currentStatus(now: now).licence?.licenceId, "L2")
        XCTAssertThrowsError(try svc.importLicence(fileData: Data("junk".utf8), now: now))
        XCTAssertThrowsError(try svc.importLicence(fileData: Data(), now: now)) { XCTAssertTrue($0 is UserFacingError, "an empty file is rejected like any other non-licence") }
        XCTAssertEqual(svc.currentStatus(now: now).licence?.licenceId, "L2", "rejected files are not stored")
    }

    func testRefreshIfDueOnlyInsideTheWindowAndSwallowsOffline() async throws {
        let far = try file(.core, id: "L1", expires: now.addingTimeInterval(100 * 86400))
        issuer.onActivate = { _ in ActivationResponse(licence: far, seats: [], seatLimit: 2) }
        try await svc.activate(key: key, now: now)
        issuer.activations.removeAll()
        await svc.refreshIfDue(now: now, window: 14 * 86400)
        XCTAssertTrue(issuer.activations.isEmpty, "100 days out is not due")

        let tenDaysLeft = now.addingTimeInterval(90 * 86400)
        let renewed = try file(.core, id: "L1", expires: now.addingTimeInterval(375 * 86400))
        issuer.onActivate = { _ in throw ActivationError.offline }
        await svc.refreshIfDue(now: tenDaysLeft, window: 14 * 86400)
        XCTAssertEqual(issuer.activations.count, 1, "10 days out is due")
        XCTAssertEqual(svc.currentStatus(now: now).licence?.expiresAt, far.expiry, "offline leaves the old file")
        XCTAssertEqual(svc.activationKey, key)

        issuer.onActivate = { _ in ActivationResponse(licence: renewed, seats: [], seatLimit: 2) }
        await svc.refreshIfDue(now: tenDaysLeft, window: 14 * 86400)
        XCTAssertEqual(svc.currentStatus(now: now).licence?.expiresAt, renewed.expiry, "a due refresh installs the fresh file")

        svc.removeLicence()
        issuer.activations.removeAll()
        await svc.refreshIfDue(now: now)
        XCTAssertTrue(issuer.activations.isEmpty, "no stored key, no call")
    }

    func testRefreshWithKeyButNoFileRepairsTheCrashGap() async throws {
        let file = try file(.core)
        issuer.onActivate = { _ in ActivationResponse(licence: file, seats: [], seatLimit: 2) }
        try await svc.activate(key: key, now: now)
        try FileManager.default.removeItem(at: layout.licenceURL)
        await svc.refreshIfDue(now: now)
        XCTAssertTrue(hasLicence)
    }

    func testDeactivateThisMacRemovesFilesButAnotherMacKeepsThem() async throws {
        let file = try file(.household)
        issuer.onActivate = { _ in ActivationResponse(licence: file, seats: [], seatLimit: 6) }
        try await svc.activate(key: key, now: now)
        issuer.onDeactivate = { _, _ in [self.seat(self.settings.deviceId, "This Mac")] }
        let remaining = try await svc.deactivate(deviceId: "other-mac")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(hasLicence && hasActivation)
        XCTAssertEqual(issuer.deactivations.last?.1, "other-mac")

        issuer.onDeactivate = { _, _ in throw ActivationError.offline }
        await XCTAssertThrowsErrorAsync { try await self.svc.deactivate(deviceId: self.settings.deviceId) }
        XCTAssertTrue(hasLicence && hasActivation, "server failure keeps the files")

        issuer.onDeactivate = { _, _ in [] }
        _ = try await svc.deactivate(deviceId: settings.deviceId)
        XCTAssertFalse(hasLicence || hasActivation)
        XCTAssertEqual(svc.currentStatus(now: now), .none)
    }

    func testSeatsReadsTheRosterWithoutReactivating() async throws {
        let file = try file(.household)
        let roster = [seat("a", "Study"), seat("b", "Kitchen")]
        issuer.onActivate = { _ in ActivationResponse(licence: file, seats: [roster[0]], seatLimit: 6) }
        issuer.onSeats = { _, _ in roster }
        try await svc.activate(key: key, now: now)
        let seats = try await svc.seats()
        XCTAssertEqual(seats, roster)
        XCTAssertEqual(issuer.activations.count, 1, "listing the roster must not re-claim a seat")
        XCTAssertEqual(issuer.rosters.count, 1)
        XCTAssertEqual(issuer.rosters.first?.0, key)
        XCTAssertEqual(issuer.rosters.first?.1, settings.deviceId)
        svc.removeLicence()
        await XCTAssertThrowsErrorAsync { try await self.svc.seats() }
    }

    func testRefreshBacksOffForSixHoursWhileTheLicenceIsExpired() async throws {
        let lapsed = try file(.core, expires: now.addingTimeInterval(-86400))
        issuer.onActivate = { _ in ActivationResponse(licence: lapsed, seats: [], seatLimit: 2) }
        try await svc.activate(key: key, now: now.addingTimeInterval(-7 * 3600))
        issuer.activations.removeAll()
        await svc.refreshIfDue(now: now)
        XCTAssertEqual(issuer.activations.count, 1, "an expired licence with a key is due")
        issuer.onActivate = { _ in throw ActivationError.ended(self.now) }
        await svc.refreshIfDue(now: now.addingTimeInterval(3600))
        XCTAssertEqual(issuer.activations.count, 1, "asked an hour ago: not again yet")
        await svc.refreshIfDue(now: now.addingTimeInterval(6 * 3600 + 1))
        XCTAssertEqual(issuer.activations.count, 2, "six hours on: ask again")
        await svc.refreshIfDue(now: now.addingTimeInterval(7 * 3600))
        XCTAssertEqual(issuer.activations.count, 2, "a failed attempt also counts as an attempt")
        XCTAssertEqual(svc.currentStatus(now: now).licence?.licenceId, "L1", "the lapsed file stays")
        XCTAssertEqual(svc.activationKey, key)
    }

    func testSwitchingKeysReleasesTheOldSeatOnlyAfterTheNewKeyActivates() async throws {
        let old = try file(.core, id: "LA")
        let fresh = try file(.household, id: "LB")
        let keyB = LicenceKey(userInput: "OV-DEVH-2345-6789-ABCD")!
        issuer.onActivate = { _ in ActivationResponse(licence: old, seats: [], seatLimit: 2) }
        try await svc.activate(key: key, now: now)

        issuer.onActivate = { _ in throw ActivationError.seatsExhausted([]) }
        await XCTAssertThrowsErrorAsync { try await self.svc.switchActivation(to: keyB, now: self.now) }
        XCTAssertTrue(issuer.deactivations.isEmpty, "a refused activation releases nothing")
        XCTAssertEqual(svc.activationKey, key)
        XCTAssertEqual(svc.currentStatus(now: now).licence?.licenceId, "LA")

        issuer.onActivate = { _ in ActivationResponse(licence: fresh, seats: [], seatLimit: 6) }
        issuer.onDeactivate = { _, _ in throw ActivationError.offline }
        let status = try await svc.switchActivation(to: keyB, now: now)
        XCTAssertEqual(status.licence?.licenceId, "LB")
        XCTAssertEqual(issuer.deactivations.map(\.0), [key], "the old key's seat is released after the new file is in place")
        XCTAssertEqual(issuer.deactivations.first?.1, settings.deviceId)
        XCTAssertEqual(svc.activationKey, keyB, "a failed release does not undo the switch")
        XCTAssertEqual(svc.currentStatus(now: now).licence?.licenceId, "LB")

        issuer.deactivations.removeAll()
        try await svc.switchActivation(to: keyB, now: now)
        XCTAssertTrue(issuer.deactivations.isEmpty, "the same key again is a refresh, not a switch")
    }

    func testLicenceKeyNormalisation() {
        XCTAssertEqual(LicenceKey(userInput: "ov-devc-2345-6789-abcd")?.rawValue, "OV-DEVC-2345-6789-ABCD")
        XCTAssertEqual(LicenceKey(userInput: " DEVC 2345 6789 ABCD ")?.rawValue, "OV-DEVC-2345-6789-ABCD")
        XCTAssertEqual(LicenceKey(userInput: "OVDEVC23456789ABCD")?.rawValue, "OV-DEVC-2345-6789-ABCD")
        XCTAssertEqual(LicenceKey(userInput: "OV-DEVC-2345-6789-ABCD")?.masked, "OV-DEVC-····-····-ABCD")
        XCTAssertNil(LicenceKey(userInput: "OV-CORE-2345-6789-ABCD"), "O is not in the alphabet")
        XCTAssertNil(LicenceKey(userInput: "OV-DEVC-2345-6789-ABC"), "15 symbols")
        XCTAssertNil(LicenceKey(userInput: "OV-K0RE-2345-6789-ABCD"), "0 is not in the alphabet")
        XCTAssertNil(LicenceKey(userInput: ""))
    }

    func testActivationRequestWireShape() throws {
        let req = ActivationRequest(key: key, deviceId: "d", deviceName: nil, appVersion: "1.2")
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try e.encode(req), as: UTF8.self), #"{"appVersion":"1.2","deviceId":"d","key":"OV-DEVC-2345-6789-ABCD"}"#)
        let response = #"{"licence":{"format":"offlinevault-licence/2","keyId":"k","payload":"AA==","signature":"AA=="},"seats":[{"deviceId":"d","deviceName":"Mac","activatedAt":"2026-10-18T12:34:56.789Z","lastSeenAt":"2026-10-18T12:34:56Z"}],"seatLimit":2}"#
        let decoded = try Manifest.decoder().decode(ActivationResponse.self, from: Data(response.utf8))
        XCTAssertEqual(decoded.seatLimit, 2)
        XCTAssertEqual(decoded.seats.first?.deviceName, "Mac")
        XCTAssertEqual(decoded.seats.first?.activatedAt.timeIntervalSince1970 ?? 0, ISO8601DateFormatter().date(from: "2026-10-18T12:34:56Z")!.timeIntervalSince1970 + 0.789, accuracy: 0.001, "JavaScript dates carry milliseconds")
    }
}

private extension LicenceFile {
    var expiry: Date? { try? LicencePayload.decoder.decode(LicencePayload.self, from: payloadData!).expiresAt }
}

func XCTAssertThrowsErrorAsync<T>(file: StaticString = #filePath, line: UInt = #line, _ expression: () async throws -> T) async {
    do { _ = try await expression(); XCTFail("expected an error", file: file, line: line) } catch {}
}
