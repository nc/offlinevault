import XCTest
import CryptoKit
@testable import OfflineVaultCore

final class LicenceTests: XCTestCase {
    let verifier = try! LicenceVerifier(keys: Config.licencePublicKeys)
    let now = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!

    func testV1LicenceStillVerifiesAsOneSeatOfCore() throws {
        let status = verifier.verify(fileData: Fixtures.data("licence_valid.json"), now: now)
        guard case .valid(let l) = status else { return XCTFail("expected valid, got \(status)") }
        XCTAssertEqual(l.subscriber, "Dev Subscriber")
        XCTAssertEqual(l.licenceId, "dev-0001")
        XCTAssertEqual(l.plan, .core)
        XCTAssertEqual(l.seats, 1)
        XCTAssertTrue(status.allowsLibraryUse)
    }

    func testExpiredLicenceStillAllowsLibrary() throws {
        let status = verifier.verify(fileData: Fixtures.data("licence_expired.json"), now: now)
        guard case .expired(let l) = status else { return XCTFail("expected expired, got \(status)") }
        XCTAssertEqual(l.subscriber, "Lapsed Subscriber")
        XCTAssertTrue(status.allowsLibraryUse, "product rule: a lapsed licence never locks the library")
        let past = ISO8601DateFormatter().date(from: "2024-06-01T00:00:00Z")!
        if case .valid = verifier.verify(fileData: Fixtures.data("licence_expired.json"), now: past) {} else { XCTFail("the same file is valid before its expiry") }
    }

    func testTamperedLicenceRejected() throws {
        let status = verifier.verify(fileData: Fixtures.data("licence_tampered.json"), now: now)
        guard case .invalid(let reason) = status else { return XCTFail("expected invalid, got \(status)") }
        XCTAssertTrue(reason.contains("signature"))
        XCTAssertTrue(status.allowsLibraryUse)
    }

    func testWrongKeyAndGarbageRejected() throws {
        let other = LicenceVerifier(publicKeys: ["other": Curve25519.Signing.PrivateKey().publicKey])
        if case .invalid = other.verify(fileData: Fixtures.data("licence_valid.json")) {} else { XCTFail("foreign key must not verify") }
        if case .invalid = verifier.verify(fileData: Data("not json".utf8)) {} else { XCTFail() }
        var file = try JSONDecoder().decode(LicenceFile.self, from: Fixtures.data("licence_valid.json"))
        file.format = "offlinevault-licence/9"
        if case .invalid(let r) = verifier.verify(file) { XCTAssertTrue(r.contains("format")) } else { XCTFail() }
    }

    func testV2FixturesPerPlan() throws {
        func licence(_ name: String) throws -> Licence {
            let status = verifier.verify(fileData: Fixtures.data("licence_v2_\(name).json"), now: now)
            guard case .valid(let l) = status else { throw UserFacingError("expected valid \(name)", message: "\(status)") }
            return l
        }
        let core = try licence("core")
        XCTAssertEqual(core.plan, .core); XCTAssertEqual(core.seats, 2); XCTAssertEqual(core.level(at: now), .core)
        let household = try licence("household")
        XCTAssertEqual(household.plan, .household); XCTAssertEqual(household.seats, 6); XCTAssertEqual(household.level(at: now), .household)
        let drive = try licence("drive")
        XCTAssertEqual(drive.plan, .drive); XCTAssertEqual(drive.seats, 2); XCTAssertEqual(drive.level(at: now), .household)
        XCTAssertEqual(drive.expiresAt, ISO8601DateFormatter().date(from: "2027-10-01T00:00:00Z"))
        let founder = try licence("founder")
        XCTAssertEqual(founder.plan, .founder); XCTAssertEqual(founder.seats, 6); XCTAssertNil(founder.expiresAt)
        let stepDown = ISO8601DateFormatter().date(from: "2029-10-01T00:00:00Z")!
        XCTAssertEqual(founder.level(at: stepDown.addingTimeInterval(-1)), .household)
        XCTAssertEqual(founder.level(at: stepDown), .core)
        XCTAssertFalse(founder.isExpired(at: .distantFuture), "no expiry is never expired")
        if case .expired(let l) = verifier.verify(fileData: Fixtures.data("licence_v2_expired.json"), now: now) { XCTAssertEqual(l.plan, .core) } else { XCTFail("expired v2 file") }
    }

