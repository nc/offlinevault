import XCTest
@testable import OfflineVaultCore

final class ResumableDownloadTests: XCTestCase {
    let sha = String(repeating: "a", count: 64)
    lazy var artefact = Artefact(id: "x", kind: .zim, path: "zim/x.zim", sizeBytes: 10_000, sha256: sha)
    let source = URL(string: "http://127.0.0.1:8787/zim/x.zim")!

    func testResumeDecisions() {
        XCTAssertEqual(ResumeDecision.decide(statusCode: 206, requestedOffset: 4000, expectedSize: 10_000, contentRange: "bytes 4000-9999/10000", etag: "\"e1\"", savedEtag: "\"e1\""), .append(fromOffset: 4000))
        XCTAssertEqual(ResumeDecision.decide(statusCode: 206, requestedOffset: 4000, expectedSize: 10_000, contentRange: "bytes 0-9999/10000", etag: nil, savedEtag: nil), .restart, "server ignored our offset")
        XCTAssertEqual(ResumeDecision.decide(statusCode: 206, requestedOffset: 4000, expectedSize: 10_000, contentRange: "bytes 4000-9999/10000", etag: "\"new\"", savedEtag: "\"old\""), .restart, "file changed on server")
        XCTAssertEqual(ResumeDecision.decide(statusCode: 200, requestedOffset: 4000, expectedSize: 10_000, contentRange: nil, etag: nil, savedEtag: nil), .restart)
        XCTAssertEqual(ResumeDecision.decide(statusCode: 416, requestedOffset: 10_000, expectedSize: 10_000, contentRange: nil, etag: nil, savedEtag: nil), .alreadyComplete)
        XCTAssertEqual(ResumeDecision.decide(statusCode: 416, requestedOffset: 500, expectedSize: 10_000, contentRange: nil, etag: nil, savedEtag: nil), .restart)
        if case .fail = ResumeDecision.decide(statusCode: 404, requestedOffset: 0, expectedSize: 10_000, contentRange: nil, etag: nil, savedEtag: nil) {} else { XCTFail("404 must fail") }
        XCTAssertEqual(ResumeDecision.parseContentRangeStart("bytes 1000-4999/5000"), 1000)
        XCTAssertNil(ResumeDecision.parseContentRangeStart("items 1-2/3"))
    }

    func testAMismatchedExternalFileIsAKiwixProblemAndAMismatchedCatalogueFileIsNot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("not what was published".utf8)
        let external = Artefact(id: "zim-ifixit", kind: .zim, path: "zim/ifixit.zim", sizeBytes: Int64(bytes.count), sha256: sha, title: "iFixit",
                                external: ExternalSource(url: URL(string: "https://download.kiwix.org/zim/ifixit/ifixit.zim")!, shaSource: "kiwix-meta4"))
        for (art, title) in [(external, "Kiwix download did not match"), (artefact, "Checksum mismatch")] {
            let part = ResumableDownloader.partFileURL(for: art, staging: dir)
            try bytes.write(to: part)
            try ResumableDownloadState(sourceURL: art.url(relativeTo: source), expectedSize: art.sizeBytes, expectedSHA256: art.sha256).save(forPartFile: part)
            XCTAssertThrowsError(try ResumableDownloader.verified(part: part, artefact: art, verifyProgress: nil)) { XCTAssertEqual(($0 as? UserFacingError)?.title, title) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), "the mismatched file is discarded either way")
            XCTAssertNil(ResumableDownloadState.load(forPartFile: part))
        }
        let good = Artefact(id: "ok", kind: .zim, path: "zim/ok.zim", sizeBytes: Int64(bytes.count), sha256: Checksum.sha256Hex(of: bytes),
                            external: ExternalSource(url: URL(string: "https://download.kiwix.org/zim/ok.zim")!, shaSource: "kiwix-meta4"))
        let part = ResumableDownloader.partFileURL(for: good, staging: dir)
        try bytes.write(to: part)
        XCTAssertEqual(try ResumableDownloader.verified(part: part, artefact: good, verifyProgress: nil), part)
    }

    func testStateRoundTripAndReconcile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let part = ResumableDownloader.partFileURL(for: artefact, staging: dir)
        try Data(count: 4000).write(to: part)
        var state = ResumableDownloadState(sourceURL: source, expectedSize: 10_000, expectedSHA256: sha, bytesReceived: 3500, etag: "\"e1\"")
        try state.save(forPartFile: part)
        let loaded = ResumableDownloadState.load(forPartFile: part)
        XCTAssertEqual(loaded?.etag, "\"e1\"")

        // The file on disk is authoritative for bytesReceived.
        let r = ResumableDownloadState.reconcile(saved: loaded, partFileSize: 4000, artefact: artefact, sourceURL: source)
        XCTAssertEqual(r.bytesReceived, 4000)
        XCTAssertEqual(r.etag, "\"e1\"")

        // A different artefact checksum means a different file: start over.
        var changed = artefact; changed.sha256 = String(repeating: "b", count: 64)
        XCTAssertEqual(ResumableDownloadState.reconcile(saved: loaded, partFileSize: 4000, artefact: changed, sourceURL: source).bytesReceived, 0)
        // Oversized partial: start over.
        XCTAssertEqual(ResumableDownloadState.reconcile(saved: loaded, partFileSize: 20_000, artefact: artefact, sourceURL: source).bytesReceived, 0)
        // No saved state: fresh.
        state = ResumableDownloadState.reconcile(saved: nil, partFileSize: 4000, artefact: artefact, sourceURL: source)
        XCTAssertEqual(state.bytesReceived, 0)
        ResumableDownloadState.discard(forPartFile: part)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    }

    func testDownloadProgressFraction() {
        XCTAssertEqual(DownloadProgress(bytesReceived: 50, totalBytes: 200).fraction, 0.25)
        XCTAssertEqual(DownloadProgress(bytesReceived: 50, totalBytes: 0).fraction, 0)
    }
}
