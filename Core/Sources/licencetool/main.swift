import Foundation
import CryptoKit
import OfflineVaultCore

// licencetool: Ed25519 keypairs, v2 licence files, keyring verification, canonical bytes and fixture regeneration.
//
//   swift run licencetool keygen --out DIR
//       writes DIR/licence-private.key and DIR/licence-public.key (base64 raw 32 bytes)
//   swift run licencetool sign --key FILE --key-id ID --subscriber NAME --plan core|household|drive|founder
//                              [--seats N] [--days N | --expires ISO | --never] [--household-until ISO]
//                              [--id ID] [--issued ISO] --out FILE
//       founder defaults to --never with --household-until = issued + 1096 days; other plans default to --days 365
//   swift run licencetool verify --pubkey ID=FILE [--pubkey ID=FILE ...] LICENCE
//       exit 1 when invalid; v1 files are tried against every key
//   swift run licencetool canon PAYLOAD.json
//       prints the canonical payload bytes for a payload JSON (the cross-language proof: diff against the worker)
//   swift run licencetool sign-envelope --format FORMAT --key FILE --key-id ID --payload FILE --out FILE
//       wraps any file byte for byte in a signed envelope (the fixture server's manifests use offlinevault-manifest/1)
//   swift run licencetool fixtures --out REPO_ROOT [--key FILE] [--key-id ID]
//       regenerates every test fixture and fixture/dev-licence-*.json from the table at the bottom of this file

func usage() -> Never {
    FileHandle.standardError.write("usage: licencetool keygen --out DIR | sign --key FILE --key-id ID --subscriber NAME --plan P [--seats N] [--days N|--expires ISO|--never] [--household-until ISO] [--id ID] [--issued ISO] --out FILE | verify --pubkey ID=FILE... LICENCE | canon PAYLOAD.json | sign-envelope --format FORMAT --key FILE --key-id ID --payload FILE --out FILE | fixtures --out REPO_ROOT [--key FILE] [--key-id ID]\n".data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("licencetool: \(message)\n".data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i); return true
}

let iso = ISO8601DateFormatter()
func date(_ s: String, _ what: String) -> Date {
    guard let d = iso.date(from: s) else { fail("bad \(what): \(s)") }
    return d
}
func number<T: LosslessStringConvertible>(_ s: String, _ what: String) -> T {
    guard let n = T(s) else { fail("bad \(what): \(s)") }
    return n
}

func privateKey(at path: String) throws -> Curve25519.Signing.PrivateKey {
    let raw = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: raw) else { fail("\(path) is not a base64 key") }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
}

let fileEncoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e }()

func write(_ file: LicenceFile, to path: String) throws {
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileEncoder.encode(file).write(to: URL(fileURLWithPath: path))
}

