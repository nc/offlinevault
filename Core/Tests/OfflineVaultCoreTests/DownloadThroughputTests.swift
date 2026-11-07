import XCTest
@testable import OfflineVaultCore

/// A 256 MB file from a local server must arrive at disk speed, not at the few MB/s a byte-at-a-time loop managed.
final class DownloadThroughputTests: XCTestCase {
    func testLocalDownloadRunsAtTensOfMegabytesPerSecondAndVerifies() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ov-throughput-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = 256 << 20
        let random = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/urandom"))
        let payload = try XCTUnwrap(try random.read(upToCount: size))
        try payload.write(to: dir.appendingPathComponent("big.bin"))
        let sha = try Checksum.sha256Hex(ofFileAt: dir.appendingPathComponent("big.bin"))

        let port = 8700 + Int.random(in: 0..<200)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", dir.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        for _ in 0..<50 {
            if (try? await URLSession.shared.data(from: base)) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let artefact = Artefact(id: "big", kind: .zim, path: "big.bin", sizeBytes: Int64(size), sha256: sha)
        let staging = dir.appendingPathComponent("staging")
        let started = Date()
        let out = try await ResumableDownloader().download(artefact, from: base, staging: staging, progress: { _ in })
        let seconds = Date().timeIntervalSince(started)
        let mbps = Double(size) / 1_048_576 / seconds
        XCTAssertEqual(try Checksum.sha256Hex(ofFileAt: out), sha)
        XCTAssertGreaterThan(mbps, 40, "downloaded 256 MB in \(String(format: "%.1f", seconds)) s (\(String(format: "%.0f", mbps)) MB/s); the delegate path should manage far more than 40 MB/s from localhost")
        print("throughput: \(String(format: "%.0f", mbps)) MB/s over localhost")
    }
}
