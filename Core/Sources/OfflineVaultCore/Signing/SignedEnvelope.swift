import Foundation
import CryptoKit

/// The one signed-document wire shape: licences (`offlinevault-licence/1|2`) and catalogues (`offlinevault-manifest/1`).
/// `keyId` sits outside the signed bytes on purpose: it only selects which trusted key to try, and a forged keyId
/// still has to produce a signature from a trusted key. v1 licences have no keyId.
public struct SignedEnvelope: Codable, Equatable, Sendable {
    public var format: String
    public var keyId: String?
    /// base64 of the exact bytes that were signed. Verifiers never re-encode; they check these bytes, then parse them.
    public var payload: String
    /// base64 of the raw 64-byte Ed25519 signature.
    public var signature: String

    public init(format: String, keyId: String?, payload: String, signature: String) {
        self.format = format; self.keyId = keyId; self.payload = payload; self.signature = signature
    }

    public var payloadData: Data? { Data(base64Encoded: payload) }
    public var signatureData: Data? { Data(base64Encoded: signature) }

    /// Signs `payload` byte for byte.
    public static func sign(_ payload: Data, format: String, keyId: String?, with privateKey: Curve25519.Signing.PrivateKey) throws -> SignedEnvelope {
        let sig = try privateKey.signature(for: payload)
        return SignedEnvelope(format: format, keyId: keyId, payload: payload.base64EncodedString(), signature: sig.base64EncodedString())
    }

    /// What a body fetched from a server turned out to be.
    public enum Detected: Equatable, Sendable {
        case envelope(SignedEnvelope)
        case plain(Data)
    }

    /// A JSON object carrying `format` or `signature` is an envelope and must decode as one, so a signed-looking file
    /// with a broken shape is never mistaken for a plain document. Anything else is handed on as plain bytes.
    public static func detect(_ data: Data) throws -> Detected {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["signature"] != nil || object["format"] != nil else { return .plain(data) }
        guard let envelope = try? JSONDecoder().decode(SignedEnvelope.self, from: data) else { throw SignatureFailure.malformedEnvelope }
        return .envelope(envelope)
    }
}

public enum SignatureFailure: Error, Equatable, Sendable {
    case wrongFormat(found: String, expected: String)
    case malformedEnvelope
    case badBase64
    case noKeyId
    case untrustedKey(String)
    case badSignature

    /// One clause shared by the licence and catalogue surfaces, so both name the same cause.
    public var reason: String {
        switch self {
        case .wrongFormat(let found, _): return "unsupported format '\(found)'"
        case .malformedEnvelope: return "the signed envelope is malformed"
        case .badBase64: return "payload or signature is not valid base64"
        case .noKeyId: return "no key id"
        case .untrustedKey(let id): return "signed with key '\(id)', which this build does not trust"
        case .badSignature: return "signature does not match: the file was altered or signed with a different key"
        }
    }
}

/// Trusted Ed25519 public keys by key id. The only place in Core that calls `isValidSignature`.
public struct Keyring: Sendable {
    public let keys: [String: Curve25519.Signing.PublicKey]

    public init(publicKeys: [String: Curve25519.Signing.PublicKey]) { keys = publicKeys }

    /// `keys`: keyId → raw 32-byte Ed25519 public key, base64 (the shape of the `Config` tables).
    public init(keys: [String: String]) throws {
        var parsed: [String: Curve25519.Signing.PublicKey] = [:]
        for (id, b64) in keys {
            guard let raw = Data(base64Encoded: b64), raw.count == 32 else {
                throw UserFacingError("Bad public key", message: "The bundled public key '\(id)' is not a 32-byte Ed25519 key.")
            }
            parsed[id] = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        }
        self.keys = parsed
    }

    /// Returns the signed bytes and the key that signed them. A returned payload was signed under `format` by a key
    /// in `keys`; every other outcome is a `SignatureFailure`.
    public func open(_ envelope: SignedEnvelope, format: String) throws -> (payload: Data, keyId: String) {
        guard envelope.format == format else { throw SignatureFailure.wrongFormat(found: envelope.format, expected: format) }
        guard let keyId = envelope.keyId else { throw SignatureFailure.noKeyId }
        guard let key = keys[keyId] else { throw SignatureFailure.untrustedKey(keyId) }
        guard let payload = envelope.payloadData, let signature = envelope.signatureData else { throw SignatureFailure.badBase64 }
        guard key.isValidSignature(signature, for: payload) else { throw SignatureFailure.badSignature }
        return (payload, keyId)
    }

    /// For documents that predate key ids (v1 licences): every key is tried.
    func openWithAnyKey(_ envelope: SignedEnvelope, format: String) throws -> Data {
        guard envelope.format == format else { throw SignatureFailure.wrongFormat(found: envelope.format, expected: format) }
        guard let payload = envelope.payloadData, let signature = envelope.signatureData else { throw SignatureFailure.badBase64 }
        guard keys.values.contains(where: { $0.isValidSignature(signature, for: payload) }) else { throw SignatureFailure.badSignature }
        return payload
    }
}
