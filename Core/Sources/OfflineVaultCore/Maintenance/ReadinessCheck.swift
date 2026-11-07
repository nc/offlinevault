import Foundation

/// The "offline drill": proves the library works without the internet and reports what would fail in an outage.
/// Pure logic over injected services so it runs identically in the app and in tests.
public struct ReadinessReport: Sendable, Equatable {
    public enum Status: String, Sendable, Comparable {
        case pass, warn, fail
        private var order: Int { ["pass": 0, "warn": 1, "fail": 2][rawValue]! }
        public static func < (a: Status, b: Status) -> Bool { a.order < b.order }
    }
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var status: Status
        public var detail: String
        /// Identifier of a fix the UI can offer (e.g. "install-rosetta", "backup", "rebuild-index", "restart-kiwix").
        public var fix: String?
        public var duration: TimeInterval = 0
        public init(id: String, title: String, status: Status, detail: String, fix: String? = nil) { self.id = id; self.title = title; self.status = status; self.detail = detail; self.fix = fix }
    }
    public var items: [Item] = []
    public var startedAt = Date()
    public var finishedAt: Date?
    public var networkWasReachable: Bool?
    public init() {}
    public var overall: Status { items.map(\.status).max() ?? .pass }
    public var counts: (pass: Int, warn: Int, fail: Int) { (items.filter { $0.status == .pass }.count, items.filter { $0.status == .warn }.count, items.filter { $0.status == .fail }.count) }
}

public struct ReadinessCheck: Sendable {
    public struct Dependencies: Sendable {
        public var layout: LibraryLayout
        public var database: IndexDatabase
        public var reference: ReferenceLibraryService?
        public var llm: LLMClient?
        public var llmModelName: String?
        public var coordinator: RetrievalCoordinator?
        public var backupService: BackupService?
        public var entitlements: Entitlements
        /// The decoded licence, for the clock-sanity check only.
        public var licence: Licence?
        public var kiwixState: ManagedProcess.State
        public var llamaState: ManagedProcess.State
        public init(layout: LibraryLayout, database: IndexDatabase, reference: ReferenceLibraryService?, llm: LLMClient?, llmModelName: String?, coordinator: RetrievalCoordinator?, backupService: BackupService?, entitlements: Entitlements, licence: Licence?, kiwixState: ManagedProcess.State, llamaState: ManagedProcess.State) {
            self.layout = layout; self.database = database; self.reference = reference; self.llm = llm; self.llmModelName = llmModelName; self.coordinator = coordinator; self.backupService = backupService; self.entitlements = entitlements; self.licence = licence; self.kiwixState = kiwixState; self.llamaState = llamaState
        }
    }

    public let deps: Dependencies
    public init(deps: Dependencies) { self.deps = deps }

