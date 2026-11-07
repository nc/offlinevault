import XCTest
@testable import OfflineVaultCore

final class ManifestTests: XCTestCase {
    func testParsesManifestWithISODates() throws {
        let m = try Manifest.parse(Fixtures.data("manifest_v1.json"))
        XCTAssertEqual(m.version, "2026.10.01")
        XCTAssertEqual(m.catalogueVersion, "1")
        XCTAssertEqual(m.artefacts.count, 4)
        XCTAssertEqual(m.artefacts[1].kind, .zim)
        XCTAssertEqual(m.artefacts[1].title, "Field Guide")
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: m.publishedAt), 2026)
        // fractional seconds also accepted
        let m2 = try Manifest.parse(Fixtures.data("manifest_v2.json"))
        XCTAssertEqual(m2.artefacts.first { $0.id == "zim-fieldguide-2026-10" }?.replaces, ["zim-fieldguide-2026-09"])
        XCTAssertEqual(m.artefacts.map(\.replaces), [[], [], [], []], "a missing replaces field reads as empty")
    }

    func testRejectsMalformedManifest() {
        XCTAssertThrowsError(try Manifest.parse(Data("{\"version\":1}".utf8)))
        let badSha = """
        {"version":"1","publishedAt":"2026-01-01T00:00:00Z","catalogueVersion":"1","artefacts":[{"id":"a","kind":"zim","path":"a.zim","sizeBytes":1,"sha256":"nope","minAppVersion":"1.0.0"}]}
        """
        XCTAssertThrowsError(try Manifest.parse(Data(badSha.utf8)))
        let traversal = badSha.replacingOccurrences(of: "\"nope\"", with: "\"" + String(repeating: "a", count: 64) + "\"").replacingOccurrences(of: "a.zim", with: "../a.zim")
        XCTAssertThrowsError(try Manifest.parse(Data(traversal.utf8)))
    }

    func testExternalArtefactDecodesAndDownloadsFromItsOwnURL() throws {
        let sha = String(repeating: "c", count: 64)
        let json = """
        {"version":"1","publishedAt":"2026-01-01T00:00:00Z","catalogueVersion":"1","artefacts":[
          {"id":"zim-ifixit-2025-12","kind":"zim","path":"zim/ifixit_en_all_2025-12.zim","sizeBytes":3570695757,"sha256":"\(sha)","minAppVersion":"1.0.0","tier":"free",
           "external":{"url":"https://download.kiwix.org/zim/ifixit/ifixit_en_all_2025-12.zim","shaSource":"kiwix-meta4","licence":"CC BY-NC-SA 3.0","attribution":"iFixit; ZIM by Kiwix"}},
          {"id":"zim-wikem-2026-07","kind":"zim","path":"zim/wikem_2026-07.zim","sizeBytes":1,"sha256":"\(sha)","minAppVersion":"1.0.0"}]}
        """
        let m = try Manifest.parse(Data(json.utf8))
        let base = URL(string: "https://offlinevault.dev/updates/")!
        let ifixit = m.artefacts[0], wikem = m.artefacts[1]
        XCTAssertEqual(ifixit.external, ExternalSource(url: URL(string: "https://download.kiwix.org/zim/ifixit/ifixit_en_all_2025-12.zim")!, shaSource: "kiwix-meta4", licence: "CC BY-NC-SA 3.0", attribution: "iFixit; ZIM by Kiwix"))
        XCTAssertEqual(ifixit.url(relativeTo: base).absoluteString, "https://download.kiwix.org/zim/ifixit/ifixit_en_all_2025-12.zim", "never our origin")
        XCTAssertEqual(ifixit.fileName, "ifixit_en_all_2025-12.zim", "path stays the local file name")
        XCTAssertEqual(ifixit.contentTier, .free)
        XCTAssertNil(wikem.external)
        XCTAssertEqual(wikem.url(relativeTo: base).absoluteString, "https://offlinevault.dev/updates/zim/wikem_2026-07.zim")
        let again = try Manifest.decoder().decode(Manifest.self, from: Manifest.encoder().encode(m))
        XCTAssertEqual(again, m, "external survives a round trip")
        XCTAssertThrowsError(try Manifest.parse(Data(json.replacingOccurrences(of: "https://download.kiwix.org", with: "kiwix.org").utf8))) {
            XCTAssertEqual(($0 as? UserFacingError)?.title, "Invalid manifest")
        }
    }

    func testExternalSourceOwnsTheFromKiwixCopy() {
        let e = ExternalSource(url: URL(string: "https://download.kiwix.org/zim/ifixit/ifixit_en_all_2025-12.zim")!, shaSource: "kiwix-meta4", licence: "CC BY-NC-SA 3.0")
        XCTAssertEqual(ExternalSource.tag, "From Kiwix")
        XCTAssertEqual(e.host, "download.kiwix.org")
        XCTAssertTrue(e.explanation.contains("download.kiwix.org") && e.explanation.contains("Not verified by OfflineVault") && e.explanation.contains("CC BY-NC-SA 3.0"), e.explanation)
        let err = e.checksumMismatch(label: "iFixit")
        XCTAssertEqual(err.title, "Kiwix download did not match")
        XCTAssertTrue(err.message.contains("Kiwix") && !err.message.contains("manifest"), "a Kiwix download problem, not a catalogue trust problem: \(err.message)")
    }

    func testArtefactURLPreservesBasePath() {
        let a = Artefact(id: "x", kind: .zim, path: "zim/my file.zim", sizeBytes: 1, sha256: String(repeating: "a", count: 64))
        XCTAssertEqual(a.url(relativeTo: URL(string: "https://cdn.example.com/updates")!).absoluteString, "https://cdn.example.com/updates/zim/my%20file.zim")
        XCTAssertEqual(a.url(relativeTo: URL(string: "http://127.0.0.1:8787/")!).absoluteString, "http://127.0.0.1:8787/zim/my%20file.zim")
    }

    func testSemanticVersionComparison() {
        XCTAssertTrue(SemanticVersion("1.2.3") < SemanticVersion("1.10.0"))
        XCTAssertTrue(SemanticVersion("1.0") == SemanticVersion("1.0.0"))
        XCTAssertTrue(SemanticVersion("2.0.0-beta") > SemanticVersion("1.9.9"))
        XCTAssertFalse(SemanticVersion("9.0.0") < SemanticVersion("1.0.0"))
    }

    func testDiffFreshInstallDownloadsEverythingCompatible() throws {
        let m = try Manifest.parse(Fixtures.data("manifest_v1.json"))
        let d = ManifestDiff.compute(manifest: m, installed: [], appVersion: "1.0.0")
        XCTAssertEqual(d.changes.map(\.artefact.id).sorted(), ["catalogue", "model-tiny", "zim-fieldguide-2026-09"])
        XCTAssertTrue(d.changes.allSatisfy { $0.reason == .new })
        XCTAssertEqual(d.incompatible.map(\.id), ["future-only"])
        XCTAssertEqual(d.totalDownloadBytes, 512 + 1_048_576 + 2048)
        XCTAssertTrue(d.orphanedInstalledIds.isEmpty)
    }

    func testDiffDetectsChangedReplacedAndUnchanged() throws {
        let v1 = try Manifest.parse(Fixtures.data("manifest_v1.json"))
        let installed = v1.artefacts.filter { $0.id != "future-only" }.map { InstalledArtefact(id: $0.id, kind: $0.kind, path: $0.path, fileName: $0.fileName, sizeBytes: $0.sizeBytes, sha256: $0.sha256) }
        let v2 = try Manifest.parse(Fixtures.data("manifest_v2.json"))
        let d = ManifestDiff.compute(manifest: v2, installed: installed, appVersion: "1.0.0")
        let byId = Dictionary(uniqueKeysWithValues: d.changes.map { ($0.artefact.id, $0) })
        XCTAssertEqual(byId["catalogue"]?.reason, .changed, "sha changed (case-insensitive compare)")
        XCTAssertEqual(byId["zim-fieldguide-2026-10"]?.reason, .replaces)
        XCTAssertEqual(byId["zim-fieldguide-2026-10"]?.removesInstalledId, "zim-fieldguide-2026-09")
        XCTAssertEqual(byId["pages-starter"]?.reason, .new)
        XCTAssertNil(byId["model-tiny"], "unchanged artefact is not re-downloaded")
        XCTAssertEqual(d.unchanged.map(\.id), ["model-tiny"])
        XCTAssertTrue(d.orphanedInstalledIds.isEmpty, "replaced artefact is referenced, not orphaned")
        XCTAssertEqual(d.totalDownloadBytes, 600 + 2_097_152 + 4096)
    }

    func testDiffRemovesTheFirstInstalledIdInReplaces() throws {
        // Skip-a-month: the September edition is installed, October was never fetched, November lists both.
        let sha = String(repeating: "1", count: 64)
        let september = InstalledArtefact(id: "zim-x-2026-09", kind: .zim, path: "zim/x_2026-09.zim", fileName: "x_2026-09.zim", sizeBytes: 1, sha256: sha)
        let november = Artefact(id: "zim-x-2026-11", kind: .zim, path: "zim/x_2026-11.zim", sizeBytes: 1, sha256: sha, replaces: ["zim-x-2026-10", "zim-x-2026-09"])
        let m = Manifest(version: "1", publishedAt: Date(), artefacts: [november], catalogueVersion: "1")
        let d = ManifestDiff.compute(manifest: m, installed: [september], appVersion: "1.0.0")
        XCTAssertEqual(d.changes.map(\.reason), [.replaces])
        XCTAssertEqual(d.changes.first?.removesInstalledId, "zim-x-2026-09")
        XCTAssertTrue(d.orphanedInstalledIds.isEmpty, "the retired edition is referenced, not orphaned")

        // Nothing in replaces is installed: a plain new artefact.
        let fresh = ManifestDiff.compute(manifest: m, installed: [], appVersion: "1.0.0")
        XCTAssertEqual(fresh.changes.map(\.reason), [.new])
        XCTAssertNil(fresh.changes.first?.removesInstalledId)

        // Two retired editions installed at once: the newest listed wins, the other is reported as an orphan.
        let october = InstalledArtefact(id: "zim-x-2026-10", kind: .zim, path: "zim/x_2026-10.zim", fileName: "x_2026-10.zim", sizeBytes: 1, sha256: sha)
        let both = ManifestDiff.compute(manifest: m, installed: [september, october], appVersion: "1.0.0")
        XCTAssertEqual(both.changes.first?.removesInstalledId, "zim-x-2026-10")
        XCTAssertEqual(both.orphanedInstalledIds, ["zim-x-2026-09"])
    }

    func testOrphanedInstalledArtefactsReported() throws {
        let v2 = try Manifest.parse(Fixtures.data("manifest_v2.json"))
        let stale = InstalledArtefact(id: "old-thing", kind: .zim, path: "zim/old.zim", fileName: "old.zim", sizeBytes: 1, sha256: String(repeating: "0", count: 64))
        let d = ManifestDiff.compute(manifest: v2, installed: [stale], appVersion: "1.0.0")
        XCTAssertEqual(d.orphanedInstalledIds, ["old-thing"])
    }
}
