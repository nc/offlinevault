import Foundation
import Compression

/// One offline map region (a PMTiles archive in `maps/`).
public struct OfflineMap: Equatable, Sendable, Identifiable, Hashable {
    public var fileURL: URL
    public var name: String
    public var sizeBytes: Int64
    public var header: PMTilesHeader?
    public var id: String { fileURL.lastPathComponent }
    public var title: String { header?.name ?? fileURL.deletingPathExtension().lastPathComponent }
    public var schemaVersion: String? { header?.version }
}

/// Reads the fixed 127-byte PMTiles v3 header plus the (gzipped JSON) metadata: enough to list regions, centre
/// the map and pick a style matching the tile schema.
public struct PMTilesHeader: Equatable, Sendable, Hashable {
    public var minLon: Double, minLat: Double, maxLon: Double, maxLat: Double
    public var centerLon: Double, centerLat: Double
    public var minZoom: Int, maxZoom: Int, centerZoom: Int
    public var tileType: String
    public var name: String?
    public var attribution: String?
    public var description: String?
    /// Protomaps tile-schema version (e.g. "3.7.1" or "4.x"), from metadata `version`.
    public var version: String?

    public static func read(_ url: URL) -> PMTilesHeader? {
        guard let h = try? FileHandle(forReadingFrom: url), let head = try? h.read(upToCount: 127), head.count == 127 else { return nil }
        defer { try? h.close() }
        guard String(decoding: head[0..<7], as: UTF8.self) == "PMTiles", head[7] == 3 else { return nil }
        func u64(_ o: Int) -> UInt64 { head[o..<o+8].reversed().reduce(0) { $0 << 8 | UInt64($1) } }
        func i32(_ o: Int) -> Int32 { Int32(bitPattern: head[o..<o+4].reversed().reduce(0) { $0 << 8 | UInt32($1) }) }
        let metaOffset = u64(24), metaLength = u64(32)
        let internalCompression = head[97]
        let tileType: String = ["unknown", "mvt", "png", "jpeg", "webp", "avif"][Int(min(head[99], 5))]
        var hdr = PMTilesHeader(minLon: Double(i32(102)) / 1e7, minLat: Double(i32(106)) / 1e7, maxLon: Double(i32(110)) / 1e7, maxLat: Double(i32(114)) / 1e7,
                                centerLon: Double(i32(119)) / 1e7, centerLat: Double(i32(123)) / 1e7, minZoom: Int(head[100]), maxZoom: Int(head[101]), centerZoom: Int(head[118]), tileType: tileType)
        if metaLength > 0, metaLength < 50_000_000, (try? h.seek(toOffset: metaOffset)) != nil, let raw = try? h.read(upToCount: Int(metaLength)) {
            let json = internalCompression == 2 ? Self.gunzip(raw) : raw
            if let json, let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
                hdr.name = obj["name"] as? String; hdr.attribution = obj["attribution"] as? String; hdr.description = obj["description"] as? String; hdr.version = obj["version"] as? String
            }
        }
        return hdr
    }

    static func gunzip(_ data: Data) -> Data? {
        // Strip the gzip header (10 bytes + optional fields) and 8-byte trailer, inflate the raw deflate stream.
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b else { return nil }
        let flags = data[3]; var idx = 10
        if flags & 0x04 != 0 { let xlen = Int(data[idx]) | Int(data[idx+1]) << 8; idx += 2 + xlen }
        if flags & 0x08 != 0 { while idx < data.count && data[idx] != 0 { idx += 1 }; idx += 1 }
        if flags & 0x10 != 0 { while idx < data.count && data[idx] != 0 { idx += 1 }; idx += 1 }
        if flags & 0x02 != 0 { idx += 2 }
        guard idx < data.count - 8 else { return nil }
        let deflated = data[idx..<(data.count - 8)]
        let capacity = 16 * 1024 * 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            deflated.withUnsafeBytes { src -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity, src.bindMemory(to: UInt8.self).baseAddress!, deflated.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }
}

/// Lists map regions and serves byte ranges for the viewer's custom URL scheme.
public final class MapsService: @unchecked Sendable {
    public let layout: LibraryLayout
    public init(layout: LibraryLayout) { self.layout = layout }

    public func maps() -> [OfflineMap] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: layout.maps, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "pmtiles" }.map { f in
            OfflineMap(fileURL: f, name: f.lastPathComponent, sizeBytes: (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0, header: PMTilesHeader.read(f))
        }.sorted { $0.title < $1.title }
    }

    public func fileURL(named name: String) -> URL? {
        guard !name.contains("/"), !name.contains("..") else { return nil }
        let u = layout.maps.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Reads `range` from a map file (used by the WKURLSchemeHandler to answer HTTP Range requests from pmtiles.js).
    public func read(_ url: URL, range: Range<Int64>) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(range.lowerBound))
        return try h.read(upToCount: Int(range.upperBound - range.lowerBound)) ?? Data()
    }

    public func importMap(from source: URL) throws -> OfflineMap {
        try layout.ensureDirectories()
        guard source.pathExtension.lowercased() == "pmtiles", PMTilesHeader.read(source) != nil else {
            throw UserFacingError("Not a PMTiles file", message: "\(source.lastPathComponent) is not a PMTiles v3 archive.", recovery: "Create one with the pmtiles tool (see Settings › Maps) or download a region from the update service.")
        }
        let dest = layout.maps.appendingPathComponent(source.lastPathComponent)
        if dest.standardizedFileURL != source.standardizedFileURL {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: source, to: dest)
        }
        return maps().first { $0.fileURL == dest }!
    }

    public func delete(_ m: OfflineMap) { if (try? FileManager.default.trashItem(at: m.fileURL, resultingItemURL: nil)) == nil { try? FileManager.default.removeItem(at: m.fileURL) } }
}