    func testV2UnknownKeyAndUnknownPlanAreInvalidWithAReason() throws {
        if case .invalid(let r) = verifier.verify(fileData: Fixtures.data("licence_v2_unknown_key.json"), now: now) { XCTAssertTrue(r.contains("rotated-2031"), r) } else { XCTFail("unknown key must not verify") }
        if case .invalid(let r) = verifier.verify(fileData: Fixtures.data("licence_v2_unknown_plan.json"), now: now) { XCTAssertTrue(r.contains("platinum") && r.contains("newer"), r) } else { XCTFail("unknown plan must not verify") }
        var noId = try JSONDecoder().decode(LicenceFile.self, from: Fixtures.data("licence_v2_core.json"))
        noId.keyId = nil
        if case .invalid = verifier.verify(noId, now: now) {} else { XCTFail("v2 without keyId must not verify") }
    }

    func testCanonicalPayloadBytes() throws {
        let l = Licence(licenceId: "L/1", subscriber: "ada@example.com", plan: .founder, issuedAt: now, expiresAt: nil, householdUntil: now.addingTimeInterval(86400))
        let bytes = try LicenceFile.canonicalPayload(l)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), #"{"householdUntil":"2026-11-02T00:00:00Z","issuedAt":"2026-11-01T00:00:00Z","licenceId":"L/1","plan":"founder","seats":6,"subscriber":"ada@example.com"}"#,
                       "sorted keys, no whitespace, nulls omitted, no slash escaping: the worker must match this byte for byte")
    }

    func testSignThenVerifyRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let licence = Licence(licenceId: "L1", subscriber: "Ada", plan: .household, issuedAt: now, expiresAt: now.addingTimeInterval(86400))
        let file = try LicenceFile.sign(licence, keyId: "k1", with: key)
        let v = LicenceVerifier(publicKeys: ["k1": key.publicKey])
        XCTAssertEqual(v.verify(file, now: now).licence, licence)
        XCTAssertEqual(file.format, LicenceFile.formatV2)
    }

    func testPlanTableConstants() {
        XCTAssertEqual(Plan.allCases.map(\.defaultSeats), [2, 6, 2, 6])
        XCTAssertEqual(Plan.allCases.map(\.grantsSharing), [false, true, true, true])
        XCTAssertEqual(Grant.forLevel(.free), Grant(tiers: [.free], modelArtefactIds: [], sharing: false))
        XCTAssertEqual(Grant.forLevel(.core).tiers, [.free, .core])
        XCTAssertTrue(ContentTier.free < ContentTier.core, "free ranks below core everywhere: spec.py TIER_RANK, the manifest, this enum")
        XCTAssertEqual(Grant.forLevel(.core).modelArtefactIds, [Config.defaultModelArtefactId])
        XCTAssertEqual(Grant.forLevel(.household).tiers, Set(ContentTier.allCases))
        XCTAssertTrue(Grant.forLevel(.household).modelArtefactIds.isSuperset(of: [Config.largeModelArtefactId, Config.glimmerModelArtefactId, Config.glimmerDrafterArtefactId]))
        XCTAssertTrue(Level.free < Level.core && Level.core < Level.household)
    }

    /// The worker signs `fixtures/payload_core.json` with the dev key and commits the result. The worker owner commits
    /// the file; until then this test skips.
    func testWorkerSignedGoldenFileVerifies() throws {
        guard let url = Bundle.module.url(forResource: "licence_worker_core", withExtension: "json", subdirectory: "Fixtures") else {
            throw XCTSkip("Fixtures/licence_worker_core.json is absent: the worker owner commits it (website/tools/sign_check.sh)")
        }
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(LicenceFile.self, from: data)
        XCTAssertEqual(file.format, LicenceFile.formatV2)
        XCTAssertEqual(file.keyId, "dev-2026")
        let status = verifier.verify(fileData: data, now: now)
        guard case .valid(let l) = status else { return XCTFail("worker-signed file must verify with the dev key, got \(status)") }
        XCTAssertEqual(l.plan, .core)
        XCTAssertEqual(l.seats, 2)
        XCTAssertEqual(try LicenceFile.canonicalPayload(LicencePayload(l)), file.payloadData, "re-encoding the decoded licence reproduces the worker's canonical bytes")
    }
}
