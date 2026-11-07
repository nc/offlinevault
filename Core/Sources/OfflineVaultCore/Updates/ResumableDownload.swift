import Foundation

/// Persisted alongside a `.part` file so an interrupted download can be resumed after a relaunch.
public struct ResumableDownloadState: Codable, Equatable, Sendable {
    public var sourceURL: URL
    public var expectedSize: Int64
    public var expectedSHA256: String
    public var bytesReceived: Int64
    public var etag: String?
    public var lastModified: String?
    public var updatedAt: Date

    public init(sourceURL: URL, expectedSize: Int64, expectedSHA256: String, bytesReceived: Int64 = 0, etag: String? = nil, lastModified: String? = nil, updatedAt: Date = Date()) {
        self.sourceURL = sourceURL; self.expectedSize = expectedSize; self.expectedSHA256 = expectedSHA256
        self.bytesReceived = bytesReceived; self.etag = etag; self.lastModified = lastModified; self.updatedAt = updatedAt
    }

    public static func stateURL(forPartFile part: URL) -> URL { part.appendingPathExtension("state.json") }

    public func save(forPartFile part: URL) throws {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try e.encode(self).write(to: Self.stateURL(forPartFile: part), options: .atomic)
    }

    public static func load(forPartFile part: URL) -> ResumableDownloadState? {
        guard let data = try? Data(contentsOf: stateURL(forPartFile: part)) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(ResumableDownloadState.self, from: data)
    }

    public static func discard(forPartFile part: URL) {
        try? FileManager.default.removeItem(at: stateURL(forPartFile: part))
        try? FileManager.default.removeItem(at: part)
    }

    /// Reconcile persisted state with the actual `.part` file on disk. The file is the source of truth for byte count;
    /// if the file is larger than expected, or the recorded source no longer matches, start over.
    public static func reconcile(saved: ResumableDownloadState?, partFileSize: Int64?, artefact: Artefact, sourceURL: URL) -> ResumableDownloadState {
        var fresh = ResumableDownloadState(sourceURL: sourceURL, expectedSize: artefact.sizeBytes, expectedSHA256: artefact.sha256)
        guard var s = saved, let size = partFileSize else { return fresh }
        guard s.sourceURL == sourceURL, s.expectedSHA256.lowercased() == artefact.sha256.lowercased(), s.expectedSize == artefact.sizeBytes else { return fresh }
        guard size <= artefact.sizeBytes else { return fresh }
        s.bytesReceived = size
        if size == 0 { fresh.etag = nil; return fresh }
        return s
    }
}

/// Pure decision logic for how to treat a server response when resuming — unit-tested separately from networking.
public enum ResumeDecision: Equatable, Sendable {
    /// Server honoured the range: append from `offset`.
    case append(fromOffset: Int64)
    /// Server ignored the range (200) or the file changed: truncate and start over.
    case restart
    /// Range not satisfiable and we already have every byte: go straight to verification.
    case alreadyComplete
    case fail(String)

    public static func decide(statusCode: Int, requestedOffset: Int64, expectedSize: Int64, contentRange: String?, etag: String?, savedEtag: String?) -> ResumeDecision {
        switch statusCode {
        case 206:
            if let saved = savedEtag, let etag, saved != etag { return .restart }
            guard let cr = contentRange, let start = parseContentRangeStart(cr) else { return requestedOffset == 0 ? .restart : .fail("Server returned a partial response without a Content-Range header.") }
            if start != requestedOffset { return .restart }
            return .append(fromOffset: start)
        case 200:
            return .restart
        case 416:
            return requestedOffset >= expectedSize && expectedSize > 0 ? .alreadyComplete : .restart
        case 404:
            return .fail("The file is not on the update server (404). The manifest and the published files may be out of sync.")
        case 401, 403:
            return .fail("The update server refused the download (HTTP \(statusCode)).")
        default:
            return .fail("Unexpected server response (HTTP \(statusCode)).")
        }
    }

    /// Parses "bytes 1000-4999/5000" → 1000
    public static func parseContentRangeStart(_ header: String) -> Int64? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
        let rest = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return Int64(rest[rest.startIndex..<dash])
    }
}

