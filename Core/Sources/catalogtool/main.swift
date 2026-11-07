import Foundation
import OfflineVaultCore

// catalogtool: the operator's view of a published catalogue, through the app's own Keyring, ManifestVerifier and
// Manifest.parse. The publisher runs it on the signed file before uploading and against the origin afterwards.
//
//   swift run catalogtool verify --file manifest.signed.json [--pubkey ID=FILE]... [--expect manifest.json]
//   swift run catalogtool verify --base https://offlinevault.dev/updates/ [--range-probe] [--expect F]
//
// A file is held to the official-service rule: it must be a signed envelope under a trusted key. A base URL is
// classified like the app does (official host or self-hosted), and the run passes only when the catalogue is
// verified. With --base every artefact is HEADed: Content-Length must equal sizeBytes and X-OfflineVault-SHA256,
// when the origin sends it, must equal sha256. --range-probe also fetches the first and last MiB of each artefact
// and expects 206 with the right byte counts. --pubkey adds or overrides a trusted key (the dev key for fixtures).
// Exit 1 on the first mismatch, naming the artefact; exit 2 on usage errors.

func usage() -> Never {
    FileHandle.standardError.write("usage: catalogtool verify (--file FILE | --base URL) [--expect FILE] [--range-probe] [--pubkey ID=FILE]...\n".data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write("catalogtool: \(message)\n".data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.first == "verify" else { usage() }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i); return true
}

var keys = Config.cataloguePublicKeys
while let spec = option("--pubkey") {
    let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { fail("--pubkey wants ID=FILE, got '\(spec)'") }
    keys[parts[0]] = try String(contentsOfFile: parts[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}
let keyring = try Keyring(keys: keys)
let rangeProbe = flag("--range-probe")
let expectPath = option("--expect")
let filePath = option("--file")
let basePath = option("--base")
guard args.isEmpty, (filePath == nil) != (basePath == nil) else { usage() }

let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.timeoutIntervalForRequest = 60
    return URLSession(configuration: c)
}()

func request(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
    var r = URLRequest(url: url)
    r.httpMethod = method
    if let range { r.setValue(range, forHTTPHeaderField: "Range") }
    let (data, response) = try await session.data(for: r)
    guard let http = response as? HTTPURLResponse else { fail("\(url): not an HTTP response") }
    return (data, http)
}

// 1. The manifest, from the file or the origin.
let body: Data
let source: UpdateSource
let baseURL: URL?
if let filePath {
    body = try Data(contentsOf: URL(fileURLWithPath: filePath))
    source = .offlineVault
    baseURL = nil
} else {
    var s = basePath!
    if !s.hasSuffix("/") { s += "/" }
    guard let base = URL(string: s) else { fail("bad base URL '\(basePath!)'") }
    let (data, http) = try await request(base.appendingPathComponent(Config.manifestFileName))
    guard http.statusCode == 200 else { fail("manifest.json: HTTP \(http.statusCode)") }
    body = data
    source = UpdateSource(baseURL: base)
    baseURL = base
}

let fetched: FetchedManifest
do {
    fetched = try ManifestVerifier.open(body: body, from: source, keyring: keyring)
} catch let e as UserFacingError {
    fail("\(e.title): \(e.message)")
}
let manifest = fetched.manifest
print("\(fetched.trust.title) · \(fetched.trust.detail(release: manifest.version))")
if case .verified(let keyId, _, _) = fetched.trust { print("key \(keyId) · \(manifest.artefacts.count) artefacts · catalogue \(manifest.catalogueVersion)") }
guard fetched.trust.isVerified else { fail("the catalogue is not verified; verify passes only for a signed catalogue under a trusted key") }

// 2. Optional: the manifest the publisher meant to publish.
if let expectPath {
    let expectedBody = try Data(contentsOf: URL(fileURLWithPath: expectPath))
    let expectedBytes: Data
    switch try SignedEnvelope.detect(expectedBody) {
    case .envelope(let e): guard let p = e.payloadData else { fail("--expect: payload is not base64") }; expectedBytes = p
    case .plain(let p): expectedBytes = p
    }
    let expected = try Manifest.parse(expectedBytes)
    guard expected == manifest else { fail("the live manifest differs from \(expectPath) (version \(manifest.version) vs \(expected.version), \(manifest.artefacts.count) vs \(expected.artefacts.count) artefacts)") }
    print("matches \(expectPath)")
}

// 3. Every artefact through the origin.
if let baseURL {
    let mib: Int64 = 1 << 20
    var failures = 0
    for a in manifest.artefacts {
        let url = a.url(relativeTo: baseURL)
        var notes: [String] = []
        let (_, head) = try await request(url, method: "HEAD")
        if head.statusCode != 200 { notes.append("HEAD \(head.statusCode)") }
        let length = head.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
        if length != a.sizeBytes { notes.append("Content-Length \(length.map(String.init) ?? "missing") ≠ sizeBytes \(a.sizeBytes)") }
        if let sha = head.value(forHTTPHeaderField: "X-OfflineVault-SHA256") {
            if sha.lowercased() != a.sha256.lowercased() { notes.append("X-OfflineVault-SHA256 \(sha) ≠ \(a.sha256)") }
        } else {
            notes.append("no X-OfflineVault-SHA256 header")
        }
        if rangeProbe, a.sizeBytes > 0 {
            let headLen = min(mib, a.sizeBytes)
            let (first, r1) = try await request(url, range: "bytes=0-\(headLen - 1)")
            if r1.statusCode != 206 || Int64(first.count) != headLen { notes.append("first MiB: HTTP \(r1.statusCode), \(first.count) bytes") }
            let tailStart = max(0, a.sizeBytes - mib)
            let (last, r2) = try await request(url, range: "bytes=\(tailStart)-")
            if r2.statusCode != 206 || Int64(last.count) != a.sizeBytes - tailStart { notes.append("last MiB: HTTP \(r2.statusCode), \(last.count) bytes") }
        }
        let mismatches = notes.filter { !$0.hasPrefix("no X-OfflineVault-SHA256") }
        if !mismatches.isEmpty { failures += 1 }
        print("\(mismatches.isEmpty ? "ok  " : "FAIL") \(a.id) \(ByteFormat.string(a.sizeBytes))\(notes.isEmpty ? "" : " · " + notes.joined(separator: "; "))")
    }
    if failures > 0 { fail("\(failures) artefact(s) do not match the manifest") }
}