switch command {
case "keygen":
    guard let out = option("--out") else { usage() }
    let dir = URL(fileURLWithPath: out)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.base64EncodedString().write(to: dir.appendingPathComponent("licence-private.key"), atomically: true, encoding: .utf8)
    try key.publicKey.rawRepresentation.base64EncodedString().write(to: dir.appendingPathComponent("licence-public.key"), atomically: true, encoding: .utf8)
    print("public key (add to Config.licencePublicKeys under a new key id):")
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard let keyPath = option("--key"), let keyId = option("--key-id"), let subscriber = option("--subscriber"), let planName = option("--plan"), let out = option("--out") else { usage() }
    guard let plan = Plan(rawValue: planName) else { fail("unknown plan '\(planName)'; one of \(Plan.allCases.map(\.rawValue).joined(separator: ", "))") }
    let key = try privateKey(at: keyPath)
    let issued = option("--issued").map { date($0, "--issued") } ?? Date()
    let never = flag("--never")
    let expires: Date?
    if never { expires = nil }
    else if let e = option("--expires") { expires = date(e, "--expires") }
    else if let d = option("--days") { expires = issued.addingTimeInterval(number(d, "--days") * 86400) }
    else { expires = plan == .founder ? nil : issued.addingTimeInterval(365 * 86400) }
    var householdUntil = option("--household-until").map { date($0, "--household-until") }
    if plan == .founder, householdUntil == nil { householdUntil = issued.addingTimeInterval(1096 * 86400) }
    let seats: Int? = option("--seats").map { number($0, "--seats") }
    let licence = Licence(licenceId: option("--id") ?? UUID().uuidString, subscriber: subscriber, plan: plan, seats: seats, issuedAt: issued, expiresAt: expires, householdUntil: householdUntil)
    try write(try LicenceFile.sign(licence, keyId: keyId, with: key), to: out)
    print("wrote \(out): \(plan.title), \(licence.seats) seats, \(expires.map { "expires " + iso.string(from: $0) } ?? "never expires")")

case "verify":
    var keys: [String: String] = [:]
    while let spec = option("--pubkey") {
        let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
        let (id, path) = parts.count == 2 ? (parts[0], parts[1]) : ("legacy", parts[0])
        keys[id] = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !keys.isEmpty, let path = args.first else { usage() }
    let status = try LicenceVerifier(keys: keys).verify(fileData: try Data(contentsOf: URL(fileURLWithPath: path)))
    print(status.summary)
    if case .invalid = status { exit(1) }

case "canon":
    guard let path = args.first else { usage() }
    let payload = try LicencePayload.decoder.decode(LicencePayload.self, from: try Data(contentsOf: URL(fileURLWithPath: path)))
    FileHandle.standardOutput.write(try LicenceFile.canonicalPayload(payload))

case "sign-envelope":
    guard let format = option("--format"), let keyPath = option("--key"), let keyId = option("--key-id"), let payloadPath = option("--payload"), let out = option("--out") else { usage() }
    let payload = try Data(contentsOf: URL(fileURLWithPath: payloadPath))
    try write(try SignedEnvelope.sign(payload, format: format, keyId: keyId, with: try privateKey(at: keyPath)), to: out)
    print("wrote \(out): \(format) signed with \(keyId) over \(payload.count) payload bytes")

case "fixtures":
    guard let root = option("--out") else { usage() }
    let keyId = option("--key-id") ?? "dev-2026"
    let key = try privateKey(at: option("--key") ?? "\(root)/scripts/dev-keys/licence-private.key")
    let tests = "\(root)/Core/Tests/OfflineVaultCoreTests/Fixtures"
    let dev = "\(root)/fixture"
    func d(_ s: String) -> Date { date(s + "T00:00:00Z", "date") }
    let far = d("2099-01-01")

    // v1 back-compat fixtures. `licence_tampered` reuses `licence_valid`'s signature over a changed payload.
    let valid = try LicenceFile.signV1(LicencePayloadV1(licenceId: "dev-0001", subscriber: "Dev Subscriber", issuedAt: d("2026-01-01"), expiresAt: far), with: key)
    try write(valid, to: "\(tests)/licence_valid.json")
    try write(try LicenceFile.signV1(LicencePayloadV1(licenceId: "dev-0002", subscriber: "Lapsed Subscriber", issuedAt: d("2024-01-01"), expiresAt: d("2025-01-01")), with: key), to: "\(tests)/licence_expired.json")
    var tampered = try LicenceFile.signV1(LicencePayloadV1(licenceId: "dev-0001", subscriber: "Mallory", issuedAt: d("2026-01-01"), expiresAt: d("2199-01-01")), with: key)
    tampered.signature = valid.signature
    try write(tampered, to: "\(tests)/licence_tampered.json")

    // v2 fixtures, one per plan plus the failure modes the verifier must name.
    let issued = d("2026-10-01")
    let table: [(name: String, licence: Licence)] = [
        ("core", Licence(licenceId: "dev-core-0001", subscriber: "Core Subscriber", plan: .core, issuedAt: issued, expiresAt: far)),
        ("household", Licence(licenceId: "dev-household-0001", subscriber: "Household Subscriber", plan: .household, issuedAt: issued, expiresAt: far)),
        ("drive", Licence(licenceId: "dev-drive-0001", subscriber: "Drive Owner", plan: .drive, issuedAt: issued, expiresAt: d("2027-10-01"))),
        ("founder", Licence(licenceId: "dev-founder-0001", subscriber: "Founding Member", plan: .founder, issuedAt: issued, expiresAt: nil, householdUntil: d("2029-10-01"))),
        ("expired", Licence(licenceId: "dev-expired-0001", subscriber: "Lapsed Subscriber", plan: .core, issuedAt: d("2025-01-01"), expiresAt: d("2026-01-08"))),
    ]
    for row in table {
        try write(try LicenceFile.sign(row.licence, keyId: keyId, with: key), to: "\(tests)/licence_v2_\(row.name).json")
    }
    try write(try LicenceFile.sign(table[0].licence, keyId: "rotated-2031", with: key), to: "\(tests)/licence_v2_unknown_key.json")
    try write(try LicenceFile.sign(payload: LicencePayload(licenceId: "dev-platinum-0001", subscriber: "Future Subscriber", plan: "platinum", seats: 9, issuedAt: issued, expiresAt: far), keyId: keyId, with: key), to: "\(tests)/licence_v2_unknown_plan.json")

    // Files the fixture server hands out for OV-DEVC/DEVH/DEVD/DEVF/DEVX keys. Valid ones never expire on a dev Mac.
    for row in table {
        var l = row.licence
        if row.name != "expired" && row.name != "founder" { l.expiresAt = far }
        try write(try LicenceFile.sign(l, keyId: keyId, with: key), to: "\(dev)/dev-licence-\(row.name).json")
    }
    // Catalogue policy-table fixtures over the committed plain manifests. The payload is the file byte for byte.
    let v1 = try Data(contentsOf: URL(fileURLWithPath: "\(tests)/manifest_v1.json"))
    let v2 = try Data(contentsOf: URL(fileURLWithPath: "\(tests)/manifest_v2.json"))
    let manifestFormat = ManifestEnvelope.format
    try write(try SignedEnvelope.sign(v1, format: manifestFormat, keyId: keyId, with: key), to: "\(tests)/manifest_v1_signed.json")
    let signedV2 = try SignedEnvelope.sign(v2, format: manifestFormat, keyId: keyId, with: key)
    try write(signedV2, to: "\(tests)/manifest_v2_signed.json")
    try write(try SignedEnvelope.sign(v2, format: manifestFormat, keyId: "rotated-2031", with: key), to: "\(tests)/manifest_v2_untrusted_key.json")
    try write(try SignedEnvelope.sign(v2, format: manifestFormat, keyId: keyId, with: Curve25519.Signing.PrivateKey()), to: "\(tests)/manifest_v2_wrong_key.json")
    var tamperedManifest = signedV2
    tamperedManifest.payload = Data(String(decoding: v2, as: UTF8.self).replacingOccurrences(of: "\"sizeBytes\": 600", with: "\"sizeBytes\": 601").utf8).base64EncodedString()
    try write(tamperedManifest, to: "\(tests)/manifest_v2_tampered.json")
    var badBase64 = signedV2
    badBase64.signature = "not base64!"
    try write(badBase64, to: "\(tests)/manifest_v2_bad_base64.json")
    print("wrote fixtures under \(tests) and \(dev)")

default:
    usage()
}