    public func run(progress: @escaping @Sendable (ReadinessReport) -> Void) async -> ReadinessReport {
        var report = ReadinessReport()
        func add(_ item: ReadinessReport.Item, _ t0: Date) { var i = item; i.duration = Date().timeIntervalSince(t0); report.items.append(i); progress(report) }

        // 0. Are we actually offline right now? (informational — the drill is meant to be run in airplane mode)
        var t = Date()
        report.networkWasReachable = await LocalHTTP.isHealthy(URL(string: "https://captive.apple.com/hotspot-detect.html")!, timeout: 3)
        add(.init(id: "network", title: "Network state", status: .pass, detail: report.networkWasReachable == true ? "Internet is reachable. For a true drill, turn Wi-Fi off and run again — every check below must still pass." : "No internet detected: this is a real offline drill."), t)

        // 1. Helper binaries + Rosetta
        t = Date()
        var missing: [String] = []
        for b in HelperBinary.allCases where b.locate() == nil { missing.append(b.rawValue) }
        add(.init(id: "binaries", title: "Helper programs bundled", status: missing.isEmpty ? .pass : .fail, detail: missing.isEmpty ? "kiwix-serve, llama-server, yt-dlp, ffmpeg found" : "Missing: \(missing.joined(separator: ", "))", fix: missing.isEmpty ? nil : "reinstall"), t)
        if RosettaStatus.neededByHelpers {
            t = Date()
            let ok = RosettaStatus.isInstalled()
            add(.init(id: "rosetta", title: "Rosetta 2 (needed by kiwix-serve)", status: ok ? .pass : .fail, detail: ok ? "Installed" : "Not installed. macOS can only install Rosetta from the internet — do it now, before you need it.", fix: ok ? nil : "install-rosetta"), t)
        }

        // 2. Library volume
        t = Date()
        let local = VolumeInfo.isLocal(deps.layout.root)
        add(.init(id: "volume", title: "Library drive", status: local == false ? .warn : .pass, detail: local == false ? "The library is on a network share; SQLite is unsafe there and the share will not exist in an outage. Move it to a local or USB drive." : "\(VolumeInfo.volumeName(deps.layout.root) ?? "local volume") — \(ByteFormat.string(deps.layout.volumeCapacity().free)) free"), t)

        // 3. Index integrity
        t = Date()
        let problems = LibraryMaintenance(layout: deps.layout, database: deps.database).quickCheck()
        add(.init(id: "index", title: "Search index integrity", status: problems.isEmpty ? .pass : .fail, detail: problems.isEmpty ? "SQLite quick_check passed" : problems.prefix(2).joined(separator: "; "), fix: problems.isEmpty ? nil : "rebuild-index"), t)

        // 4. Reference books: engine up, each book validated and searchable
        t = Date()
        let books = (try? deps.database.zimBooks()) ?? []
        if books.isEmpty {
            add(.init(id: "books", title: "Reference books", status: .warn, detail: "No reference books installed. Add WikiMed or the Core tier so medical and survival questions have sources.", fix: "updates"), t)
        } else if deps.kiwixState != .running || deps.reference == nil {
            add(.init(id: "books", title: "Reference books", status: .fail, detail: "kiwix-serve is \(deps.kiwixState.label.lowercased()); \(books.count) book(s) unreachable.", fix: "restart-kiwix"), t)
        } else {
            var bad: [String] = []
            for b in books {
                let file = deps.layout.zim.appendingPathComponent(b.fileName)
                if case .damaged(let why) = ZimValidator.validate(file) { bad.append("\(b.displayTitle): \(why)"); continue }
                let probe = (b.title ?? b.name).split(separator: " ").first { $0.count > 3 }.map(String.init) ?? "the"
                if let hits = try? await deps.reference!.search(probe, books: [b.name], limit: 1), hits.isEmpty, let h2 = try? await deps.reference!.search("a", books: [b.name], limit: 1), h2.isEmpty { bad.append("\(b.displayTitle): search returned nothing") }
            }
            add(.init(id: "books", title: "Reference books (\(books.count))", status: bad.isEmpty ? .pass : .fail, detail: bad.isEmpty ? "Every book opens and answers a search" : bad.joined(separator: "; "), fix: bad.isEmpty ? nil : "verify"), t)
        }

        // 5. Documents / pages / videos / maps files present
        t = Date()
        let docs = DocumentService(layout: deps.layout, database: deps.database)
        let docList = (try? docs.documents()) ?? []
        let missingDocs = docList.filter { !FileManager.default.fileExists(atPath: docs.fileURL(for: $0).path) }
        add(.init(id: "documents", title: "Documents (\(docList.count))", status: missingDocs.isEmpty ? (docList.isEmpty ? .warn : .pass) : .fail, detail: docList.isEmpty ? "No manuals yet — the US government document pack is the single best addition." : missingDocs.isEmpty ? "All files present" : "\(missingDocs.count) missing: \(missingDocs.prefix(3).map(\.title).joined(separator: ", "))", fix: missingDocs.isEmpty ? (docList.isEmpty ? "updates" : nil) : "rebuild-index"), t)
        t = Date()
        let videos = VideoLibraryService(layout: deps.layout, database: deps.database)
        let vids = (try? videos.videos(status: .downloaded)) ?? []
        let missingVids = vids.filter { v in videos.fileURL(for: v).map { !FileManager.default.fileExists(atPath: $0.path) } ?? true }
        add(.init(id: "videos", title: "Videos (\(vids.count))", status: missingVids.isEmpty ? .pass : .fail, detail: missingVids.isEmpty ? "All files present" : "\(missingVids.count) missing", fix: missingVids.isEmpty ? nil : "rebuild-index"), t)
        t = Date()
        let maps = MapsService(layout: deps.layout).maps()
        let badMaps = maps.filter { $0.header == nil }
        add(.init(id: "maps", title: "Offline maps (\(maps.count))", status: maps.isEmpty ? .warn : (badMaps.isEmpty ? .pass : .fail), detail: maps.isEmpty ? "No map regions. Extract your area with the pmtiles tool while you are online (Settings › Maps)." : badMaps.isEmpty ? maps.map(\.title).joined(separator: ", ") : "Unreadable: \(badMaps.map(\.name).joined(separator: ", "))", fix: maps.isEmpty ? "maps" : nil), t)

        // 6. AI model answers from the library with a citation
        t = Date()
        if let llm = deps.llm, deps.llamaState == .running {
            let coordinator = deps.coordinator ?? RetrievalCoordinator(retrievers: [])
            // Pick a question the library can answer: the first indexed document/page chunk's leading words.
            let seed = (try? deps.database.db.query("SELECT text FROM doc_chunks ORDER BY id LIMIT 1").first?.string("text")) ?? (try? deps.database.db.query("SELECT text FROM page_chunks ORDER BY id LIMIT 1").first?.string("text")) ?? ""
            let question = seed.isEmpty ? "How do I make water safe to drink?" : "What does my library say about: " + seed.split(separator: " ").prefix(8).joined(separator: " ")
            let passages = await coordinator.retrieve(question)
            var answer = ""
            var err: String?
            do { for try await d in llm.streamChat(messages: Prompting.messages(history: [], userQuestion: question, passages: passages), options: { var o = ChatOptions(); o.maxTokens = 160; return o }()) { answer += d; if answer.count > 600 { break } } } catch { err = error.userFacing.message }
            let cited = Prompting.citedPassages(answer: answer, passages: passages)
            let status: ReadinessReport.Status = err != nil ? .fail : (passages.isEmpty ? .warn : (cited.isEmpty ? .warn : .pass))
            add(.init(id: "ai", title: "AI assistant (\(deps.llmModelName ?? "model"))", status: status, detail: err ?? (passages.isEmpty ? "Model answered, but no library sources were found for a test question — add reference content." : cited.isEmpty ? "Model answered without citing a source. Small models do this; the 4B default is recommended." : "Answered a library question in \(String(format: "%.1f", Date().timeIntervalSince(t)))s and cited \(cited.count) source(s)."), fix: err != nil ? "restart-llm" : nil), t)
        } else {
            add(.init(id: "ai", title: "AI assistant", status: .warn, detail: deps.llamaState == .starting ? "Model is still loading — run again in a minute." : "No model loaded. Chat will be unavailable; search still works.", fix: "restart-llm"), t)
        }

        // 7. Backup, licence, clock, memory, space
        t = Date()
        if let b = deps.backupService {
            let due = b.isReminderDue
            add(.init(id: "backup", title: "Second copy of the library", status: due ? .warn : .pass, detail: b.lastBackupDate.map { "Last verified backup \($0.formatted(.relative(presentation: .named))) at \(b.lastBackupPath ?? "")" } ?? "No backup recorded. Two is one, one is none.", fix: due ? "backup" : nil), t)
        }
        t = Date()
        add(Self.licenceItem(deps.entitlements), t)
        if let clock = ClockSanity.looksWrong(licence: deps.licence) { add(.init(id: "clock", title: "System clock", status: .warn, detail: clock), Date()) }
        t = Date()
        let (_, free) = deps.layout.volumeCapacity()
        add(.init(id: "space", title: "Free space on library drive", status: free < LibraryLayout.lowSpaceMargin ? .fail : (free < LibraryLayout.lowSpaceMargin * 5 ? .warn : .pass), detail: ByteFormat.string(free) + " free"), t)
        t = Date()
        let ram = MemoryPressureMonitor.physicalMemoryBytes
        add(.init(id: "memory", title: "Memory", status: ram <= 8 * 1024 * 1024 * 1024 ? .warn : .pass, detail: ByteFormat.string(ram) + (ram <= 8 * 1024 * 1024 * 1024 ? " — keep the 4B model, enable 'load model only when Chat opens', avoid running other heavy apps during use." : "")), t)

        report.finishedAt = Date()
        progress(report)
        return report
    }

    /// The plan line. A self-hosted source is never gated, so it passes whatever the plan says; on OfflineVault's
    /// service a lapsed plan and no plan warn.
    public static func licenceItem(_ e: Entitlements) -> ReadinessReport.Item {
        if case .selfHosted(let url) = e.source {
            return .init(id: "licence", title: "Plan", status: .pass, detail: "Content comes from \(url.host ?? url.absoluteString). No OfflineVault plan needed.")
        }
        if e.lapsedOn != nil {
            return .init(id: "licence", title: "Plan", status: .warn, detail: "\(e.label). New editions are paused; everything installed keeps working and the free tier still downloads.", fix: "licence")
        }
        guard e.plan == nil else { return .init(id: "licence", title: "Plan", status: .pass, detail: e.label) }
        return .init(id: "licence", title: "Plan", status: .warn, detail: "No plan. The free tier downloads; Core or Household adds the rest, and everything you add yourself works.", fix: "licence")
    }
}