public struct DownloadProgress: Equatable, Sendable {
    public var bytesReceived: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double
    public var fraction: Double { totalBytes > 0 ? min(1, Double(bytesReceived) / Double(totalBytes)) : 0 }
    public init(bytesReceived: Int64, totalBytes: Int64, bytesPerSecond: Double = 0) {
        self.bytesReceived = bytesReceived; self.totalBytes = totalBytes; self.bytesPerSecond = bytesPerSecond
    }
}

/// Downloads a single artefact into `<staging>/<fileName>.part` with HTTP range resumption and verifies it.
/// Cancel the surrounding Task to pause: the `.part` file and its state are kept for the next attempt.
public actor ResumableDownloader {
    public let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 60
            cfg.timeoutIntervalForResource = 60 * 60 * 24
            cfg.waitsForConnectivity = true
            self.session = URLSession(configuration: cfg)
        }
    }

    public static func partFileURL(for artefact: Artefact, staging: URL) -> URL {
        staging.appendingPathComponent(artefact.id + "-" + artefact.fileName + ".part")
    }

    /// Size of a remote file (HEAD, falling back to a zero-length range GET).
    public static func remoteSize(of url: URL) async throws -> Int64 {
        var req = URLRequest(url: url); req.httpMethod = "HEAD"; req.timeoutInterval = 30
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 200, let len = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), len > 0 { return len }
        var get = URLRequest(url: url); get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, r2) = try await URLSession.shared.data(for: get)
        if let http = r2 as? HTTPURLResponse, let cr = http.value(forHTTPHeaderField: "Content-Range"), let total = cr.split(separator: "/").last.flatMap({ Int64($0) }) { return total }
        throw UserFacingError("Could not read file size", message: "The server did not report the size of \(url.lastPathComponent).")
    }

    /// Returns the URL of the fully downloaded, checksum-verified file (still inside staging).
    public func download(_ artefact: Artefact, from baseURL: URL, staging: URL, progress: @escaping @Sendable (DownloadProgress) -> Void, verifyProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let source = artefact.url(relativeTo: baseURL)
        let part = Self.partFileURL(for: artefact, staging: staging)
        let fm = FileManager.default

        var attempt = 0
        while true {
            attempt += 1
            let partSize = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value
            var state = ResumableDownloadState.reconcile(saved: ResumableDownloadState.load(forPartFile: part), partFileSize: partSize, artefact: artefact, sourceURL: source)
            if state.bytesReceived == 0 || partSize == nil { try? fm.removeItem(at: part); fm.createFile(atPath: part.path, contents: nil) }

            if state.bytesReceived >= artefact.sizeBytes && artefact.sizeBytes > 0 {
                return try finish(part: part, artefact: artefact, verifyProgress: verifyProgress)
            }

            var request = URLRequest(url: source)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if state.bytesReceived > 0 { request.setValue("bytes=\(state.bytesReceived)-", forHTTPHeaderField: "Range") }

            let body = ChunkedBody(configuration: session.configuration)
            let response: URLResponse
            do { response = try await body.start(request) } catch { body.cancel(); throw error }
            guard let http = response as? HTTPURLResponse else { body.cancel(); throw UserFacingError("Download failed", message: "The server returned a non-HTTP response.") }
            let decision = ResumeDecision.decide(statusCode: http.statusCode, requestedOffset: state.bytesReceived, expectedSize: artefact.sizeBytes,
                                                 contentRange: http.value(forHTTPHeaderField: "Content-Range"), etag: http.value(forHTTPHeaderField: "ETag"), savedEtag: state.etag)
            var offset: Int64
            switch decision {
            case .append(let o): offset = o
            case .restart:
                try? fm.removeItem(at: part); fm.createFile(atPath: part.path, contents: nil)
                offset = 0
                state.bytesReceived = 0
                if http.statusCode == 416 || http.statusCode == 206 {
                    // Range confusion: retry once from scratch with a clean request.
                    body.cancel()
                    guard attempt < 3 else { throw UserFacingError("Download failed", message: "The server kept returning inconsistent range responses for \(artefact.displayTitle).", recovery: "Try again later.") }
                    ResumableDownloadState.discard(forPartFile: part)
                    continue
                }
            case .alreadyComplete:
                body.cancel()
                return try finish(part: part, artefact: artefact, verifyProgress: verifyProgress)
            case .fail(let msg):
                body.cancel()
                throw UserFacingError("Download failed", message: "\(artefact.displayTitle): \(msg)", recovery: "Check for updates again later.")
            }
            state.etag = http.value(forHTTPHeaderField: "ETag")
            state.lastModified = http.value(forHTTPHeaderField: "Last-Modified")

            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))

            var received = offset
            var lastReport = Date(); var lastReportBytes = received
            var lastSave = Date()
            progress(DownloadProgress(bytesReceived: received, totalBytes: artefact.sizeBytes))
            do {
                for try await chunk in body.chunks {
                    try handle.write(contentsOf: chunk); received += Int64(chunk.count)
                    body.consumed(chunk.count)
                    let now = Date()
                    if now.timeIntervalSince(lastReport) >= 0.25 {
                        let rate = Double(received - lastReportBytes) / now.timeIntervalSince(lastReport)
                        progress(DownloadProgress(bytesReceived: received, totalBytes: artefact.sizeBytes, bytesPerSecond: rate))
                        lastReport = now; lastReportBytes = received
                    }
                    if now.timeIntervalSince(lastSave) >= 2 { state.bytesReceived = received; state.updatedAt = now; try? state.save(forPartFile: part); lastSave = now }
                    if received > artefact.sizeBytes && artefact.sizeBytes > 0 {
                        throw UserFacingError("Download failed", message: "\(artefact.displayTitle) is larger than the manifest says. The service may be mid-publish.", recovery: "Check for updates again later.")
                    }
                }
            } catch {
                body.cancel()
                state.bytesReceived = received; state.updatedAt = Date(); try? state.save(forPartFile: part)
                throw error
            }
            state.bytesReceived = received; try? state.save(forPartFile: part)
            progress(DownloadProgress(bytesReceived: received, totalBytes: artefact.sizeBytes))
            try handle.close()
            if received < artefact.sizeBytes {
                // Connection closed early: loop and resume.
                guard attempt < 20 else { throw UserFacingError("Download failed", message: "The connection kept dropping while downloading \(artefact.displayTitle).", recovery: "Resume the download when you have a stable connection.") }
                continue
            }
            return try finish(part: part, artefact: artefact, verifyProgress: verifyProgress)
        }
    }

    private func finish(part: URL, artefact: Artefact, verifyProgress: (@Sendable (Double) -> Void)?) throws -> URL {
        try Self.verified(part: part, artefact: artefact, verifyProgress: verifyProgress)
    }

    /// The complete `.part` file, checked against the manifest's sha256, or discarded. A mismatch on a file that
    /// came from Kiwix is reported as Kiwix's problem; one from the catalogue as a corrupt download.
    static func verified(part: URL, artefact: Artefact, verifyProgress: (@Sendable (Double) -> Void)?) throws -> URL {
        // Files without a checksum (e.g. the Protomaps planet build) are complete when their size is.
        guard !artefact.sha256.isEmpty else {
            try? FileManager.default.removeItem(at: ResumableDownloadState.stateURL(forPartFile: part))
            return part
        }
        do {
            let total = Double(max(artefact.sizeBytes, 1))
            try Checksum.verify(fileAt: part, expectedHex: artefact.sha256, label: artefact.displayTitle) { done in verifyProgress?(min(1, Double(done) / total)) }
        } catch {
            ResumableDownloadState.discard(forPartFile: part)
            // Checksum.verify throws a UserFacingError only for a mismatch; anything else is an I/O failure.
            if let external = artefact.external, error is UserFacingError { throw external.checksumMismatch(label: artefact.displayTitle) }
            throw error
        }
        try? FileManager.default.removeItem(at: ResumableDownloadState.stateURL(forPartFile: part))
        return part
    }
}
