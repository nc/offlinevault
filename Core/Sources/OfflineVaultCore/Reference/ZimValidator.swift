import Foundation

/// Cheap structural check of a ZIM file so one damaged book cannot take down kiwix-serve (which exits if any
/// file fails to load). Reads the 80-byte header, checks the magic number and that the recorded pointer-list
/// offsets lie inside the file.
public enum ZimValidator {
    public enum Verdict: Equatable, Sendable {
        case ok
        case damaged(String)
        public var isOK: Bool { self == .ok }
    }

    static let magic: UInt32 = 72173914 // "ZIM\x04" little-endian

    public static func validate(_ url: URL) -> Verdict {
        guard let h = try? FileHandle(forReadingFrom: url) else { return .damaged("cannot be opened") }
        defer { try? h.close() }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init), size > 80 else { return .damaged("file is empty or truncated") }
        guard let head = try? h.read(upToCount: 80), head.count == 80 else { return .damaged("header could not be read") }
        func u32(_ o: Int) -> UInt32 { head[o..<o+4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        func u64(_ o: Int) -> UInt64 { head[o..<o+8].reversed().reduce(0) { $0 << 8 | UInt64($1) } }
        guard u32(0) == magic else { return .damaged("not a ZIM file (bad magic number)") }
        let entryCount = u32(24), clusterCount = u32(28)
        let pathPtr = u64(32), titlePtr = u64(40), clusterPtr = u64(48), mimePtr = u64(56)
        guard entryCount > 0, clusterCount > 0 else { return .damaged("header reports no articles") }
        // titlePtrPos is unused (all 0xFF) in ZIM minor version ≥ 1, where the title index lives in a listing entry.
        var pointers = [("path index", pathPtr), ("cluster index", clusterPtr), ("MIME list", mimePtr)]
        if titlePtr != UInt64.max { pointers.append(("title index", titlePtr)) }
        for (name, p) in pointers where p >= size {
            return .damaged("\(name) points past the end of the file (truncated download?)")
        }
        // The file ends with a 16-byte MD5 of everything before it; make sure the checksum block is really there.
        let checksumPos = u64(72)
        guard checksumPos + 16 == size else { return .damaged("checksum block missing — the file is truncated or was changed") }
        return .ok
    }

    /// Parses kiwix-serve's startup complaint so the offending file can be excluded and the rest still served.
    public static func failedFile(inKiwixOutput output: String) -> String? {
        guard let r = output.range(of: "Unable to add the ZIM file '") else { return nil }
        let rest = output[r.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<end])
    }
}
