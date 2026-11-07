import XCTest
import CryptoKit
@testable import OfflineVaultCore

final class SigningTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()
    let payload = Data(#"{"hello":"world"}"#.utf8)
    var keyring: Keyring { Keyring(publicKeys: ["k1": key.publicKey]) }

    func testSignThenOpenReturnsTheExactBytesAndTheKeyId() throws {
        let env = try SignedEnvelope.sign(payload, format: "test/1", keyId: "k1", with: key)
        let opened = try keyring.open(env, format: "test/1")
        XCTAssertEqual(opened.payload, payload)
        XCTAssertEqual(opened.keyId, "k1")
    }

    func testOpenNamesEachFailure() throws {
        let env = try SignedEnvelope.sign(payload, format: "test/1", keyId: "k1", with: key)
        func failure(_ e: SignedEnvelope, format: String = "test/1", _ ring: Keyring? = nil) -> SignatureFailure? {
            do { _ = try (ring ?? keyring).open(e, format: format); return nil } catch { return error as? SignatureFailure }
        }
        XCTAssertEqual(failure(env, format: "other/1"), .wrongFormat(found: "test/1", expected: "other/1"))
        var noId = env; noId.keyId = nil
        XCTAssertEqual(failure(noId), .noKeyId)
        var unknown = env; unknown.keyId = "k9"
        XCTAssertEqual(failure(unknown), .untrustedKey("k9"))
        var garbage = env; garbage.signature = "%%%"
        XCTAssertEqual(failure(garbage), .badBase64)
        var tampered = env; tampered.payload = Data(#"{"hello":"mallory"}"#.utf8).base64EncodedString()
        XCTAssertEqual(failure(tampered), .badSignature)
        XCTAssertEqual(failure(env, Keyring(publicKeys: ["k1": Curve25519.Signing.PrivateKey().publicKey])), .badSignature, "a forged keyId still needs a signature from the trusted key")
    }

    func testAnyKeyOpenIsForDocumentsWithoutAKeyId() throws {
        let env = try SignedEnvelope.sign(payload, format: "v1", keyId: nil, with: key)
        let ring = Keyring(publicKeys: ["other": Curve25519.Signing.PrivateKey().publicKey, "ours": key.publicKey])
        XCTAssertEqual(try ring.openWithAnyKey(env, format: "v1"), payload)
        XCTAssertThrowsError(try ring.open(env, format: "v1")) { XCTAssertEqual($0 as? SignatureFailure, .noKeyId) }
        XCTAssertThrowsError(try Keyring(publicKeys: ["other": Curve25519.Signing.PrivateKey().publicKey]).openWithAnyKey(env, format: "v1")) { XCTAssertEqual($0 as? SignatureFailure, .badSignature) }
    }

    func testDetectSeparatesEnvelopesFromPlainDocumentsAndRejectsBrokenEnvelopes() throws {
        let env = try SignedEnvelope.sign(payload, format: "test/1", keyId: "k1", with: key)
        let encoded = try JSONEncoder().encode(env)
        XCTAssertEqual(try SignedEnvelope.detect(encoded), .envelope(env))
        XCTAssertEqual(try SignedEnvelope.detect(payload), .plain(payload))
        XCTAssertEqual(try SignedEnvelope.detect(Data("not json".utf8)), .plain(Data("not json".utf8)), "non-JSON is handed on; the document parser names the problem")
        let broken = Data(#"{"format":"test/1","payload":"AA=="}"#.utf8)
        XCTAssertThrowsError(try SignedEnvelope.detect(broken)) { XCTAssertEqual($0 as? SignatureFailure, .malformedEnvelope) }
    }

    func testKeyringRejectsMalformedBundledKeys() {
        XCTAssertThrowsError(try Keyring(keys: ["bad": "AAAA"]))
        XCTAssertNoThrow(try Keyring(keys: Config.licencePublicKeys))
    }

    func testLicenceVerifierRidesOnTheKeyring() throws {
        let licence = Licence(licenceId: "L1", subscriber: "Ada", plan: .core, issuedAt: Date(timeIntervalSince1970: 1_800_000_000), expiresAt: nil)
        let file = try LicenceFile.sign(licence, keyId: "k1", with: key)
        XCTAssertEqual(LicenceVerifier(keyring: keyring).verify(file).licence, licence)
        XCTAssertEqual(file.format, "offlinevault-licence/2")
    }
}
