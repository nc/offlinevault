import XCTest
@testable import OfflineVaultCore

/// The client's own code path against the published catalogue: fetch and verify the signed manifest, download and
/// install the Field Guide and the small document packs with resume and checksum, then search the installed book.
/// Opt in with `OV_LIVE_BASE=https://offlinevault.dev/updates/` so CI never depends on the network.
///
///     OV_LIVE_BASE=https://offlinevault.dev/updates/ OFFLINEVAULT_BIN_DIR=$PWD/../OfflineVault/Resources/bin swift test --filter LiveCatalogueIntegrationTests
final class LiveCatalogueIntegrationTests: XCTestCase {
    var baseURL: URL!

    override func setUpWithError() throws {
        guard let raw = ProcessInfo.processInfo.environment["OV_LIVE_BASE"], let url = URL(string: raw) else {
            throw XCTSkip("set OV_LIVE_BASE to run against the published catalogue")
        }
        baseURL = url
    }

    func testVerifiedCatalogueInstallsAndSearches() async throws {
        let suite = "ov-live-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let svc = UpdateService(layout: layout, database: db, baseURL: baseURL, appVersion: "1.0.0", settings: AppSettings(defaults: defaults))

        let fetched = try await svc.fetchManifest()
        guard case .verified(let keyId, _, let mirror) = fetched.trust else { return XCTFail("expected a verified catalogue, got \(fetched.trust)") }
        XCTAssertEqual(keyId, "content-2026-10")
        XCTAssertNil(mirror, "the official origin is not a mirror")
        XCTAssertGreaterThanOrEqual(fetched.manifest.artefacts.count, 17)

        // Install only what a test can afford: the Field Guide and the two small document packs.
        let diff = try svc.diff(fetched.manifest)
        let wanted = diff.changes.filter { $0.artefact.id.hasPrefix("zim-fieldguide") || $0.artefact.kind == .documentPack || $0.artefact.kind == .catalogue }
        XCTAssertEqual(wanted.filter { $0.artefact.id.hasPrefix("zim-fieldguide") }.count, 1, "exactly one Field Guide edition is offered")
        for change in wanted { try await svc.apply(change, manifestVersion: fetched.manifest.version) { _ in } }
        let installed = Set(try db.installedArtefacts().map(\.id))
        XCTAssertTrue(installed.contains { $0.hasPrefix("zim-fieldguide") })

        let zim = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: layout.zim, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("fieldguide_en_") })
        let kiwix = KiwixServeService(port: 8796)
        defer { kiwix.stop() }
        try await kiwix.start(zimFiles: [zim])
        let books = try await kiwix.books()
        XCTAssertEqual(books.count, 1)
        for (query, needle) in [("bleach", "water"), ("tourniquet", "bleeding"), ("botulism", "botulism"), ("carbon monoxide", "carbon")] {
            let hits = try await kiwix.search(query, books: nil, limit: 5)
            XCTAssertTrue((hits.first?.title)?.lowercased().contains(needle) == true, "\(query): top hit was \(String(describing: hits.first?.title))")
        }
    }
}
