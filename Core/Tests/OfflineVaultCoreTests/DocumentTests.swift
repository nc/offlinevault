import XCTest
@testable import OfflineVaultCore

final class DocumentTests: XCTestCase {
    func testImportIndexesPagesAndSearchReturnsPageNumbers() throws {
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let docs = DocumentService(layout: layout, database: db)
        let d = try docs.importPDF(from: Fixtures.url("sample_guide.pdf"))
        XCTAssertEqual(d.title, "Field Water Treatment Guide", "title comes from the PDF metadata")
        XCTAssertEqual(d.pageCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.documents.appendingPathComponent("sample_guide.json").path), "sidecar written")

        let boil = try docs.search("rolling boil")
        XCTAssertEqual(boil.first?.page, 1)
        let bleach = try docs.search("bleach drops litre", anyTerm: true)
        XCTAssertEqual(bleach.first?.page, 2)
        XCTAssertTrue(bleach.first!.chunkText.contains("two drops per litre"))
        XCTAssertTrue(try docs.search("carburettor").isEmpty)

        // Retriever exposes page-level sources with a procedural boost on safety-critical questions.
        let r = DocumentRetriever(documents: docs)
        let passages = try awaitSync { try await r.retrieve("how many drops of bleach per litre", limit: 5) }
        guard case .document(let id, _, let page)? = passages.first?.source else { return XCTFail("expected a document source") }
        XCTAssertEqual(id, d.id); XCTAssertEqual(page, 2)

        // Rescan is idempotent and picks up files dropped into the folder (e.g. by a document pack).
        XCTAssertEqual(try docs.rescanFolder(), 0)
        try FileManager.default.copyItem(at: Fixtures.url("sample_guide.pdf"), to: layout.documents.appendingPathComponent("second.pdf"))
        XCTAssertEqual(try docs.rescanFolder(), 1)
        XCTAssertEqual(try docs.documents().count, 2)
        try docs.delete(d)
        XCTAssertEqual(try docs.documents().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.documents.appendingPathComponent("sample_guide.pdf").path))
    }

    func testDehyphenation() {
        XCTAssertEqual(DocumentService.dehyphenate("disin-\nfection is reli-\nable.\nNext sentence\nstarts here."), "disinfection is reliable.\nNext sentence starts here.")
    }

    func testTiersAndRolesParseAndBoost() throws {
        let json = """
        {"version":"1","publishedAt":"2026-01-01T00:00:00Z","catalogueVersion":"1","artefacts":[
          {"id":"a","kind":"zim","path":"zim/a.zim","sizeBytes":1,"sha256":"\(String(repeating: "a", count: 64))","minAppVersion":"1.0.0","tier":"complete"},
          {"id":"b","kind":"document-pack","path":"packs/b.tar.gz","sizeBytes":1,"sha256":"\(String(repeating: "b", count: 64))","minAppVersion":"1.0.0"}]}
        """
        let m = try Manifest.parse(Data(json.utf8))
        XCTAssertEqual(m.artefacts[0].contentTier, .complete)
        XCTAssertEqual(m.artefacts[1].contentTier, .core, "missing tier defaults to core")
        XCTAssertEqual(m.artefacts[1].kind, .documentPack)
        XCTAssertTrue(ContentTier.core < ContentTier.complete)
        let entry = Catalogue.Entry(artefactId: "a", title: "FM", role: "procedural")
        XCTAssertEqual(entry.bookRole, .procedural)
        XCTAssertGreaterThan(BookRole.procedural.proceduralBoost, BookRole.encyclopaedic.proceduralBoost)
        XCTAssertEqual(LibraryLayout(root: URL(fileURLWithPath: "/tmp/x")).directory(forKind: .documentPack).lastPathComponent, "documents")
    }

    func testReferenceRetrieverBoostsProceduralBooksOnSafetyQuestions() async throws {
        final class Fake: ReferenceLibraryService, @unchecked Sendable {
            var isRunning: Bool { true }
            var engineDescription: String { "fake" }
            var baseURL: URL { URL(string: "http://127.0.0.1:1/")! }
            func start(zimFiles: [URL]) async throws {}
            func stop() {}
            func books() async throws -> [ReferenceBook] { [] }
            func search(_ query: String, books: [String]?, limit: Int) async throws -> [ReferenceHit] {
                [ReferenceHit(bookName: "wikipedia", title: "Tourniquet", path: "A/T", snippet: "encyclopaedia text about tourniquets"),
                 ReferenceHit(bookName: "fm4-25", title: "Control bleeding", path: "A/B", snippet: "apply the tourniquet 5 cm above the wound")]
            }
            func articleText(bookName: String, path: String) async throws -> String { "" }
            func articleURL(bookName: String, path: String) -> URL { baseURL }
            func mainPageURL(bookName: String) -> URL { baseURL }
        }
        let r = ReferenceRetriever(service: Fake(), bookRoles: { ["fm4-25": .procedural, "wikipedia": .encyclopaedic] })
        let safety = try await r.retrieve("how do I apply a tourniquet to stop bleeding", limit: 5)
        XCTAssertTrue(safety.prefix(2).contains { $0.source.title == "Control bleeding" }, "field manual is guaranteed a top-two slot on a safety-critical question")
        let neutral = try await r.retrieve("history of the tourniquet", limit: 5)
        XCTAssertEqual(neutral.first?.source.title, "Tourniquet", "no boost on non-safety questions")
    }
}

/// Runs an async closure synchronously inside a non-async test (keeps the PDF test linear).
func awaitSync<T>(_ body: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task { do { result = .success(try await body()) } catch { result = .failure(error) }; sem.signal() }
    sem.wait()
    return try result.get()
}
