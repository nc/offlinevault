import XCTest
import CryptoKit
@testable import OfflineVaultCore

/// Every row of the `ManifestVerifier` policy table, from the committed fixtures `licencetool fixtures` writes.
final class ManifestVerifierTests: XCTestCase {
    let devKeyring = try! Keyring(keys: ["dev-2026": "ORUshk9UHuNd8mebEbfEGTqbigEVYCaByVR8yyB8/TU="])
    let mirror = URL(string: "http://nas.local:8080/updates/")!
    let v2Published = ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!

    func open(_ fixture: String, from source: UpdateSource, seen: Date? = nil) throws -> FetchedManifest {
        try ManifestVerifier.open(body: Fixtures.data(fixture), from: source, keyring: devKeyring, lastVerifiedPublishedAt: seen)
    }

    func rejection(_ fixture: String, from source: UpdateSource, seen: Date? = nil, file: StaticString = #filePath, line: UInt = #line) -> UserFacingError? {
        do { _ = try open(fixture, from: source, seen: seen); XCTFail("\(fixture) from \(source) must be rejected", file: file, line: line); return nil }
        catch let e as UserFacingError { return e }
        catch { XCTFail("expected a UserFacingError, got \(error)", file: file, line: line); return nil }
    }

    // MARK: Official service

    func testOfficialSignedWithTrustedKeyIsVerifiedWithoutMirror() throws {
        let fetched = try open("manifest_v2_signed.json", from: .offlineVault)
        XCTAssertEqual(fetched.trust, .verified(keyId: "dev-2026", publishedAt: v2Published, mirror: nil))
        XCTAssertEqual(fetched.manifest, try Manifest.parse(Fixtures.data("manifest_v2.json")), "the opened bytes are the publisher's file, parsed as before")
    }

    func testOfficialSignedWithUntrustedKeyNamesTheKeyAndAsksForAnUpdate() {
        let e = rejection("manifest_v2_untrusted_key.json", from: .offlineVault)
        XCTAssertEqual(e?.title, "Catalogue not trusted")
        XCTAssertTrue(e?.message.contains("rotated-2031") == true, e?.message ?? "")
        XCTAssertTrue(e?.recovery?.contains("Update OfflineVault") == true, e?.recovery ?? "")
    }

    func testOfficialBadSignatureOrBase64IsRejected() {
        for fixture in ["manifest_v2_wrong_key.json", "manifest_v2_tampered.json", "manifest_v2_bad_base64.json"] {
            let e = rejection(fixture, from: .offlineVault)
            XCTAssertEqual(e?.title, "Catalogue not trusted", fixture)
            XCTAssertFalse(e?.message.contains("does not trust") == true, "\(fixture): a forged keyId is a signature failure, not a key failure")
        }
    }

    func testOfficialPlainManifestIsRefused() {
        XCTAssertEqual(rejection("manifest_v2.json", from: .offlineVault)?.title, "Unsigned catalogue from the OfflineVault service")
    }

    // MARK: Self-hosted

    func testSelfHostedSignedWithTrustedKeyIsVerifiedViaMirror() throws {
        let fetched = try open("manifest_v2_signed.json", from: .selfHosted(mirror))
        XCTAssertEqual(fetched.trust, .verified(keyId: "dev-2026", publishedAt: v2Published, mirror: mirror))
    }

    func testSelfHostedInvalidEnvelopeIsNeverDowngradedToUnverified() {
        for fixture in ["manifest_v2_tampered.json", "manifest_v2_untrusted_key.json", "manifest_v2_wrong_key.json", "manifest_v2_bad_base64.json"] {
            XCTAssertEqual(rejection(fixture, from: .selfHosted(mirror))?.title, "Catalogue not trusted", fixture)
        }
    }

    func testSelfHostedPlainManifestIsUnverifiedWithTheHost() throws {
        let fetched = try open("manifest_v2.json", from: .selfHosted(mirror))
        XCTAssertEqual(fetched.trust, .unverified(host: "nas.local:8080"))
        XCTAssertEqual(fetched.manifest.version, "2026.10.08")
    }

    // MARK: Edges

