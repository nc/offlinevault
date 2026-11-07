import Foundation

/// Describes a GGUF model available in `models/`.
public struct LocalModel: Equatable, Sendable, Identifiable, Hashable {
    public var fileURL: URL
    public var displayName: String
    public var sizeBytes: Int64
    public var artefactId: String?
    public var id: String { fileURL.lastPathComponent }
    public init(fileURL: URL, displayName: String, sizeBytes: Int64, artefactId: String? = nil) {
        self.fileURL = fileURL; self.displayName = displayName; self.sizeBytes = sizeBytes; self.artefactId = artefactId
    }

    public static func scan(_ directory: URL, installed: [InstalledArtefact] = []) -> [LocalModel] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "gguf" && !$0.lastPathComponent.lowercased().hasPrefix("dflash-") && !$0.lastPathComponent.lowercased().hasPrefix("mmproj-") }.map { f in
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let art = installed.first { $0.kind == .model && $0.fileName == f.lastPathComponent }
            return LocalModel(fileURL: f, displayName: f.deletingPathExtension().lastPathComponent, sizeBytes: size, artefactId: art?.id)
        }.sorted { $0.displayName < $1.displayName }
    }
}

/// Manages `llama-server` (llama.cpp) serving one model over the OpenAI-compatible API on localhost.
public final class LlamaServerService: @unchecked Sendable {
    public let port: Int
    public let baseURL: URL
    private let lock = NSLock()
    private var process: ManagedProcess?
    private var _loadedModel: LocalModel?
    public var stateObserver: (@Sendable (ManagedProcess.State) -> Void)?

    public init(port: Int = Config.llamaPort) {
        self.port = port
        self.baseURL = URL(string: "http://127.0.0.1:\(port)/")!
    }

    public var loadedModel: LocalModel? { lock.withLock { _loadedModel } }
    public var isRunning: Bool { process?.state == .running }
    public var processState: ManagedProcess.State { process?.state ?? .stopped }
    public var recentOutput: String { process?.recentOutput ?? "" }

    /// Context size scaled to RAM: 8k on ≤8 GB machines, 16k otherwise (per-model overrides in `ModelProfile`).
    public static var contextSize: Int {
        ProcessInfo.processInfo.physicalMemory <= 8 * 1024 * 1024 * 1024 ? 8192 : 16384
    }

    /// llama-server arguments for a model: profile-specific context, template arguments and an optional drafter.
    public static func arguments(for model: LocalModel, port: Int, physicalMemory: UInt64, drafter: URL?) -> [String] {
        let profile = model.profile
        var args = ["-m", model.fileURL.path, "--host", "127.0.0.1", "--port", String(port),
                    "-c", String(profile.contextSize(physicalMemory: physicalMemory)), "-ngl", "99", "--jinja", "--no-webui", "--parallel", "1",
                    "--reasoning-format", "deepseek", "--log-disable"]
        if !profile.templateKwargs.isEmpty, let data = try? JSONSerialization.data(withJSONObject: profile.templateKwargs.mapValues { v -> Any in if v == "true" { return true }; if v == "false" { return false }; return v }), let json = String(data: data, encoding: .utf8) {
            args += ["--chat-template-kwargs", json]
        }
        if let drafter { args += profile.drafterArguments(drafter) }
        return args
    }

    public func start(model: LocalModel) async throws {
        if isRunning, loadedModel == model { return }
        stop()
        guard FileManager.default.fileExists(atPath: model.fileURL.path) else {
            throw UserFacingError("Model missing", message: "\(model.displayName) is not in the models folder.", recovery: "Download it again from Settings › AI Model.")
        }
        let physical = ProcessInfo.processInfo.physicalMemory
        guard model.memoryNeeded <= physical else {
            throw UserFacingError("Not enough memory for \(model.profile.displayName)", message: "\(model.displayName) needs about \(ByteFormat.string(model.memoryNeeded)) of memory to run alongside the library; this Mac has \(ByteFormat.string(physical)).", recovery: "Choose a smaller model in Settings › AI Model.")
        }
        let exe = try HelperBinary.llamaServer.require()
        let url = baseURL
        let drafter = model.profile.drafter(in: model.fileURL.deletingLastPathComponent())
        let args = Self.arguments(for: model, port: port, physicalMemory: physical, drafter: drafter)
        let spec = ManagedProcess.Spec(name: "llama-server", executable: exe, arguments: args,
                                       environment: ["DYLD_LIBRARY_PATH": exe.deletingLastPathComponent().path],
                                       healthCheck: { await LocalHTTP.isHealthy(url.appendingPathComponent("health")) },
                                       startupTimeout: model.sizeBytes > 10_000_000_000 ? 420 : 180, autoRestart: true)
        let p = ManagedProcess(spec: spec)
        if let obs = stateObserver { p.observeState(obs) }
        lock.withLock { process = p; _loadedModel = model }
        do { try await p.start() } catch { lock.withLock { _loadedModel = nil }; throw error }
    }

    public func stop() {
        let p: ManagedProcess? = lock.withLock { let x = process; process = nil; _loadedModel = nil; return x }
        p?.stop()
    }

    public func makeClient() -> LLMClient { OpenAICompatibleClient(baseURL: baseURL) }
}
