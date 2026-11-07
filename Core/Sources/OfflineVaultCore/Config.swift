import Foundation

/// Central configuration. Values that operators are expected to change live here.
public enum Config {
    /// Base URL of the update service (Cloudflare R2 behind a custom domain, treated as a static HTTPS host).
    /// `manifest.json` lives at this URL; artefacts live at `<base>/<artefact.path>`.
    ///
    /// To point a build at your own service either:
    ///   1. change this constant, or
    ///   2. set the `OFFLINEVAULT_UPDATES_URL` environment variable, or
    ///   3. set the `updatesBaseURL` user default (editable in Settings › Updates in DEBUG builds), or
    ///   4. launch with `--use-fixture-server` to use the local fixture server (see scripts/make_fixture_server.sh).
    public static let UPDATES_BASE_URL = URL(string: "https://offlinevault.dev/updates/")!

    /// Where `scripts/make_fixture_server.sh` serves the development fixture.
    public static let fixtureServerURL = URL(string: "http://127.0.0.1:8787/")!

    public static let manifestFileName = "manifest.json"

    /// Localhost ports used by managed helper processes.
    public static let kiwixPort = 8765
    public static let llamaPort = 8766

    /// Trusted licence signing keys by key id (raw 32-byte Ed25519 public keys, base64). The production private
    /// key exists only as a Worker secret.
    public static var licencePublicKeys: [String: String] { withDevelopmentKey(productionLicencePublicKeys) }

    /// Trusted catalogue signing keys. A separate table from the licence keys, so the content key can never mint a
    /// licence and the licence key never vouches for a catalogue; a test keeps the two production tables disjoint.
    public static var cataloguePublicKeys: [String: String] { withDevelopmentKey(productionCataloguePublicKeys) }

    public static let productionLicencePublicKeys = ["prod-2026-10": "8h7YxMEMfZYxgvZC3XxVxeiJdEW8/ogs00YTCxzk3iQ="]
    public static let productionCataloguePublicKeys = ["content-2026-10": "1O0FL/5hswGi0rSwLEeeyLagHiQRrYDsygaY4yW6QF4="]

    /// The committed development key (scripts/dev-keys/) signs fixtures, tests and everything the fixture server
    /// hands out, licences and catalogues alike. DEBUG builds trust it in both tables; release builds never do.
    public static let developmentKeyId = "dev-2026"
    static func withDevelopmentKey(_ keys: [String: String]) -> [String: String] {
        #if DEBUG
        var keys = keys
        keys[developmentKeyId] = "ORUshk9UHuNd8mebEbfEGTqbigEVYCaByVR8yyB8/TU="
        return keys
        #else
        return keys
        #endif
    }

    /// The licence issuer (Cloudflare Worker, same host as the website).
    public static let LICENCE_SERVICE_URL = URL(string: "https://offlinevault.dev/")!
    public static let pricingURL = URL(string: "https://offlinevault.dev/#pricing")!
    /// A stored key is refreshed online once the licence is this close to expiry (or past it).
    public static let licenceRefreshWindow: TimeInterval = 14 * 86400
    /// Once the licence is expired or invalid, the issuer is asked at most this often.
    public static let licenceRefreshBackoff: TimeInterval = 6 * 3600

    /// Same ladder as `updatesBaseURL`: `OFFLINEVAULT_LICENCE_URL` → fixture server → constant.
    public static var licenceServiceURL: URL {
        if let env = ProcessInfo.processInfo.environment["OFFLINEVAULT_LICENCE_URL"], let url = URL(string: env) { return url }
        if usesFixtureServer { return fixtureServerURL }
        return LICENCE_SERVICE_URL
    }

    /// Default and optional LLM models, delivered as `model` artefacts by the update service.
    public static let defaultModelArtefactId = "model-qwen3-4b-q4_k_m"
    public static let largeModelArtefactId = "model-qwen3-8b-q4_k_m"
    public static let largeModelMinimumRAMBytes: UInt64 = 16 * 1024 * 1024 * 1024
    /// Meta's Muse Glimmer 30B (dense, Apache-2.0, ~16.8 GB at Q4_K_M) for 32 GB+ Macs, plus its DFlash drafter.
    public static let glimmerModelArtefactId = "model-muse-glimmer-30b-q4_k_m"
    public static let glimmerDrafterArtefactId = "model-muse-glimmer-dflash"
    public static let glimmerMinimumRAMBytes: UInt64 = 32 * 1024 * 1024 * 1024

    /// Approximate build date, used only for clock-sanity warnings.
    public static let buildDate: Date = ISO8601DateFormatter().date(from: "2026-10-11T00:00:00Z")!

    public static var appVersion: String {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !v.isEmpty { return v }
        return "1.0.0"
    }

    public static var usesFixtureServer: Bool {
        if CommandLine.arguments.contains("--use-fixture-server") { return true }
        if ProcessInfo.processInfo.environment["OFFLINEVAULT_FIXTURE"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "useFixtureServer")
    }

    /// Effective base URL after applying all overrides (see `UPDATES_BASE_URL`).
    public static var updatesBaseURL: URL {
        if usesFixtureServer { return fixtureServerURL }
        if let env = ProcessInfo.processInfo.environment["OFFLINEVAULT_UPDATES_URL"], let url = URL(string: env) { return url }
        if let s = UserDefaults.standard.string(forKey: "updatesBaseURL"), !s.isEmpty, let url = URL(string: s) { return url }
        return UPDATES_BASE_URL
    }

    public static var manifestURL: URL { updatesBaseURL.appendingPathComponent(manifestFileName) }
}
