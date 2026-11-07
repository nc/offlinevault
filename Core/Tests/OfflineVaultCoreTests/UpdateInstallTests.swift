import XCTest
@testable import OfflineVaultCore

final class UpdateInstallTests: XCTestCase {
    func testInstallReplacesPreviousArtefactAtomicallyAndUpdatesIndex() throws {
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let svc = UpdateService(layout: layout, database: db, baseURL: URL(string: "http://127.0.0.1:1/")!, appVersion: "1.0.0")

        // v1 zim installed
        let old = Data("old zim".utf8)
        let oldArt = Artefact(id: "zim-v1", kind: .zim, path: "zim/guide_2026-09.zim", sizeBytes: Int64(old.count), sha256: Checksum.sha256Hex(of: old), title: "Guide")
        let staged1 = layout.staging.appendingPathComponent("s1")
        try old.write(to: staged1)
        try svc.install(verifiedFile: staged1, artefact: oldArt, removingInstalledId: nil, manifestVersion: "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.zim.appendingPathComponent("guide_2026-09.zim").path))
        XCTAssertEqual(try db.zimBooks().map(\.name), ["guide_2026-09"])

        // v2 replaces v1
        let new = Data("new zim".utf8)
        let newArt = Artefact(id: "zim-v2", kind: .zim, path: "zim/guide_2026-10.zim", sizeBytes: Int64(new.count), sha256: Checksum.sha256Hex(of: new), replaces: ["zim-v1"])
        let staged2 = layout.staging.appendingPathComponent("s2")
        try new.write(to: staged2)
        try svc.install(verifiedFile: staged2, artefact: newArt, removingInstalledId: "zim-v1", manifestVersion: "2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.zim.appendingPathComponent("guide_2026-09.zim").path), "replaced file removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.zim.appendingPathComponent("guide_2026-10.zim").path))
        XCTAssertEqual(try db.installedArtefacts().map(\.id), ["zim-v2"])
        XCTAssertEqual(try db.zimBooks().map(\.name), ["guide_2026-10"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged2.path), "staging file moved, not copied")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: layout.staging.path).filter { $0.hasPrefix(".previous-") }.isEmpty)
    }

    func testAnInstalledExternalBookRemembersItCameFromKiwix() throws {
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let svc = UpdateService(layout: layout, database: db, baseURL: URL(string: "http://127.0.0.1:1/")!, appVersion: "1.0.0")
        let bytes = Data("kiwix zim".utf8)
        let art = Artefact(id: "zim-ifixit-2025-12", kind: .zim, path: "zim/ifixit_en_all_2025-12.zim", sizeBytes: Int64(bytes.count), sha256: Checksum.sha256Hex(of: bytes), title: "iFixit", tier: "free",
                           external: ExternalSource(url: URL(string: "https://download.kiwix.org/zim/ifixit/ifixit_en_all_2025-12.zim")!, shaSource: "kiwix-meta4", licence: "CC BY-NC-SA 3.0"))
        let staged = layout.staging.appendingPathComponent("s")
        try bytes.write(to: staged)
        try svc.install(verifiedFile: staged, artefact: art, removingInstalledId: nil, manifestVersion: "1")
        let book = try XCTUnwrap(try db.zimBooks().first)
        XCTAssertEqual(book.name, "ifixit_en_all_2025-12")
        XCTAssertTrue(book.isExternal)
        // The engine scan upserts the row again without knowing where it came from; the provenance sticks.
        try db.upsertZimBook(ZimBook(name: book.name, fileName: book.fileName, title: "iFixit in English", articleCount: 103480))
        XCTAssertTrue(try XCTUnwrap(try db.zimBooks().first).isExternal)
        XCTAssertEqual(try db.zimBooks().first?.articleCount, 103480)
        let plain = Artefact(id: "zim-wikem", kind: .zim, path: "zim/wikem.zim", sizeBytes: Int64(bytes.count), sha256: Checksum.sha256Hex(of: bytes))
        try bytes.write(to: staged)
        try svc.install(verifiedFile: staged, artefact: plain, removingInstalledId: nil, manifestVersion: "1")
        XCTAssertEqual(try db.zimBooks().map { ($0.name, $0.isExternal) }.map { "\($0.0):\($0.1)" }.sorted(), ["ifixit_en_all_2025-12:true", "wikem:false"])
    }

    func testPagePackExtractsAndIndexes() throws {
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let svc = UpdateService(layout: layout, database: db, baseURL: URL(string: "http://127.0.0.1:1/")!, appVersion: "1.0.0")
        // Build a tar.gz with one captured page.
        let work = layout.staging.appendingPathComponent("packsrc", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Fixtures.string("sample_page.html").write(to: work.appendingPathComponent("water.html"), atomically: true, encoding: .utf8)
        let tar = layout.staging.appendingPathComponent("pages.tar.gz")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); p.arguments = ["-czf", tar.path, "-C", work.path, "."]; try p.run(); p.waitUntilExit()
        let data = try Data(contentsOf: tar)
        let art = Artefact(id: "pages-starter", kind: .pagePack, path: "packs/pages.tar.gz", sizeBytes: Int64(data.count), sha256: Checksum.sha256Hex(of: data))
        try svc.install(verifiedFile: tar, artefact: art, removingInstalledId: nil, manifestVersion: "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.pages.appendingPathComponent("water.html").path))
        let pages = PageService(layout: layout, database: db)
        XCTAssertEqual(try pages.rescanFolder(), 1)
        XCTAssertEqual(try pages.search("bleach").first?.page.title, "Water purification in the field – Field Notes")
        XCTAssertEqual(try db.installedArtefacts().first?.id, "pages-starter")
    }

    func testStorageReportAndLayout() throws {
        let layout = try makeTempLibrary(self)
        try Data(count: 4096).write(to: layout.models.appendingPathComponent("m.gguf"))
        let r = layout.storageReport()
        XCTAssertGreaterThanOrEqual(r.bytesByCategory[.models] ?? 0, 4096)
        XCTAssertGreaterThan(r.volumeTotalBytes, 0)
        XCTAssertTrue(LibraryLayout.looksLikeLibrary(layout.root))
        XCTAssertEqual(layout.directory(forKind: .videoPack), layout.videos)
    }
}
