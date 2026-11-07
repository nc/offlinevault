import Foundation
import CryptoKit

public enum Checksum {
    /// Streams the file through SHA-256 and returns lower-case hex.
    public static func sha256Hex(ofFileAt url: URL, bufferSize: Int = 4 * 1024 * 1024, progress: ((Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: bufferSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
            progress?(total)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies the file matches `expectedHex` (case-insensitive). Throws a user-facing error on mismatch.
    public static func verify(fileAt url: URL, expectedHex: String, label: String, progress: ((Int64) -> Void)? = nil) throws {
        let actual = try sha256Hex(ofFileAt: url, progress: progress)
        guard actual == expectedHex.lowercased() else {
            throw UserFacingError("Checksum mismatch",
                                  message: "\(label) did not match the checksum published in the manifest. The download is corrupt or the service is mid-publish.",
                                  recovery: "The partial file has been discarded. Check for updates again to retry the download.")
        }
    }
}
