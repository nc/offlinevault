import XCTest
@testable import OfflineVaultCore

final class HoardAndSafetyTests: XCTestCase {
    func testSubjectClassifier() {
        XCTAssertEqual(SubjectClassifier.classify("FM 4-25.11 First Aid\nControl bleeding with a tourniquet; treat for shock; splint fractures."), .medical)
        XCTAssertEqual(SubjectClassifier.classify("Complete Guide to Home Canning\nPressure canning vegetables, pickles and jams; food preservation."), .food)
        XCTAssertEqual(SubjectClassifier.classify("Off-grid solar wiring\nCharge controller, inverter, LiFePO4 battery bank, voltage drop."), .power)
        XCTAssertEqual(SubjectClassifier.classify("Making Water Safe\nBoil water, bleach disinfection, filtration, chlorine residual."), .water)
        XCTAssertEqual(SubjectClassifier.classify("Quarterly sales report"), .general)
    }

    func testHighStakesDetectionAndRefusal() {
        XCTAssertEqual(Prompting.highStakes("Is this mushroom safe to eat? It has a white cap"), .mushroomIdentification)
        XCTAssertEqual(Prompting.highStakes("can I eat these red berries I found while foraging"), .plantIdentification)
        XCTAssertEqual(Prompting.highStakes("how many mg of ibuprofen for a child"), .medicationDosing)
        XCTAssertEqual(Prompting.highStakes("how many drops of bleach per gallon of water"), .chemicalMixing)
        XCTAssertNil(Prompting.highStakes("how do I build a lean-to shelter"))
        XCTAssertNil(Prompting.highStakes("6 month old baby choking, cant cry, is it the same as the heimlich"), "\"ml\" inside heimlich is not a dose")
        XCTAssertEqual(Prompting.highStakes("how many ml of childrens ibuprofen for my 2 year old, she weighs 11kg"), .medicationDosing)
        XCTAssertEqual(Prompting.highStakes("can i give my 4 year old adult paracetamol tablets"), .medicationDosing)
        XCTAssertNil(Prompting.highStakes("history of penicillin discovery"))
        let dose = RetrievedPassage(label: 2, source: .zimArticle(book: "nhs", path: "A/Ibuprofen", title: "Ibuprofen for children"), text: "Children aged 1 to 3 years: 5 ml, up to 3 times a day.\nAlways check the packaging.", score: 1, retriever: "reference")
        let quoted = Prompting.sourcesOnlyAnswer(for: .medicationDosing, passages: [dose])
        XCTAssertTrue(quoted.contains("word for word"), "says the answer is the source text, not a computation")
        XCTAssertTrue(quoted.contains("Ibuprofen for children: Children aged 1 to 3 years: 5 ml, up to 3 times a day. Always check the packaging. [2]"), quoted)
        let g = Grounding.ground(answer: quoted, passages: [dose])
        XCTAssertEqual(g.supportedClaims, 1, "the passage line renders as a quote of itself")
        XCTAssertEqual(g.unverifiedClaims, 0)
        XCTAssertTrue(Prompting.isSafetyCritical("all my blood pressure pills expired 2 years ago, can i still take them"), "medicine questions are safety-critical")
        XCTAssertEqual(Grounding.ground(answer: Prompting.fieldGuideOnlyNote, passages: []).unverifiedClaims, 0, "the note carries no claims of its own")
        let r = Prompting.refusal(for: .mushroomIdentification, libraryOn: false)
        XCTAssertTrue(r.contains("can't answer this from memory") && r.contains("Search library"))
    }

