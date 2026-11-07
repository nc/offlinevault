import Foundation

/// One queued download: an update-service artefact or a user-chosen video.
public struct DownloadItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case artefact(ManifestDiff.Change, manifestVersion: String)
        case video(Video, quality: VideoQuality)
        /// A plain file from a URL without a manifest (e.g. the full-detail world map), saved under `destination`.
        case file(url: URL, destination: URL, sizeBytes: Int64)
    }
    public enum State: Equatable, Sendable {
        case queued, running, paused, completed
        case failed(UserFacingError)
        public var isActive: Bool { self == .running }
        public var label: String {
            switch self {
            case .queued: return "Queued"
            case .running: return "Downloading"
            case .paused: return "Paused"
            case .completed: return "Done"
            case .failed(let e): return e.title
            }
        }
    }
    public let id: String
    public let kind: Kind
    public let title: String
    public var state: State = .queued
    public var bytesReceived: Int64 = 0
    public var totalBytes: Int64
    public var bytesPerSecond: Double = 0
    public var statusText: String = ""
    public var createdAt = Date()

    public var fraction: Double { totalBytes > 0 ? min(1, Double(bytesReceived) / Double(totalBytes)) : 0 }
    public var isArtefact: Bool { if case .artefact = kind { return true }; if case .file = kind { return true }; return false }
}

/// Serial-ish download queue (2 concurrent artefacts, 1 concurrent yt-dlp job) with pause/resume/retry.
@MainActor
public final class DownloadManager: ObservableObject {
    @Published public private(set) var items: [DownloadItem] = []
    @Published public var lastError: UserFacingError?

    private var tasks: [String: Task<Void, Never>] = [:]
    private let updateService: () -> UpdateService?
    private let youtube: () -> YouTubeService?
    public var onArtefactInstalled: ((Artefact) -> Void)?
    public var onVideoDownloaded: ((Video) -> Void)?
    public var maxConcurrentArtefacts = 2
    public var maxConcurrentVideos = 1

    public init(updateService: @escaping () -> UpdateService?, youtube: @escaping () -> YouTubeService?) {
        self.updateService = updateService; self.youtube = youtube
    }

    public var activeCount: Int { items.filter { $0.state == .running || $0.state == .queued }.count }
    public var totalQueuedBytes: Int64 { items.filter { $0.state != .completed }.reduce(0) { $0 + $1.totalBytes } }

    // MARK: Enqueue

    public func enqueue(changes: [ManifestDiff.Change], manifestVersion: String) {
        for c in changes {
            let id = "artefact:" + c.artefact.id
            if let i = items.firstIndex(where: { $0.id == id }) {
                if case .failed = items[i].state { items[i].state = .queued } else if items[i].state == .paused { items[i].state = .queued } else { continue }
            } else {
                items.append(DownloadItem(id: id, kind: .artefact(c, manifestVersion: manifestVersion), title: c.artefact.displayTitle, totalBytes: c.artefact.sizeBytes))
            }
        }
        pump()
    }

    /// Resumable download of an external file into the library (no checksum available; completeness by size).
    public func enqueue(fileURL: URL, destination: URL, sizeBytes: Int64, title: String) {
        let id = "file:" + destination.lastPathComponent
        if let i = items.firstIndex(where: { $0.id == id }) {
            if items[i].state == .paused || { if case .failed = items[i].state { return true } else { return false } }() { items[i].state = .queued } else { return }
        } else {
            items.append(DownloadItem(id: id, kind: .file(url: fileURL, destination: destination, sizeBytes: sizeBytes), title: title, totalBytes: sizeBytes))
        }
        pump()
    }

    public func enqueue(videos: [Video], quality: VideoQuality, estimatedBytes: (Video) -> Int64?) {
        for v in videos {
            let id = "video:" + v.id
            if items.contains(where: { $0.id == id && $0.state != .completed }) { continue }
            items.removeAll { $0.id == id }
            items.append(DownloadItem(id: id, kind: .video(v, quality: quality), title: v.title, totalBytes: estimatedBytes(v) ?? 0))
            try? youtube()?.library.setStatus(.queued, for: v.id)
        }
        pump()
    }

    // MARK: Controls

    public func pause(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        tasks[id]?.cancel(); tasks[id] = nil
        items[i].state = .paused
        items[i].statusText = "Paused"
        pump()
    }

