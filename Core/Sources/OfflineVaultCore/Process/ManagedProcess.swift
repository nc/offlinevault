import Foundation

/// A long-running helper (kiwix-serve, llama-server) with health checks, crash restart and guaranteed termination.
public final class ManagedProcess: @unchecked Sendable {
    public struct Spec: Sendable {
        public var name: String
        public var executable: URL
        public var arguments: [String]
        public var environment: [String: String]
        public var workingDirectory: URL?
        public var healthCheck: (@Sendable () async -> Bool)?
        public var startupTimeout: TimeInterval
        public var autoRestart: Bool

        public init(name: String, executable: URL, arguments: [String], environment: [String: String] = [:], workingDirectory: URL? = nil, healthCheck: (@Sendable () async -> Bool)? = nil, startupTimeout: TimeInterval = 60, autoRestart: Bool = true) {
            self.name = name; self.executable = executable; self.arguments = arguments; self.environment = environment
            self.workingDirectory = workingDirectory; self.healthCheck = healthCheck; self.startupTimeout = startupTimeout; self.autoRestart = autoRestart
        }
    }

    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running
        case crashed(exitCode: Int32)
        case failed(String)

        public var isRunning: Bool { self == .running }
        public var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case .running: return "Running"
            case .crashed(let c): return "Crashed (exit \(c))"
            case .failed(let m): return "Failed: \(m)"
            }
        }
    }

    public let spec: Spec
    private let lock = NSLock()
    private var process: Process?
    private var _state: State = .stopped
    private var intentionalStop = false
    private var restartTimestamps: [Date] = []
    private var outputLines: [String] = []
    private var stateObservers: [UUID: @Sendable (State) -> Void] = [:]
    public var pid: Int32? { lock.withLock { process?.processIdentifier } }

    public init(spec: Spec) { self.spec = spec }

    public var state: State { lock.withLock { _state } }

    /// Last ~200 lines of combined stdout/stderr for diagnostics.
    public var recentOutput: String { lock.withLock { outputLines.joined(separator: "\n") } }

    @discardableResult
    public func observeState(_ observer: @escaping @Sendable (State) -> Void) -> UUID {
        let id = UUID(); lock.withLock { stateObservers[id] = observer }; return id
    }
    public func removeObserver(_ id: UUID) { lock.withLock { _ = stateObservers.removeValue(forKey: id) } }

    private func setState(_ s: State) {
        let observers: [@Sendable (State) -> Void] = lock.withLock { _state = s; return Array(stateObservers.values) }
        Log.process.info("\(self.spec.name, privacy: .public): \(s.label, privacy: .public)")
        observers.forEach { $0(s) }
    }

    // MARK: Lifecycle

    /// Launches the process and waits until the health check passes (or the process exits / times out).
    public func start() async throws {
        if state == .running { return }
        lock.withLock { intentionalStop = false }
        try launch()
        setState(.starting)
        let deadline = Date().addingTimeInterval(spec.startupTimeout)
        while Date() < deadline {
            if let p = lock.withLock({ process }), !p.isRunning {
                let code = p.terminationStatus
                let tail = recentOutput.split(separator: "\n").suffix(5).joined(separator: "\n")
                setState(.failed("exited during startup (code \(code))"))
                throw UserFacingError("\(spec.name) failed to start", message: "The helper exited immediately with code \(code).\n\(tail)", recovery: "Check the log in Settings › Diagnostics; if a model or ZIM file is corrupt, delete it and download it again.")
            }
            if let hc = spec.healthCheck {
                if await hc() { setState(.running); return }
            } else {
                setState(.running); return
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        stop()
        setState(.failed("did not become healthy within \(Int(spec.startupTimeout))s"))
        throw UserFacingError("\(spec.name) did not start", message: "The helper did not respond within \(Int(spec.startupTimeout)) seconds.", recovery: "Try again. Large AI models take longer to load on first use; if this keeps happening choose a smaller model in Settings.")
    }

    private func launch() throws {
        let p = Process()
        let (exe, prefix) = HelperBinary.launchCommand(for: spec.executable)
        p.executableURL = exe
        p.arguments = prefix + spec.arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in spec.environment { env[k] = v }
        env["OFFLINEVAULT_PARENT_PID"] = String(getpid())
        p.environment = env
        if let wd = spec.workingDirectory { p.currentDirectoryURL = wd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        for pipe in [out, err] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let data = h.availableData
                guard let self, !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                self.appendOutput(s)
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            self?.handleTermination(status: proc.terminationStatus, reason: proc.terminationReason)
        }
        Log.process.info("launching \(self.spec.name, privacy: .public): \(exe.path, privacy: .public) \((prefix + self.spec.arguments).joined(separator: " "), privacy: .public)")
        do {
            try p.run()
        } catch {
            throw UserFacingError("\(spec.name) could not be launched", message: error.localizedDescription, recovery: "Reinstall OfflineVault or run scripts/fetch_binaries.sh in a development checkout.")
        }
        lock.withLock { process = p }
        ProcessSupervisor.shared.register(self)
    }

    private func appendOutput(_ s: String) {
        lock.withLock {
            for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
                outputLines.append(String(line))
            }
            if outputLines.count > 200 { outputLines.removeFirst(outputLines.count - 200) }
        }
        if ProcessInfo.processInfo.environment["OFFLINEVAULT_LOG"] == "1" {
            Log.process.debug("[\(self.spec.name, privacy: .public)] \(s.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
        }
    }

    private func handleTermination(status: Int32, reason: Process.TerminationReason) {
        let intentional = lock.withLock { intentionalStop }
        lock.withLock { process = nil }
        ProcessSupervisor.shared.unregister(self)
        if intentional { setState(.stopped); return }
        setState(.crashed(exitCode: status))
        guard spec.autoRestart else { return }
        // Allow at most 3 automatic restarts per minute; after that stay crashed and let the user decide.
        let now = Date()
        let recent: Int = lock.withLock {
            restartTimestamps = restartTimestamps.filter { now.timeIntervalSince($0) < 60 }
            return restartTimestamps.count
        }
        guard recent < 3 else {
            setState(.failed("crashed repeatedly (exit \(status)); automatic restart paused"))
            return
        }
        lock.withLock { restartTimestamps.append(now) }
        let delay = UInt64(1 + recent * 2) * 1_000_000_000
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !(self.lock.withLock { self.intentionalStop }) else { return }
            try? await self.start()
        }
    }

    /// SIGTERM, then SIGKILL after a grace period. Blocks briefly.
    public func stop(graceSeconds: TimeInterval = 3) {
        let p: Process? = lock.withLock { intentionalStop = true; return process }
        guard let p, p.isRunning else { setState(.stopped); return }
        p.terminate()
        let deadline = Date().addingTimeInterval(graceSeconds)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()
        lock.withLock { process = nil }
        ProcessSupervisor.shared.unregister(self)
        setState(.stopped)
    }

    public func restart() async throws {
        stop()
        try await start()
    }
}