    func testSignedLookingButMalformedBodyIsRejectedEverywhere() {
        let broken = Data(#"{"format":"offlinevault-manifest/1","payload":"AA=="}"#.utf8)
        for source in [UpdateSource.offlineVault, .selfHosted(mirror)] {
            XCTAssertThrowsError(try ManifestVerifier.open(body: broken, from: source, keyring: devKeyring)) {
                XCTAssertEqual(($0 as? UserFacingError)?.title, "Catalogue not trusted")
            }
        }
    }

    func testGarbageFromAMirrorIsAnInvalidManifestNotATrustFailure() {
        XCTAssertThrowsError(try ManifestVerifier.open(body: Data("<html>".utf8), from: .selfHosted(mirror), keyring: devKeyring)) {
            XCTAssertEqual(($0 as? UserFacingError)?.title, "Invalid manifest")
        }
    }

    func testReplayGuardRejectsAVerifiedManifestOlderThanTheLastSeen() throws {
        let v1Published = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
        XCTAssertEqual(rejection("manifest_v1_signed.json", from: .offlineVault, seen: v2Published)?.title, "Catalogue is older than the one already seen")
        XCTAssertNoThrow(try open("manifest_v2_signed.json", from: .offlineVault, seen: v2Published), "the same edition again is fine")
        XCTAssertNoThrow(try open("manifest_v2_signed.json", from: .offlineVault, seen: v1Published), "newer is fine")
        XCTAssertNoThrow(try open("manifest_v1_signed.json", from: .selfHosted(mirror), seen: nil), "nothing seen yet")
        XCTAssertNoThrow(try open("manifest_v2.json", from: .selfHosted(mirror), seen: v2Published), "plain manifests carry no date the guard trusts")
    }

    func testTrustCopy() {
        let verified = CatalogueTrust.verified(keyId: "content-2026-10", publishedAt: v2Published, mirror: nil)
        XCTAssertEqual(verified.title, "Verified OfflineVault catalogue")
        XCTAssertEqual(verified.detail(release: "2026.10.08"), "Published 8 Oct 2026 · release 2026.10.08")
        XCTAssertEqual(verified.symbolName, "checkmark.seal.fill")
        XCTAssertTrue(verified.isVerified)
        let mirrored = CatalogueTrust.verified(keyId: "content-2026-10", publishedAt: v2Published, mirror: mirror)
        XCTAssertEqual(mirrored.detail(release: "2026.10.08"), "Published 8 Oct 2026 · release 2026.10.08 · via nas.local:8080")
        let unverified = CatalogueTrust.unverified(host: "nas.local:8080")
        XCTAssertEqual(unverified.title, "Unverified source")
        XCTAssertEqual(unverified.detail(release: "2026.10.08"), "nas.local:8080 · release 2026.10.08")
        XCTAssertEqual(unverified.symbolName, "exclamationmark.shield")
        XCTAssertFalse(unverified.isVerified)
    }

    // MARK: External artefacts

    func testSignatureCoversTheExternalURL() throws {
        let key = Curve25519.Signing.PrivateKey()
        let ring = Keyring(publicKeys: ["t": key.publicKey])
        let sha = String(repeating: "d", count: 64)
        let payload = """
        {"version":"2026.11.01","publishedAt":"2026-11-01T00:00:00Z","catalogueVersion":"3","artefacts":[
          {"id":"zim-ifixit-2025-12","kind":"zim","path":"zim/ifixit_en_all_2025-12.zim","sizeBytes":10,"sha256":"\(sha)","minAppVersion":"1.0.0","tier":"free",
           "external":{"url":"https://download.kiwix.org/zim/ifixit/ifixit_en_all_2025-12.zim","shaSource":"kiwix-meta4"}}]}
        """
        let envelope = try SignedEnvelope.sign(Data(payload.utf8), format: ManifestEnvelope.format, keyId: "t", with: key)
        let fetched = try ManifestVerifier.open(body: JSONEncoder().encode(envelope), from: .offlineVault, keyring: ring)
        XCTAssertTrue(fetched.trust.isVerified, "the catalogue is verified; the external book inside it is not, and says so")
        XCTAssertEqual(fetched.manifest.artefacts.first?.external?.host, "download.kiwix.org")

        // Swapping the URL inside the signed payload is a signature failure, like any other edit.
        var forged = envelope
        forged.payload = Data(payload.replacingOccurrences(of: "download.kiwix.org", with: "evil.example").utf8).base64EncodedString()
        XCTAssertThrowsError(try ManifestVerifier.open(body: JSONEncoder().encode(forged), from: .offlineVault, keyring: ring)) {
            XCTAssertEqual(($0 as? UserFacingError)?.title, "Catalogue not trusted")
        }
    }

    // MARK: Keys

    func testCatalogueAndLicenceKeysAreSeparateTables() {
        let licence = Config.productionLicencePublicKeys, catalogue = Config.productionCataloguePublicKeys
        XCTAssertEqual(catalogue, ["content-2026-10": "1O0FL/5hswGi0rSwLEeeyLagHiQRrYDsygaY4yW6QF4="])
        XCTAssertTrue(Set(licence.keys).isDisjoint(with: catalogue.keys), "a key id never appears in both production tables")
        XCTAssertTrue(Set(licence.values).isDisjoint(with: catalogue.values), "nor does a key")
        XCTAssertEqual(Set(Config.licencePublicKeys.keys).intersection(Config.cataloguePublicKeys.keys).subtracting([Config.developmentKeyId]), [],
                       "only the committed dev key may sign both, and only in a DEBUG build")
        XCTAssertNoThrow(try Keyring(keys: Config.cataloguePublicKeys))
        XCTAssertEqual(Set(UpdateService.catalogueKeyring.keys.keys), Set(Config.cataloguePublicKeys.keys))
    }
}