    public func resume(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].state == .paused || { if case .failed = items[i].state { return true } else { return false } }() { items[i].state = .queued }
        pump()
    }

    public func retry(_ id: String) { resume(id) }

    public func remove(_ id: String) {
        tasks[id]?.cancel(); tasks[id] = nil
        if let item = items.first(where: { $0.id == id }), case .video(let v, _) = item.kind, item.state != .completed { try? youtube()?.library.setStatus(.indexed, for: v.id) }
        items.removeAll { $0.id == id }
        pump()
    }

    public func clearCompleted() { items.removeAll { $0.state == .completed } }

    public func pauseAll() { for item in items where item.state == .running || item.state == .queued { pause(item.id) } }
    public func resumeAll() { for item in items where item.state == .paused { resume(item.id) } }

    // MARK: Engine

    private func pump() {
        let runningArtefacts = items.filter { $0.state == .running && $0.isArtefact }.count
        let runningVideos = items.filter { $0.state == .running && !$0.isArtefact }.count
        var slotsA = maxConcurrentArtefacts - runningArtefacts
        var slotsV = maxConcurrentVideos - runningVideos
        for item in items where item.state == .queued {
            if item.isArtefact { guard slotsA > 0 else { continue }; slotsA -= 1 } else { guard slotsV > 0 else { continue }; slotsV -= 1 }
            start(item.id)
        }
    }

    private var lastProgressFlush: [String: Date] = [:]
    private func update(_ id: String, _ body: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[i])
    }
    /// Progress-only updates are coalesced so observers (lists, badges) are not re-rendered hundreds of times a second.
    private func updateProgress(_ id: String, _ body: (inout DownloadItem) -> Void) {
        let now = Date()
        if let last = lastProgressFlush[id], now.timeIntervalSince(last) < 0.2 { return }
        lastProgressFlush[id] = now
        update(id, body)
    }
    /// Fires when an item finishes or fails (coarse signal for screens that list downloaded content).
    public var onItemFinished: ((DownloadItem) -> Void)?

    private func start(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        update(id) { $0.state = .running; $0.statusText = "Starting…" }
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                switch item.kind {
                case .artefact(let change, let manifestVersion):
                    guard let svc = self.updateService() else { throw UserFacingError("No library", message: "Choose a library folder first.") }
                    try await svc.apply(change, manifestVersion: manifestVersion) { phase in
                        Task { @MainActor in
                            let apply: (inout DownloadItem) -> Void = { it in
                                switch phase {
                                case .downloading(let p): it.bytesReceived = p.bytesReceived; it.totalBytes = p.totalBytes; it.bytesPerSecond = p.bytesPerSecond; it.statusText = p.bytesPerSecond > 0 ? "\(ByteFormat.string(Int64(p.bytesPerSecond)))/s" : "Downloading"
                                case .verifying(let f): it.statusText = "Verifying… \(Int(f * 100))%"; it.bytesReceived = it.totalBytes
                                case .installing: it.statusText = "Installing…"
                                case .done: it.statusText = "Installed"
                                }
                            }
                            if case .downloading = phase { self.updateProgress(id, apply) } else if case .verifying = phase { self.updateProgress(id, apply) } else { self.update(id, apply) }
                        }
                    }
                    self.update(id) { $0.state = .completed; $0.bytesReceived = $0.totalBytes; $0.statusText = "Installed" }
                    self.onArtefactInstalled?(change.artefact)
                    if let it = self.items.first(where: { $0.id == id }) { self.onItemFinished?(it) }
                case .file(let url, let destination, let size):
                    guard let svc = self.updateService() else { throw UserFacingError("No library", message: "Choose a library folder first.") }
                    guard svc.layout.hasSpace(forAdditionalBytes: size) else { throw UserFacingError("Not enough space", message: "\(item.title) needs \(ByteFormat.string(size)) and the library drive is nearly full.", recovery: "Free up space or move the library to a larger drive.") }
                    let pseudo = Artefact(id: "file-" + destination.lastPathComponent, kind: .map, path: url.absoluteString, sizeBytes: size, sha256: "", title: item.title)
                    let file = try await svc.downloader.download(pseudo, from: url.deletingLastPathComponent(), staging: svc.layout.staging, progress: { p in
                        Task { @MainActor in self.updateProgress(id) { it in it.bytesReceived = p.bytesReceived; it.totalBytes = p.totalBytes; it.bytesPerSecond = p.bytesPerSecond; it.statusText = p.bytesPerSecond > 0 ? "\(ByteFormat.string(Int64(p.bytesPerSecond)))/s" : "Downloading" } }
                    })
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.moveItem(at: file, to: destination)
                    self.update(id) { $0.state = .completed; $0.bytesReceived = $0.totalBytes; $0.statusText = "Installed" }
                    if let it = self.items.first(where: { $0.id == id }) { self.onItemFinished?(it) }
                case .video(let video, let quality):
                    guard let yt = self.youtube() else { throw UserFacingError("No library", message: "Choose a library folder first.") }
                    let done = try await yt.download(video: video, quality: quality) { ev in
                        Task { @MainActor in
                            let apply: (inout DownloadItem) -> Void = { it in
                                switch ev {
                                case .progress(let p):
                                    it.bytesReceived = p.downloadedBytes
                                    if let t = p.totalBytes, t > 0 { it.totalBytes = t }
                                    it.bytesPerSecond = p.bytesPerSecond ?? 0
                                    it.statusText = p.bytesPerSecond.map { "\(ByteFormat.string(Int64($0)))/s" } ?? "Downloading"
                                case .status(let s): it.statusText = s
                                }
                            }
                            if case .progress = ev { self.updateProgress(id, apply) } else { self.update(id, apply) }
                        }
                    }
                    self.update(id) { $0.state = .completed; $0.bytesReceived = $0.totalBytes; $0.statusText = "Saved \(ByteFormat.string(done.fileSize ?? 0))" }
                    self.onVideoDownloaded?(done)
                    if let it = self.items.first(where: { $0.id == id }) { self.onItemFinished?(it) }
                }
            } catch is CancellationError {
                self.update(id) { if $0.state == .running { $0.state = .paused } }
            } catch {
                let uf = error.userFacing
                if (error as NSError).code == NSURLErrorCancelled { self.update(id) { if $0.state == .running { $0.state = .paused } } }
                else { self.update(id) { $0.state = .failed(uf); $0.statusText = uf.message }; self.lastError = uf; if let it = self.items.first(where: { $0.id == id }) { self.onItemFinished?(it) } }
            }
            self.tasks[id] = nil
            self.pump()
        }
    }

    public func cancelAll() {
        for (_, t) in tasks { t.cancel() }
        tasks.removeAll()
    }
}
