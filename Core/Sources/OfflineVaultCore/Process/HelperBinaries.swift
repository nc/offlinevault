import Foundation

/// Locates the bundled helper executables. Resolution order:
///   1. `OFFLINEVAULT_BIN_DIR` environment variable (development)
///   2. `<app bundle>/Contents/Resources/bin` (what scripts/fetch_binaries.sh populates)
///   3. For ffmpeg / yt-dlp only: a system install on PATH (Homebrew), flagged as `isSystemFallback`.
public enum HelperBinary: String, CaseIterable, Sendable {
    case kiwixServe = "kiwix-serve"
    case llamaServer = "llama-server"
    case ytDlp = "yt-dlp"
    case ffmpeg = "ffmpeg"

    public var title: String {
        switch self {
        case .kiwixServe: return "kiwix-serve (reference library)"
        case .llamaServer: return "llama-server (local AI)"
        case .ytDlp: return "yt-dlp (video indexer/downloader)"
        case .ffmpeg: return "ffmpeg (media processing)"
        }
    }

    /// Relative path inside the bin folder.
    var relativePath: String {
        switch self {
        case .llamaServer: return "llama/llama-server"
        default: return rawValue
        }
    }

    public struct Location: Equatable, Sendable {
        public let url: URL
        public let isSystemFallback: Bool
    }

    public static var bundledBinDirectory: URL? {
        if let env = ProcessInfo.processInfo.environment["OFFLINEVAULT_BIN_DIR"], !env.isEmpty { return URL(fileURLWithPath: env, isDirectory: true) }
        if let res = Bundle.main.resourceURL {
            let bin = res.appendingPathComponent("bin", isDirectory: true)
            if FileManager.default.fileExists(atPath: bin.path) { return bin }
        }
        return nil
    }

    public func locate() -> Location? {
        let fm = FileManager.default
        if let dir = Self.bundledBinDirectory {
            let candidate = dir.appendingPathComponent(relativePath)
            if fm.isExecutableFile(atPath: candidate.path) { return Location(url: candidate, isSystemFallback: false) }
        }
        if self == .ffmpeg || self == .ytDlp {
            for p in ["/opt/homebrew/bin", "/usr/local/bin"] {
                let c = URL(fileURLWithPath: p).appendingPathComponent(rawValue)
                if fm.isExecutableFile(atPath: c.path) { return Location(url: c, isSystemFallback: true) }
            }
        }
        return nil
    }

    public func require() throws -> URL {
        guard let loc = locate() else {
            throw UserFacingError("\(rawValue) is missing", message: "The helper program \(rawValue) is not bundled with this build.", recovery: "Run scripts/fetch_binaries.sh and rebuild, or reinstall OfflineVault.")
        }
        return loc.url
    }

    /// Arguments needed to run this binary (kiwix-serve ships only as x86_64 → explicitly run under Rosetta via /usr/bin/arch).
    public static func launchCommand(for url: URL) -> (executable: URL, prefixArguments: [String]) {
        if MachO.architectures(of: url).contains("x86_64") && !MachO.architectures(of: url).contains("arm64") && MachO.isAppleSilicon {
            return (URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", url.path])
        }
        return (url, [])
    }
}

/// Minimal Mach-O header sniffing so we know whether a helper needs Rosetta.
public enum MachO {
    public static var isAppleSilicon: Bool {
        var sysinfo = utsname(); uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        return machine.hasPrefix("arm64")
    }

    public static func architectures(of url: URL) -> Set<String> {
        guard let h = try? FileHandle(forReadingFrom: url), let head = try? h.read(upToCount: 4096) else { return [] }
        try? h.close()
        guard head.count >= 8 else { return [] }
        func u32(_ o: Int, big: Bool) -> UInt32 {
            let b = head[head.startIndex + o ..< head.startIndex + o + 4]
            let v = b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return big ? v : v.byteSwapped
        }
        let magic = u32(0, big: true)
        func arch(_ cputype: UInt32) -> String? {
            switch cputype & 0x00FF_FFFF { case 7: return "x86_64"; case 12: return "arm64"; default: return nil }
        }
        switch magic {
        case 0xCAFE_BABE: // fat, big-endian
            let n = Int(u32(4, big: true)); var set = Set<String>()
            for i in 0..<min(n, 8) { let off = 8 + i * 20; if off + 4 <= head.count, let a = arch(u32(off, big: true)) { set.insert(a) } }
            return set
        case 0xFEED_FACF: return arch(u32(4, big: true)).map { [$0] } ?? []  // 64-bit big-endian
        case 0xCFFA_EDFE: return arch(u32(4, big: false)).map { [$0] } ?? []  // 64-bit little-endian (normal on macOS)
        default: return []
        }
    }
}