/// Tracks every helper process so they are all terminated when the app quits, and reaps orphans left by a crash.
public final class ProcessSupervisor: @unchecked Sendable {
    public static let shared = ProcessSupervisor()

    private let lock = NSLock()
    private var managed: [ObjectIdentifier: ManagedProcess] = [:]
    private var oneShotPids: Set<Int32> = []
    private var installedSignalHandlers = false

    public var pidFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OfflineVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("helper-pids.json")
    }()

    private init() {}

    func register(_ p: ManagedProcess) {
        lock.withLock { managed[ObjectIdentifier(p)] = p }
        persistPids()
    }
    func unregister(_ p: ManagedProcess) {
        lock.withLock { _ = managed.removeValue(forKey: ObjectIdentifier(p)) }
        persistPids()
    }
    public func registerOneShot(pid: Int32, executable: URL) {
        lock.withLock { _ = oneShotPids.insert(pid) }
        persistPids(extra: [pid: executable.path])
    }
    public func unregisterOneShot(pid: Int32) {
        lock.withLock { _ = oneShotPids.remove(pid) }
        persistPids()
    }

    public var runningProcesses: [ManagedProcess] { lock.withLock { Array(managed.values) } }

    private var extraPaths: [Int32: String] = [:]
    private func persistPids(extra: [Int32: String] = [:]) {
        var map: [String: String] = [:]
        lock.withLock {
            for (k, v) in extra { extraPaths[k] = v }
            for p in managed.values { if let pid = p.pid { map[String(pid)] = p.spec.executable.path } }
            for pid in oneShotPids { map[String(pid)] = extraPaths[pid] ?? "" }
            extraPaths = extraPaths.filter { oneShotPids.contains($0.key) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: map) { try? data.write(to: pidFileURL, options: .atomic) }
    }

    /// Terminates all helpers. Call from `applicationWillTerminate` and signal handlers.
    public func terminateAll() {
        let procs = lock.withLock { Array(managed.values) }
        for p in procs { p.stop(graceSeconds: 2) }
        let pids = lock.withLock { oneShotPids }
        for pid in pids { kill(pid, SIGTERM) }
        usleep(200_000)
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// Kills helpers recorded by a previous (crashed) instance of the app, verifying the executable path first
    /// so we never kill an unrelated process that reused the pid.
    public func reapOrphans() {
        guard let data = try? Data(contentsOf: pidFileURL), let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        for (pidString, path) in map {
            guard let pid = Int32(pidString), pid > 1, pid != getpid(), kill(pid, 0) == 0 else { continue }
            let actual = Self.executablePath(of: pid)
            // kiwix-serve runs via /usr/bin/arch; `actual` is then the real binary after exec, so compare both ways.
            if actual == path || actual.hasSuffix((path as NSString).lastPathComponent) || path.isEmpty {
                Log.process.warning("reaping orphaned helper pid \(pid) (\(actual, privacy: .public))")
                kill(pid, SIGTERM)
                usleep(300_000)
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    public static func executablePath(of pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    /// Make sure SIGTERM/SIGINT/SIGHUP to the app also take the helpers down.
    public func installSignalHandlers() {
        lock.withLock {
            guard !installedSignalHandlers else { return }
            installedSignalHandlers = true
        }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            signal(sig, SIG_IGN)
            src.setEventHandler { ProcessSupervisor.shared.terminateAll(); exit(0) }
            src.resume()
            signalSources.append(src)
        }
        atexit { ProcessSupervisor.shared.terminateAll() }
    }
    private var signalSources: [DispatchSourceSignal] = []
}

/// Runs a short-lived command (yt-dlp, ffmpeg) with streamed line output and cooperative cancellation.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
    }

    public static func run(_ executable: URL, arguments: [String], workingDirectory: URL? = nil, environment: [String: String] = [:], onLine: (@Sendable (String, Bool) -> Void)? = nil) async throws -> Result {
        let p = Process()
        let (exe, prefix) = HelperBinary.launchCommand(for: executable)
        p.executableURL = exe
        p.arguments = prefix + arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        p.environment = env
        if let wd = workingDirectory { p.currentDirectoryURL = wd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice

        let collector = LineCollector(onLine: onLine)
        out.fileHandleForReading.readabilityHandler = { h in collector.feed(h.availableData, isStderr: false) }
        err.fileHandleForReading.readabilityHandler = { h in collector.feed(h.availableData, isStderr: true) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
                p.terminationHandler = { proc in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collector.feed(out.fileHandleForReading.readDataToEndOfFile(), isStderr: false)
                    collector.feed(err.fileHandleForReading.readDataToEndOfFile(), isStderr: true)
                    collector.flush()
                    ProcessSupervisor.shared.unregisterOneShot(pid: proc.processIdentifier)
                    cont.resume(returning: Result(exitCode: proc.terminationStatus, stdout: collector.stdout, stderr: collector.stderr))
                }
                do {
                    try p.run()
                    ProcessSupervisor.shared.registerOneShot(pid: p.processIdentifier, executable: executable)
                    collector.process = p
                } catch {
                    cont.resume(throwing: UserFacingError("\(executable.lastPathComponent) could not be launched", message: error.localizedDescription))
                }
            }
        } onCancel: {
            collector.cancel()
        }
    }

    final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var outBuf = Data(), errBuf = Data()
        private(set) var stdout = "", stderr = ""
        private let onLine: (@Sendable (String, Bool) -> Void)?
        var process: Process?
        init(onLine: (@Sendable (String, Bool) -> Void)?) { self.onLine = onLine }

        func feed(_ data: Data, isStderr: Bool) {
            guard !data.isEmpty else { return }
            var lines: [String] = []
            lock.withLock {
                if isStderr { errBuf.append(data) } else { outBuf.append(data) }
                var buf = isStderr ? errBuf : outBuf
                while let nl = buf.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
                    buf.removeSubrange(buf.startIndex...nl)
                    if !line.isEmpty { lines.append(line) }
                }
                if isStderr { errBuf = buf } else { outBuf = buf }
                for l in lines { if isStderr { stderr += l + "\n" } else { stdout += l + "\n" } }
            }
            for l in lines { onLine?(l, isStderr) }
        }
        func flush() {
            lock.withLock {
                if !outBuf.isEmpty { stdout += String(decoding: outBuf, as: UTF8.self); outBuf.removeAll() }
                if !errBuf.isEmpty { stderr += String(decoding: errBuf, as: UTF8.self); errBuf.removeAll() }
            }
        }
        func cancel() {
            lock.withLock {
                guard let p = process, p.isRunning else { return }
                p.terminate()
                let pid = p.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
            }
        }
    }
}
