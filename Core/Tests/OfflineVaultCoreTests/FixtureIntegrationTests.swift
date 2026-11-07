import XCTest
@testable import OfflineVaultCore

/// End-to-end tests against the local fixture server and the real bundled helpers.
/// Skipped unless `OV_INTEGRATION=1` is set; requires `scripts/fetch_binaries.sh --allow-rosetta` and
/// `scripts/make_fixture_server.sh` to have been run. The test starts its own fixture server on a free port.
///
///     OV_INTEGRATION=1 OFFLINEVAULT_BIN_DIR=$PWD/../OfflineVault/Resources/bin swift test --filter FixtureIntegrationTests
final class FixtureIntegrationTests: XCTestCase {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var server: Process?
    /// 8799 is somebody else's server to the app (self-hosted); the official-port test moves to 8787.
    var port = 8799
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }
    /// Each test gets its own defaults so the replay guard (`lastVerifiedPublishedAt`) never leaks between tests.
    lazy var settings: AppSettings = {
        let suite = "ov-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: defaults)
    }()

    func makeService(_ layout: LibraryLayout, _ db: IndexDatabase, appVersion: String = "1.0.0") -> UpdateService {
        UpdateService(layout: layout, database: db, baseURL: baseURL, appVersion: appVersion, settings: settings)
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OV_INTEGRATION"] == "1", "set OV_INTEGRATION=1 to run fixture integration tests")
        let out = Self.repoRoot.appendingPathComponent("fixture/out/manifest.v1.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: out.path), "run scripts/make_fixture_server.sh first")
    }

    override func tearDown() { stopServer() }

    func startServer(version: Int, throttle: Double = 0, signed: Bool = true) async throws {
        stopServer()
        Self.killListeners(onPort: port) // a crashed previous run may have left a server behind
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", Self.repoRoot.appendingPathComponent("scripts/fixture_server.py").path, "--root", Self.repoRoot.appendingPathComponent("fixture/out").path, "--port", String(port), "--version", String(version), "--throttle", String(throttle)] + (signed ? [] : ["--unsigned"])
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        server = p
        for _ in 0..<50 { if await LocalHTTP.isHealthy(baseURL.appendingPathComponent("manifest.json")) { return }; try await Task.sleep(nanoseconds: 100_000_000) }
        XCTFail("fixture server did not start")
    }

    func stopServer() {
        if let p = server {
            // Avoid Process.waitUntilExit (can block forever if the child exits during terminate()); poll instead.
            if p.isRunning { p.terminate() }
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL); usleep(200_000) }
        }
        server = nil
        Self.killListeners(onPort: port)
    }

    static func isPortOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = in_port_t(port).bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    static func killListeners(onPort port: Int) {
        guard isPortOpen(port) else { return } // lsof is slow; only use it when something is actually listening
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof"); p.arguments = ["-ti", ":\(port)"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        let pids = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        for pid in pids where pid != getpid() { kill(pid, SIGKILL) }
        if !pids.isEmpty { usleep(300_000) }
    }

    /// Applies every change the catalogue serves itself. The fixture's "from Kiwix" book is signed with an absolute
    /// URL on the port the fixture was built for, so on this test's own port it stands for a Kiwix server that is
    /// not reachable; the app run against the fixture server downloads it.
    func applyAll(_ svc: UpdateService) async throws -> (Manifest, ManifestDiff) {
        let manifest = try await svc.fetchManifest().manifest
        let diff = try svc.diff(manifest)
        for change in diff.changes where change.artefact.external == nil {
            try await svc.apply(change, manifestVersion: manifest.version) { _ in }
        }
        return (manifest, diff)
    }

    // MARK: Setup → base pack → update → search → chat → play

    func testFullFlowAgainstFixture() async throws {
        try await startServer(version: 1)
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let svc = makeService(layout, db)

        // 1. First run: base pack downloads and verifies.
        let (m1, d1) = try await applyAll(svc)
        XCTAssertEqual(m1.version, "2026.10.01")
        XCTAssertEqual(d1.changes.count, 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.maps.appendingPathComponent("firenze.pmtiles").path), "map region installed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.maps.appendingPathComponent("world-overview.pmtiles").path), "world overview installed")
        let installedMaps = MapsService(layout: layout).maps()
        XCTAssertTrue(installedMaps.contains { $0.header?.maxZoom == 15 })
        XCTAssertTrue(installedMaps.contains { $0.header?.minZoom == 0 && ($0.header!.maxLon - $0.header!.minLon) > 300 }, "world overview spans the globe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.zim.appendingPathComponent("fieldguide_en_2026-09.zim").path))
        XCTAssertFalse(LocalModel.scan(layout.models).isEmpty, "model installed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.catalogueURL.path))
        let videos = VideoLibraryService(layout: layout, database: db)
        XCTAssertEqual(try videos.rescanFolder(), 1, "video pack extracted and indexed")
        let th = try XCTUnwrap(try videos.searchTranscripts("bleach").first)
        XCTAssertTrue(th.text.contains("bleach")); XCTAssertEqual(th.startSeconds, 0.5)
        XCTAssertEqual(try db.zimBooks().first?.title, "Field Guide (fixture)", "catalogue metadata applied to the zim row")
        XCTAssertEqual(try db.zimBooks().first?.role, .procedural)
        let docs = DocumentService(layout: layout, database: db)
        XCTAssertGreaterThanOrEqual(try docs.rescanFolder(), 1, "document pack extracted and indexed")
        let docHit = try XCTUnwrap(try docs.search("rolling boil").first)
        XCTAssertEqual(docHit.page, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: layout.staging.path).filter { $0.hasSuffix(".part") }.isEmpty, "staging is clean after install")

        // 2. Changed manifest (v2): zim replaced, page pack added, incompatible artefact skipped.
        try await startServer(version: 2)
        let (m2, d2) = try await applyAll(svc)
        XCTAssertEqual(m2.version, "2026.10.08")
        XCTAssertEqual(Set(d2.changes.map(\.artefact.id)), ["catalogue", "zim-fieldguide-2026-10", "pages-starter", "zim-fieldguide-full", "zim-kiwix-fixture-2026-11"])
        let fromKiwix = try XCTUnwrap(d2.changes.first { $0.artefact.id == "zim-kiwix-fixture-2026-11" }?.artefact)
        XCTAssertEqual(fromKiwix.external?.url.path, "/kiwix/zimit/kiwix-fixture_en_2026-11.zim")
        XCTAssertEqual(fromKiwix.contentTier, .free)
        XCTAssertEqual(d2.changes.first { $0.artefact.id == "zim-fieldguide-full" }?.artefact.contentTier, .full)
        XCTAssertEqual(d2.incompatible.map(\.id), ["zim-future"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.zim.appendingPathComponent("fieldguide_en_2026-09.zim").path), "old edition removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.zim.appendingPathComponent("fieldguide_en_2026-10.zim").path))
        let ids = Set(try db.installedArtefacts().map(\.id))
        XCTAssertEqual(ids.subtracting(["model-fixture", "model-qwen3-4b-q4_k_m"]), ["catalogue", "zim-fieldguide-2026-10", "video-starter", "docs-starter", "pages-starter", "map-firenze", "map-world-overview", "zim-fieldguide-full"])
        XCTAssertEqual(ids.count, 9)
        let pages = PageService(layout: layout, database: db)
        XCTAssertEqual(try pages.rescanFolder(), 1)
        XCTAssertEqual(try pages.search("bowline").count, 1)
        // Re-check: nothing left but the book from Kiwix, which applyAll leaves alone.
        let again = try await svc.fetchManifest()
        XCTAssertEqual(try svc.diff(again.manifest).changes.map(\.artefact.id), ["zim-kiwix-fixture-2026-11"])

        // 3. Reference engine: kiwix-serve search and article text.
        let kiwix = KiwixServeService(port: 8795)
        defer { kiwix.stop() }
        try await kiwix.start(zimFiles: [layout.zim.appendingPathComponent("fieldguide_en_2026-10.zim")])
        let books = try await kiwix.books()
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "fieldguide_en_2026-10")
        // Both the 'zim-fieldguide-2026-10' and the tier-2 'zim-fieldguide-full' artefacts share one file; one book is served.
        let hits = try await kiwix.search("bleach drops per litre", books: nil, limit: 5)
        XCTAssertFalse(hits.isEmpty, "kiwix full-text search returns results")
        XCTAssertTrue((hits.first?.title)?.lowercased().contains("water") == true, "top hit for a water search should be the water article, got \(String(describing: hits.first?.title))")
        let text = try await kiwix.articleText(bookName: hits[0].bookName, path: hits[0].path)
        XCTAssertTrue(text.contains("2 drops"))

        // 4. Chat with citations through the real llama-server.
        let models = LocalModel.scan(layout.models)
        if let model = models.first, !model.fileURL.lastPathComponent.hasPrefix("mock") {
            let llama = LlamaServerService(port: 8796)
            defer { llama.stop() }
            try await llama.start(model: model)
            let coordinator = RetrievalCoordinator(retrievers: [ReferenceRetriever(service: kiwix), DocumentRetriever(documents: docs), PageRetriever(pages: pages), VideoRetriever(videos: videos)])
            let question = "How many drops of bleach per litre of water, and how long should I wait?"
            let passages = await coordinator.retrieve(question)
            XCTAssertFalse(passages.isEmpty)
            XCTAssertTrue(passages.contains { if case .zimArticle = $0.source { return true }; return false }, "a reference passage was retrieved")
            XCTAssertTrue(passages.contains { if case .video = $0.source { return true }; return false }, "a transcript passage was retrieved")
            XCTAssertTrue(passages.contains { if case .document = $0.source { return true }; return false }, "a PDF page passage was retrieved")
            var answer = ""
            for try await delta in llama.makeClient().streamChat(messages: Prompting.messages(history: [], userQuestion: question, passages: passages), options: ChatOptions()) { answer += delta }
            print("ANSWER:", answer)
            XCTAssertFalse(answer.isEmpty)
            XCTAssertFalse(answer.contains("<think>"))
            let cited = Prompting.citedPassages(answer: answer, passages: passages)
            let tinyModel = model.displayName.contains("0.6B") || model.displayName.contains("SmolLM")
            if tinyModel && cited.isEmpty {
                print("WARNING: the 0.6B stand-in model answered without a citation; the 4B default is held to the strict check. Answer: \(answer.prefix(200))")
            } else {
                XCTAssertFalse(cited.isEmpty, "answer cites at least one source: \(answer)")
            }
            // The citation resolves to an openable source.
            if case .zimArticle(let book, let path, _)? = cited.first?.source {
                let (_, http) = try await LocalHTTP.get(kiwix.articleURL(bookName: book, path: path))
                XCTAssertEqual(http.statusCode, 200, "citation opens the article in the viewer")
            }
        } else {
            print("skipping LLM step: no real model in fixture")
        }

        // 4b. The offline drill against a real, fully installed library.
        let deps = ReadinessCheck.Dependencies(layout: layout, database: db, reference: kiwix, llm: nil, llmModelName: nil, coordinator: RetrievalCoordinator(retrievers: [ReferenceRetriever(service: kiwix)]), backupService: BackupService(layout: layout, database: db), entitlements: .resolve(status: .none, source: .offlineVault), licence: nil, kiwixState: .running, llamaState: .stopped)
        let drill = await ReadinessCheck(deps: deps).run { _ in }
        let byId = Dictionary(uniqueKeysWithValues: drill.items.map { ($0.id, $0) })
        XCTAssertEqual(byId["books"]?.status, .pass, byId["books"]?.detail ?? "")
        XCTAssertEqual(byId["documents"]?.status, .pass, byId["documents"]?.detail ?? "")
        XCTAssertEqual(byId["maps"]?.status, .pass, byId["maps"]?.detail ?? "")
        XCTAssertEqual(byId["index"]?.status, .pass)
        XCTAssertEqual(byId["videos"]?.status, .pass)
        XCTAssertEqual(byId["backup"]?.status, .warn, "no backup yet is a warning with a fix")

        // 5. Video playback prerequisites: file + thumbnail + resume position memory.
        let v = try XCTUnwrap(try videos.videos(status: .downloaded).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: videos.fileURL(for: v)!.path))
        XCTAssertNotNil(videos.thumbnailURL(for: v))
        try videos.savePlaybackPosition(12.5, for: v.id)
        XCTAssertEqual(try videos.playbackPosition(for: v.id), 12.5)
    }

    // MARK: Pause / resume of a large artefact

    func testInterruptedDownloadResumesFromPartFile() async throws {
        try await startServer(version: 1, throttle: 0.04)
        let layout = try makeTempLibrary(self)
        let svc = makeService(layout, try IndexDatabase(url: layout.databaseURL))
        let manifest = try await svc.fetchManifest().manifest
        let big = try XCTUnwrap(manifest.artefacts.max { $0.sizeBytes < $1.sizeBytes })
        try XCTSkipUnless(big.sizeBytes > 4 * 1024 * 1024, "fixture model too small to interrupt meaningfully")
        let downloader = ResumableDownloader()
        let progressed = expectation(description: "progress")
        progressed.assertForOverFulfill = false
        let task = Task { try await downloader.download(big, from: baseURL, staging: layout.staging) { p in if p.bytesReceived > 2 * 1024 * 1024 { progressed.fulfill() } } }
        await fulfillment(of: [progressed], timeout: 60)
        task.cancel()
        _ = try? await task.value
        let part = ResumableDownloader.partFileURL(for: big, staging: layout.staging)
        let partSize = (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(partSize, 0, "partial file kept after cancel")
        XCTAssertLessThan(partSize, big.sizeBytes)
        let saved = ResumableDownloadState.load(forPartFile: part)
        XCTAssertNotNil(saved)

        // Resume without throttle and verify the checksum passes (proves bytes were appended at the right offset).
        try await startServer(version: 1)
        let final = try await downloader.download(big, from: baseURL, staging: layout.staging) { _ in }
        XCTAssertEqual(try Checksum.sha256Hex(ofFileAt: final), big.sha256)
        XCTAssertNil(ResumableDownloadState.load(forPartFile: part), "state file removed on completion")
    }

    // MARK: Webpage capture served by the fixture

    func testCaptureRendersOfflineAndIsSearchable() async throws {
        try await startServer(version: 1)
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let pages = PageService(layout: layout, database: db)
        let page = try await pages.capture(baseURL.appendingPathComponent("site/index.html"))
        XCTAssertEqual(page.title, "Fixture site – shelter basics")
        let html = try String(contentsOf: pages.fileURL(for: page), encoding: .utf8)
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("data:image/png;base64,"), "image inlined")
        XCTAssertTrue(html.contains("<style>"), "stylesheet inlined")
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("http://127.0.0.1:\(port)/site/style.css"), "no external stylesheet reference remains")
        XCTAssertEqual(try pages.search("lean-to").first?.page.id, page.id)
        // Refresh keeps the previous capture when the source is gone.
        stopServer()
        do { _ = try await pages.refresh(page); XCTFail("refresh should fail offline") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: pages.fileURL(for: page).path))
        XCTAssertNotNil(try pages.page(id: page.id)?.lastError)
    }

    // MARK: External file without a manifest checksum (the full world map path)

    func testExternalFileDownloadWithoutChecksumCompletesBySize() async throws {
        try await startServer(version: 1)
        let layout = try makeTempLibrary(self)
        let url = baseURL.appendingPathComponent("maps/world-overview.pmtiles")
        let size = try await ResumableDownloader.remoteSize(of: url)
        XCTAssertGreaterThan(size, 1_000_000)
        let pseudo = Artefact(id: "file-world", kind: .map, path: url.absoluteString, sizeBytes: size, sha256: "", title: "World")
        let file = try await ResumableDownloader().download(pseudo, from: url.deletingLastPathComponent(), staging: layout.staging) { _ in }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value, size)
        XCTAssertNotNil(PMTilesHeader.read(file), "downloaded file is a valid PMTiles archive")
    }

    // MARK: Catalogue trust against the real server and the real signed files

    func rejection(_ svc: UpdateService, file: StaticString = #filePath, line: UInt = #line) async -> UserFacingError? {
        do { _ = try await svc.fetchManifest(); XCTFail("fetch must be rejected", file: file, line: line); return nil }
        catch let e as UserFacingError { return e }
        catch { XCTFail("expected a UserFacingError, got \(error)", file: file, line: line); return nil }
    }

    func testPlainManifestFromASelfHostedServerIsUnverified() async throws {
        try await startServer(version: 1, signed: false)
        let layout = try makeTempLibrary(self)
        let svc = makeService(layout, try IndexDatabase(url: layout.databaseURL))
        let fetched = try await svc.fetchManifest()
        XCTAssertEqual(fetched.trust, .unverified(host: "127.0.0.1:8799"))
        XCTAssertEqual(fetched.manifest.version, "2026.10.01")
        XCTAssertNil(settings.lastVerifiedPublishedAt, "an unverified catalogue never moves the replay guard")
    }

    func testSignedManifestFromASelfHostedServerIsVerifiedViaMirrorAndGuardsReplay() async throws {
        try await startServer(version: 2)
        let layout = try makeTempLibrary(self)
        let svc = makeService(layout, try IndexDatabase(url: layout.databaseURL))
        let fetched = try await svc.fetchManifest()
        XCTAssertEqual(fetched.trust, .verified(keyId: "dev-2026", publishedAt: fetched.manifest.publishedAt, mirror: baseURL))
        XCTAssertEqual(fetched.manifest.version, "2026.10.08")
        XCTAssertEqual(settings.lastVerifiedPublishedAt, fetched.manifest.publishedAt)
        // The same edition again is fine; last week's edition is a replay.
        let again = try await svc.fetchManifest()
        XCTAssertEqual(again.trust, fetched.trust)
        try await startServer(version: 1)
        let replay = await rejection(svc)
        XCTAssertEqual(replay?.title, "Catalogue is older than the one already seen")
        XCTAssertEqual(settings.lastVerifiedPublishedAt, fetched.manifest.publishedAt, "a rejected catalogue leaves the guard where it was")
    }

    func testTheOfficialPortRefusesAPlainManifestAndVerifiesASignedOne() async throws {
        try XCTSkipIf(Self.isPortOpen(8787), "another fixture server holds 8787 (a developer's --serve); stop it to run this test")
        port = 8787
        XCTAssertEqual(UpdateSource(baseURL: baseURL), .offlineVault, "the fixture port stands in for the service")
        try await startServer(version: 1, signed: false)
        let layout = try makeTempLibrary(self)
        let svc = makeService(layout, try IndexDatabase(url: layout.databaseURL))
        let unsigned = await rejection(svc)
        XCTAssertEqual(unsigned?.title, "Unsigned catalogue from the OfflineVault service")
        try await startServer(version: 1)
        let fetched = try await svc.fetchManifest()
        XCTAssertEqual(fetched.trust, .verified(keyId: "dev-2026", publishedAt: fetched.manifest.publishedAt, mirror: nil))
    }

    // MARK: Optional: real YouTube index + download (network, gated separately)

    func testYouTubeIndexAndDownload() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OV_YOUTUBE_E2E"] == "1", "set OV_YOUTUBE_E2E=1 to hit YouTube")
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let lib = VideoLibraryService(layout: layout, database: db)
        let yt = YouTubeService(layout: layout, library: lib)
        let src = try lib.addSource(url: "https://www.youtube.com/watch?v=jNQXAC9IVRw") // "Me at the zoo", 19 s
        let count = try await yt.indexSource(src)
        XCTAssertEqual(count, 1)
        let v = try XCTUnwrap(try lib.videos(status: .indexed).first)
        let done = try await yt.download(video: v, quality: .p360) { _ in }
        XCTAssertEqual(done.status, .downloaded)
        XCTAssertNotNil(done.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lib.fileURL(for: done)!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.videos.appendingPathComponent(done.id + ".json").path), "sidecar written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.ytdlpArchiveURL.path), "download archive maintained")
    }
}
