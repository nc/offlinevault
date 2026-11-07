import XCTest
@testable import OfflineVaultCore

final class ChecksumTests: XCTestCase {
    func testSHA256OfKnownData() throws {
        XCTAssertEqual(Checksum.sha256Hex(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Checksum.sha256Hex(of: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testStreamingFileHashMatchesInMemoryHash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var data = Data(count: 5 * 1024 * 1024 + 123)
        data.withUnsafeMutableBytes { buf in for i in 0..<buf.count { buf[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) } }
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var reported: Int64 = 0
        let hex = try Checksum.sha256Hex(ofFileAt: url, bufferSize: 64 * 1024) { reported = $0 }
        XCTAssertEqual(hex, Checksum.sha256Hex(of: data))
        XCTAssertEqual(reported, Int64(data.count))
    }

    func testVerifyThrowsUserFacingErrorOnMismatch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try Checksum.verify(fileAt: url, expectedHex: Checksum.sha256Hex(of: Data("hello".utf8)).uppercased(), label: "x"))
        XCTAssertThrowsError(try Checksum.verify(fileAt: url, expectedHex: String(repeating: "0", count: 64), label: "Field Guide")) { error in
            let uf = error as? UserFacingError
            XCTAssertEqual(uf?.title, "Checksum mismatch")
            XCTAssertTrue(uf?.message.contains("Field Guide") ?? false)
            XCTAssertNotNil(uf?.recovery)
        }
    }
}
