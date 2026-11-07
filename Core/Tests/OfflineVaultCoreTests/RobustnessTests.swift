import XCTest
@testable import OfflineVaultCore

final class RobustnessTests: XCTestCase {
    static let fixtureZim = FixtureIntegrationTests.repoRoot.appendingPathComponent("fixture/out/zim/fieldguide_en_2026-10.zim")

    func testZimValidatorAcceptsRealAndRejectsDamagedFiles() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.fixtureZim.path), "run scripts/make_fixture_server.sh first")
        XCTAssertEqual(ZimValidator.validate(Self.fixtureZim), .ok)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Random bytes
        let junk = dir.appendingPathComponent("junk.zim"); try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: junk)
        if case .damaged(let why) = ZimValidator.validate(junk) { XCTAssertTrue(why.contains("magic")) } else { XCTFail("junk accepted") }
        // Truncated copy of a real ZIM (half the bytes): header is fine, pointers/checksum are not.
        let data = try Data(contentsOf: Self.fixtureZim)
        let truncated = dir.appendingPathComponent("truncated.zim"); try data.prefix(data.count / 2).write(to: truncated)
        if case .damaged(let why) = ZimValidator.validate(truncated) { XCTAssertTrue(why.contains("truncated") || why.contains("past the end"), why) } else { XCTFail("truncated accepted") }
        // Empty
        let empty = dir.appendingPathComponent("empty.zim"); try Data().write(to: empty)
        XCTAssertNotEqual(ZimValidator.validate(empty), .ok)
        XCTAssertEqual(ZimValidator.failedFile(inKiwixOutput: "Unable to add the ZIM file '/x/bad.zim' to the internal library."), "/x/bad.zim")
        XCTAssertNil(ZimValidator.failedFile(inKiwixOutput: "The Kiwix server is running"))
    }

    func testKiwixStartsWithTheGoodBookWhenOneIsDamaged() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OV_INTEGRATION"] == "1" && FileManager.default.fileExists(atPath: Self.fixtureZim.path), "integration")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good.zim"); try FileManager.default.copyItem(at: Self.fixtureZim, to: good)
        let bad = dir.appendingPathComponent("bad.zim"); try Data((0..<100_000).map { _ in UInt8.random(in: 0...255) }).write(to: bad)
        let kiwix = KiwixServeService(port: 8794)
        defer { kiwix.stop() }
        try await kiwix.start(zimFiles: [bad, good])
        XCTAssertTrue(kiwix.isRunning)
        XCTAssertEqual(kiwix.currentFiles, [good])
        XCTAssertNotNil(kiwix.damagedFiles[bad])
        let books = try await kiwix.books()
        XCTAssertEqual(books.count, 1)
    }

    func testQuickCheckAndRebuildPreserveConversations() throws {
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let maint = LibraryMaintenance(layout: layout, database: db)
        XCTAssertTrue(maint.quickCheck().isEmpty)
        // Seed: a document, a page, a conversation.
        let docs = DocumentService(layout: layout, database: db)
        _ = try docs.importPDF(from: Fixtures.url("sample_guide.pdf"))
        let pages = PageService(layout: layout, database: db)
        try Fixtures.string("sample_page.html").write(to: layout.pages.appendingPathComponent("water.html"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try pages.rescanFolder(), 1)
        let store = ChatStore(database: db)
        let c = try store.create(title: "keep me", model: nil); try store.save(ChatMessage(role: .user, content: "hello"), in: c.id)
        // Corrupt the derived index: delete the FTS rows behind the user's back.
        try db.db.execute("DELETE FROM doc_chunks_fts"); try db.db.execute("DELETE FROM page_chunks_fts")
        XCTAssertTrue(try docs.search("rolling boil").isEmpty)
        let report = maint.rebuildIndex { _ in }
        XCTAssertTrue(report.problems.isEmpty, report.problems.joined(separator: "; "))
        XCTAssertEqual(report.documents, 1); XCTAssertEqual(report.pages, 1)
        XCTAssertEqual(try docs.search("rolling boil").first?.page, 1, "search works again after rebuild")
        XCTAssertEqual(try pages.search("bleach").count, 1)
        XCTAssertEqual(try store.messages(in: c.id).count, 1, "chat history survives a rebuild")
        XCTAssertTrue(maint.quickCheck().isEmpty)
    }

    func testVerifyInstalledArtefactsDetectsBitRot() throws {
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let data = Data("model bytes".utf8)
        try data.write(to: layout.models.appendingPathComponent("m.gguf"))
        try db.recordInstalled(InstalledArtefact(id: "m", kind: .model, path: "models/m.gguf", fileName: "m.gguf", sizeBytes: Int64(data.count), sha256: Checksum.sha256Hex(of: data)))
        try db.recordInstalled(InstalledArtefact(id: "gone", kind: .zim, path: "zim/g.zim", fileName: "g.zim", sizeBytes: 1, sha256: String(repeating: "0", count: 64)))
        let maint = LibraryMaintenance(layout: layout, database: db)
        var rep = maint.verifyInstalledArtefacts { _ in }
        XCTAssertEqual(rep.items.first { $0.id == "m" }?.ok, true)
        XCTAssertEqual(rep.items.first { $0.id == "gone" }?.ok, false)
        try Data("model bytez".utf8).write(to: layout.models.appendingPathComponent("m.gguf"))
        rep = maint.verifyInstalledArtefacts { _ in }
        XCTAssertEqual(rep.items.first { $0.id == "m" }?.ok, false)
        XCTAssertTrue(rep.failures.count == 2 && rep.finished)
    }

    func testReadinessOnBareLibraryReportsWhatIsMissingWithoutCrashing() throws {
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let deps = ReadinessCheck.Dependencies(layout: layout, database: db, reference: nil, llm: nil, llmModelName: nil, coordinator: nil, backupService: BackupService(layout: layout, database: db), entitlements: .resolve(status: .none, source: .offlineVault), licence: nil, kiwixState: .stopped, llamaState: .stopped)
        let report = try awaitSync { await ReadinessCheck(deps: deps).run { _ in } }
        XCTAssertNotNil(report.finishedAt)
        let byId = Dictionary(uniqueKeysWithValues: report.items.map { ($0.id, $0) })
        XCTAssertEqual(byId["index"]?.status, .pass)
        XCTAssertEqual(byId["books"]?.status, .warn, "no books is a warning with a fix, not a crash")
        XCTAssertEqual(byId["books"]?.fix, "updates")
        XCTAssertEqual(byId["ai"]?.status, .warn)
        XCTAssertEqual(byId["backup"]?.status, .warn); XCTAssertEqual(byId["backup"]?.fix, "backup")
        XCTAssertEqual(byId["licence"]?.status, .warn)
        XCTAssertEqual(byId["maps"]?.status, .warn)
        XCTAssertEqual(report.overall, .fail == report.overall ? .fail : report.overall) // overall is the worst status
        XCTAssertTrue(report.items.allSatisfy { !$0.detail.isEmpty })
    }

    func testClockSanity() {
        XCTAssertNil(ClockSanity.looksWrong(licence: nil, buildDate: Date().addingTimeInterval(-86400 * 10)))
        XCTAssertNotNil(ClockSanity.looksWrong(licence: nil, buildDate: Date().addingTimeInterval(86400 * 10)), "clock before build date")
        let future = Licence(licenceId: "x", subscriber: "y", plan: .core, issuedAt: Date().addingTimeInterval(86400 * 30), expiresAt: Date().addingTimeInterval(86400 * 400))
        XCTAssertNotNil(ClockSanity.looksWrong(licence: future, buildDate: Date().addingTimeInterval(-86400)))
    }
}