    func testEPUBParsingAndImportWithDedupe() throws {
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let docs = DocumentService(layout: layout, database: db)
        // Build a minimal EPUB with the system zip.
        let src = layout.staging.appendingPathComponent("epubsrc", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        try "application/epub+zip".write(to: src.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.write(to: src.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Shelter Craft</dc:title><dc:creator>Test Author</dc:creator></metadata>
        <manifest><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
        """.write(to: src.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)
        try "<html><head><title>Lean-to</title></head><body><h1>Lean-to</h1><p>A lean-to shelter uses a ridgepole lashed between two trees with poles leaned against it and covered with boughs or a tarp for insulation and rain protection.</p></body></html>".write(to: src.appendingPathComponent("OEBPS/ch1.xhtml"), atomically: true, encoding: .utf8)
        try "<html><head><title>Debris hut</title></head><body><h1>Debris hut</h1><p>A debris hut is a small insulated shelter built from a ridgepole, ribbing and a thick layer of leaves; it keeps a person warm without fire in cold weather.</p></body></html>".write(to: src.appendingPathComponent("OEBPS/ch2.xhtml"), atomically: true, encoding: .utf8)
        let epub = layout.staging.appendingPathComponent("shelter.epub")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = src; zip.arguments = ["-qr", "-X", epub.path, "."]; zip.standardOutput = FileHandle.nullDevice; try zip.run(); zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let book = try EPUB.open(epub)
        XCTAssertEqual(book.title, "Shelter Craft")
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters[1].title, "Debris hut")

        let d = try XCTUnwrap(try docs.importDocument(from: epub))
        XCTAssertEqual(d.kind, .epub)
        XCTAssertEqual(d.title, "Shelter Craft")
        XCTAssertEqual(d.pageCount, 2)
        XCTAssertEqual(d.subject, .shelter)
        XCTAssertEqual(try docs.search("debris hut").first?.page, 2)
        XCTAssertEqual(d.unitLabel, "chapter")

        // Duplicate import (same bytes, different name) is skipped.
        let copy = layout.staging.appendingPathComponent("shelter-copy.epub")
        try FileManager.default.copyItem(at: epub, to: copy)
        XCTAssertNil(try docs.importDocument(from: copy))
        XCTAssertEqual(try docs.documents().count, 1)

        // Hoard import over a folder with pdf + epub + duplicate + text.
        let hoard = layout.staging.appendingPathComponent("hoard", isDirectory: true)
        try FileManager.default.createDirectory(at: hoard.appendingPathComponent("medical"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixtures.url("sample_guide.pdf"), to: hoard.appendingPathComponent("medical/water-guide.pdf"))
        try FileManager.default.copyItem(at: epub, to: hoard.appendingPathComponent("shelter-dupe.epub"))
        try "Radio notes\nNOAA weather radio frequencies: 162.400 162.425 162.450 162.475 162.500 162.525 162.550 MHz. GMRS repeater channels 15-22.".write(to: hoard.appendingPathComponent("radio.txt"), atomically: true, encoding: .utf8)
        let importer = LibraryImporter(layout: layout, documents: docs, pages: PageService(layout: layout, database: db), videos: VideoLibraryService(layout: layout, database: db))
        let report = try awaitSync { await importer.importFolder(hoard) { _ in } }
        XCTAssertEqual(report.total, 3)
        XCTAssertEqual(report.imported, 2)
        XCTAssertEqual(report.duplicates, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(try docs.documents().count, 3)
        XCTAssertEqual(try docs.subjectCounts()[.communications], 1)
        XCTAssertEqual(try docs.subjectCounts()[.water], 1)
    }

    func testBackupCloneAndVerify() throws {
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        try Data(count: 1_000_000).write(to: layout.models.appendingPathComponent("m.gguf"))
        try Fixtures.data("sample_guide.pdf").write(to: layout.documents.appendingPathComponent("g.pdf"))
        try Data("junk".utf8).write(to: layout.staging.appendingPathComponent("x.part"))
        let backup = BackupService(layout: layout, database: db)
        XCTAssertTrue(backup.isReminderDue)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ov-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) }
        let r = try awaitSync { await backup.clone(to: dest) { _ in } }
        XCTAssertNil(r.error); XCTAssertTrue(r.mismatches.isEmpty)
        XCTAssertGreaterThanOrEqual(r.filesCopied, 2)
        XCTAssertEqual(r.filesVerified, r.filesCopied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("documents/g.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("staging/x.part").path), "staging excluded")
        XCTAssertFalse(backup.isReminderDue)
        XCTAssertEqual(backup.lastBackupPath, dest.path)
        // Second run copies nothing new.
        let r2 = try awaitSync { await backup.clone(to: dest) { _ in } }
        XCTAssertLessThanOrEqual(r2.filesCopied, 3, "only the live SQLite files may change between runs")
        XCTAssertTrue(r2.mismatches.isEmpty)
        // Verify detects corruption.
        try Data("corrupt".utf8).write(to: dest.appendingPathComponent("documents/g.pdf"))
        let v = backup.verify(dest)
        XCTAssertTrue(v.mismatches.contains("documents/g.pdf"))
    }

    func testShareServerRoutesAndRanges() throws {
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        try Data((0..<1000).map { UInt8($0 % 251) }).write(to: layout.videos.appendingPathComponent("v.mp4"))
        let server = LocalShareServer(layout: layout, database: db, kiwixPort: 8765, port: 8788)
        let landing = server.route(path: "/", rangeHeader: nil)
        XCTAssertEqual(landing.status, 200)
        XCTAssertTrue(String(decoding: landing.body ?? Data(), as: UTF8.self).contains("OfflineVault library"))
        XCTAssertEqual(server.route(path: "/videos/../index/library.sqlite", rangeHeader: nil).status, 404, "no traversal")
        XCTAssertEqual(server.route(path: "/videos/missing.mp4", rangeHeader: nil).status, 404)
        let full = server.route(path: "/videos/v.mp4", rangeHeader: nil)
        XCTAssertEqual(full.status, 200); XCTAssertEqual(full.range, 0..<1000); XCTAssertEqual(full.headers["Content-Type"], "video/mp4")
        let part = server.route(path: "/videos/v.mp4", rangeHeader: "bytes=100-199")
        XCTAssertEqual(part.status, 206); XCTAssertEqual(part.range, 100..<200); XCTAssertEqual(part.headers["Content-Range"], "bytes 100-199/1000")
        XCTAssertEqual(server.route(path: "/videos/v.mp4", rangeHeader: "bytes=900-").range, 900..<1000)
        XCTAssertEqual(LocalShareServer.parseRange("bytes=-100", size: 1000), 900..<1000)
        XCTAssertNil(LocalShareServer.parseRange("bytes=5000-", size: 1000))

        // Real socket round-trip.
        try server.start()
        defer { server.stop() }
        let exp = expectation(description: "http")
        var got: (Int, Data)?
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8788/videos/v.mp4")!); req.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        URLSession.shared.dataTask(with: req) { data, resp, _ in got = ((resp as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()); exp.fulfill() }.resume()
        wait(for: [exp], timeout: 10)
        XCTAssertEqual(got?.0, 206)
        XCTAssertEqual(got?.1, Data((10..<20).map { UInt8($0 % 251) }))
    }

    func testPMTilesHeaderParsesRealFileIfPresent() throws {
        let f = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-namitchadha-Workspace-offline-vault/8832de4b-ae96-4af1-aa04-eacb243081c0/scratchpad/webassets/firenze.pmtiles")
        let fixture = FixtureIntegrationTests.repoRoot.appendingPathComponent("fixture/out/maps/firenze.pmtiles")
        let url = FileManager.default.fileExists(atPath: fixture.path) ? fixture : f
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "no PMTiles sample available")
        let h = try XCTUnwrap(PMTilesHeader.read(url))
        XCTAssertEqual(h.tileType, "mvt")
        XCTAssertEqual(h.maxZoom, 15)
        XCTAssertEqual(h.name, "Protomaps Basemap")
        XCTAssertTrue(h.version?.hasPrefix("3") ?? false)
        XCTAssertEqual(h.centerLat, 43.767213, accuracy: 0.001)
    }
}
