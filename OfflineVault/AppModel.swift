import SwiftUI
import Combine
import OfflineVaultCore

/// Root state: library, services, helper processes, navigation and update checks.
@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case chat, scenarios, library, documents, maps, videos, pages, sources, downloads, readiness, backup, share, maintenance, settings
        /// Sidebar grouping.
        static let knowledge: [Section] = [.chat, .scenarios, .library, .documents, .maps, .videos, .pages]
        static let manage: [Section] = [.sources, .downloads, .readiness, .backup, .share, .maintenance]
        var id: String { rawValue }
        var title: String {
            switch self {
            case .chat: return "Chat"; case .scenarios: return "Scenarios"; case .library: return "Reference"; case .documents: return "Documents"; case .maps: return "Maps"; case .videos: return "Videos"; case .pages: return "Saved Pages"
            case .sources: return "Video Sources"; case .downloads: return "Downloads"; case .readiness: return "Readiness"; case .backup: return "Backup"; case .share: return "Share on Wi-Fi"; case .maintenance: return "Maintenance"; case .settings: return "Settings"
            }
        }
        var systemImage: String {
            switch self {
            case .chat: return "bubble.left.and.text.bubble.right"; case .scenarios: return "list.bullet.clipboard"; case .library: return "books.vertical"; case .documents: return "doc.richtext"; case .maps: return "map"; case .videos: return "play.rectangle.on.rectangle"
            case .pages: return "doc.text"; case .sources: return "antenna.radiowaves.left.and.right"; case .downloads: return "arrow.down.circle"; case .readiness: return "checkmark.shield"; case .backup: return "externaldrive.badge.checkmark"; case .share: return "wifi"; case .maintenance: return "wrench.and.screwdriver"; case .settings: return "gearshape"
            }
        }
    }

    let settings = AppSettings.shared
    @Published var section: Section = Section(rawValue: UserDefaults.standard.string(forKey: "lastSection") ?? "") ?? .chat { didSet { UserDefaults.standard.set(section.rawValue, forKey: "lastSection"); if oldValue == .videos, section != .videos { videosScreen.player.pause() } } }
    enum SettingsTab: String { case general, models, licence, updates, about }
    @Published var settingsTab: SettingsTab = .general

    // Screen state that must survive navigation.
    let libraryScreen = LibraryScreen()
    let documentsScreen = DocumentsScreen()
    let pagesScreen = PagesScreen()
    let videosScreen = VideosScreen()
    let mapsScreen = MapsScreen()
    let scenariosScreen = ScenariosScreen()
    let sourcesScreen = SourcesScreen()
    let globalSearch = GlobalSearchState()
    let updater = Updater()
    let location = LocationService()

    /// Notices are queued (newest first, at most three) instead of overwriting one another.
    @Published var banners: [UserFacingError] = []
    var banner: UserFacingError? {
        get { banners.first }
        set { if let b = newValue { if !banners.contains(b) { banners.insert(b, at: 0) }; while banners.count > 3 { bannerFixes[banners.removeLast()] = nil } } }
    }
    func dismiss(_ b: UserFacingError) { banners.removeAll { $0 == b }; bannerFixes[b] = nil }
    @Published private(set) var layout: LibraryLayout?
    @Published private(set) var database: IndexDatabase?
    @Published var kiwixState: ManagedProcess.State = .stopped
    @Published var llamaState: ManagedProcess.State = .stopped
    /// Kept for the Licence tab's summary only; every gate reads `entitlements`.
    @Published var licenceStatus: LicenceStatus = .none
    @Published var entitlements: Entitlements = .resolve(status: .none, source: .offlineVault)
    /// Macs holding this key's seats, as of the last issuer call. nil until fetched.
    @Published var seats: [Seat]?
    @Published var activating = false
    /// A key that arrived by `offlinevault://activate` and waits for the user to confirm it in RootView's alert.
    @Published var pendingURLActivation: LicenceKey?
    /// Which fix a plan banner offers, so the banner's action button needs no string matching. Entries live as long
    /// as their banner: dismissal and eviction remove them.
    var bannerFixes: [UserFacingError: Denial.Fix] = [:]
    @Published var books: [ZimBook] = []
    @Published var referenceBooks: [ReferenceBook] = []
    @Published var models: [LocalModel] = []
    @Published var installed: [InstalledArtefact] = []
    @Published var storage: LibraryLayout.StorageReport?
    @Published var updateCheck: UpdateCheck?
    @Published var isCheckingUpdates = false
    @Published var showUpdateSheet = false
    @Published var helperWarnings: [String] = []

    // Cross-tab navigation requests (citations → viewer).
    @Published var pendingArticle: (book: String, path: String)?
    @Published var pendingPageId: String?
    @Published var pendingVideo: (id: String, seconds: Double?)?
    @Published var pendingDocument: (id: String, page: Int)?
    /// Text the article or page viewer selects once it has loaded (the first words of a quote).
    @Published var pendingHighlight: String?

    struct UpdateCheck { var manifest: Manifest; var trust: CatalogueTrust; var diff: ManifestDiff; var checkedAt: Date }

    let kiwix = KiwixServeService()
    let llama = LlamaServerService()
    let chat = ChatController()
    private(set) var updateService: UpdateService?
    private(set) var pageService: PageService?
    private(set) var documentService: DocumentService?
    private(set) var mapsService: MapsService?
    private(set) var backupService: BackupService?
    private(set) var importer: LibraryImporter?
    private(set) var shareServer: LocalShareServer?
    @Published var isSharing = false
    @Published var showImportSheet = false

    /// Where the library stands right now: ready, configured but its drive is unplugged, or not set up.
    enum LibraryState: Equatable { case none, ready, volumeMissing(path: String) }
    @Published var libraryState: LibraryState = .none
    @Published var damagedBooks: [(file: String, reason: String)] = []
    @Published var memoryLevel: MemoryPressureMonitor.Level = .normal
    @Published var readinessReport: ReadinessReport?
    @Published var readinessRunning = false
    @Published var rosettaMissing = false
    private(set) var maintenance: LibraryMaintenance?
    private let memoryMonitor = MemoryPressureMonitor()
    private var volumeObservers: [NSObjectProtocol] = []
    private var llmRequested = false
    private(set) var videoLibrary: VideoLibraryService?
    private(set) var youtube: YouTubeService?
    private(set) var entitlement: EntitlementService?
    lazy var downloads: DownloadManager = {
        let dm = DownloadManager(updateService: { [weak self] in self?.updateService }, youtube: { [weak self] in self?.youtube })
        dm.onArtefactInstalled = { [weak self] a in Task { await self?.artefactInstalled(a) } }
        dm.onVideoDownloaded = { [weak self] _ in self?.objectWillChange.send() }
        return dm
    }()

    var needsSetup: Bool { libraryState != .volumeMissing(path: settings.libraryPath ?? "") && (layout == nil || !settings.setupCompleted) }
    var volumeMissing: Bool { if case .volumeMissing = libraryState { return true } else { return false } }

    init() {
        kiwix.stateObserver = { [weak self] s in Task { @MainActor in self?.kiwixState = s } }
        llama.stateObserver = { [weak self] s in Task { @MainActor in self?.llamaState = s; if case .crashed = s { self?.chat.modelUnavailable("The AI model process stopped unexpectedly; restarting…") } } }
    }

    // MARK: Bootstrap

    func bootstrap() async {
        checkHelperBinaries()
        Notifier.requestAuthorization()
        downloads.onItemFinished = { [weak self] item in
            guard let self else { return }
            if case .failed(let e) = item.state { Notifier.post(title: "Download failed", body: "\(item.title): \(e.message)") }
            else if !NSApp.isActive { Notifier.post(title: item.isArtefact ? "Library content installed" : "Video ready", body: item.title) }
            Notifier.setBadge(self.downloads.activeCount)
        }
        rosettaMissing = RosettaStatus.neededByHelpers && !RosettaStatus.isInstalled()
        watchVolumes()
        memoryMonitor.start { [weak self] level in Task { @MainActor in self?.memoryPressureChanged(level) } }
        if let l = settings.libraryLayout {
            if LibraryLayout.looksLikeLibrary(l.root) {
                do { try openLibrary(at: l.root) } catch { banner = error.userFacing }
                await entitlement?.refreshIfDue()
                refreshLibraryState()
                await startHelpers()
                var autoCheck = settings.autoCheckUpdates && settings.setupCompleted
                #if DEBUG
                if ScreenshotMode.directory != nil { autoCheck = false }   // no update sheet over the screenshots
                #endif
                if autoCheck { await checkForUpdates(interactive: false) }
            } else if settings.setupCompleted {
                // Configured library whose drive is not mounted: wait for it instead of showing first-run setup.
                libraryState = .volumeMissing(path: l.root.path)
            }
        }
    }

    /// Reconnects automatically when the library's drive is plugged back in; parks the app when it is pulled.
    private func watchVolumes() {
        let nc = NSWorkspace.shared.notificationCenter
        volumeObservers.append(nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, case .volumeMissing(let path) = self.libraryState, LibraryLayout.looksLikeLibrary(URL(fileURLWithPath: path)) else { return }
            Task { @MainActor in
                do { try self.openLibrary(at: URL(fileURLWithPath: path, isDirectory: true)); await self.startHelpers(); self.banner = nil } catch { self.banner = error.userFacing }
            }
        })
        volumeObservers.append(nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let root = self.layout?.root, !FileManager.default.fileExists(atPath: root.path) else { return }
            Task { @MainActor in self.libraryWentAway(root) }
        })
    }

    private func libraryWentAway(_ root: URL) {
        kiwix.stop(); llama.stop(); downloads.cancelAll(); shareServer?.stop(); isSharing = false
        chat.setClient(nil, modelName: nil)
        layout = nil; database = nil
        libraryState = .volumeMissing(path: root.path)
    }

    private func memoryPressureChanged(_ level: MemoryPressureMonitor.Level) {
        memoryLevel = level
        if level == .critical, llama.isRunning {
            llama.stop(); chat.setClient(nil, modelName: nil)
            banner = UserFacingError("AI model unloaded", message: "macOS reported critical memory pressure, so the model was unloaded to keep the rest of the library responsive.", recovery: "Close other heavy apps, then open Chat again to reload it.")
            llmRequested = false
        }
    }

    /// Used by the Chat tab: on low-memory Macs (or when the user asks) the model loads on first use, not at launch.
    func ensureLLMLoaded() {
        guard layout != nil, !llama.isRunning, llama.processState != .starting else { return }
        llmRequested = true
        Task { await startLLM() }
    }

    func checkHelperBinaries() {
        var w: [String] = []
        for b in HelperBinary.allCases {
            guard let loc = b.locate() else {
                #if DEBUG
                w.append("\(b.rawValue) is not bundled — run scripts/fetch_binaries.sh --allow-rosetta and rebuild.")
                #else
                w.append("A required component (\(b.rawValue)) is missing from this copy of OfflineVault. Please reinstall the app.")
                #endif
                continue
            }
            if loc.isSystemFallback { w.append("Using the system copy of \(b.rawValue) instead of the bundled one.") }
        }
        helperWarnings = w
    }

    /// For a folder the user picked that is not already a library, the library is created inside it as
    /// "OfflineVault Library" so ~/Documents is never littered with zim/, index/, staging/.
    static func libraryRoot(forChosenFolder url: URL) -> URL {
        if LibraryLayout.looksLikeLibrary(url) || url.lastPathComponent == "OfflineVault Library" { return url }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { !$0.hasPrefix(".") } ?? []
        return contents.isEmpty ? url : url.appendingPathComponent("OfflineVault Library", isDirectory: true)
    }

    /// Opens (or creates) a library folder and wires every service to it.
    func openLibrary(at root: URL) throws {
        let l = LibraryLayout(root: root)
        try l.ensureDirectories()
        let db = try IndexDatabase(url: l.databaseURL)
        layout = l; database = db
        libraryState = .ready
        let maint = LibraryMaintenance(layout: l, database: db)
        maintenance = maint
        Task.detached(priority: .utility) { [weak self] in
            let problems = maint.quickCheck()
            if !problems.isEmpty { await MainActor.run { self?.banner = UserFacingError("Search index needs repair", message: "The database reported: \(problems.first ?? "").", recovery: "Open Maintenance in the sidebar and choose Rebuild Index. Your files are untouched; chat history is kept.") } }
        }
        scenariosScreen.attach(db)
        if VolumeInfo.isLocal(root) == false {
            banner = UserFacingError("Library is on a network share", message: "The database cannot safely run on a network volume, and the share will not be there in an outage.", recovery: "Move the library to this Mac or a USB drive (Settings › General › Choose a Different Library).")
        }
        settings.libraryPath = root.path
        updateService = UpdateService(layout: l, database: db, baseURL: Config.updatesBaseURL)
        pageService = PageService(layout: l, database: db)
        let ds = DocumentService(layout: l, database: db)
        documentService = ds
        let vl = VideoLibraryService(layout: l, database: db)
        videoLibrary = vl
        youtube = YouTubeService(layout: l, library: vl)
        mapsService = MapsService(layout: l)
        backupService = BackupService(layout: l, database: db)
        importer = LibraryImporter(layout: l, documents: ds, pages: pageService!, videos: vl)
        shareServer?.stop(); isSharing = false
        shareServer = LocalShareServer(layout: l, database: db)
        entitlement = EntitlementService(verifier: try LicenceVerifier(keys: Config.licencePublicKeys), layout: l, issuer: LicenceActivationClient(), settings: settings)
        seats = nil
        chat.configure(store: ChatStore(database: db), coordinator: .standard(reference: kiwix, documents: ds, pages: pageService!, videos: vl, books: { [weak db] in (try? db?.zimBooks()) ?? [] }))
        refreshLibraryState()
        _ = try? pageService?.rescanFolder()
        _ = try? vl.rescanFolder()
        Task.detached(priority: .utility) { [ds] in _ = try? ds.rescanFolder() }
    }

    private var storageTask: Task<Void, Never>?
    func refreshLibraryState() {
        guard let layout, let database else { return }
        books = (try? database.zimBooks()) ?? []
        installed = (try? database.installedArtefacts()) ?? []
        models = LocalModel.scan(layout.models, installed: installed)
        licenceStatus = entitlement?.currentStatus() ?? .none
        entitlements = Entitlements.resolve(status: licenceStatus, source: UpdateSource(baseURL: Config.updatesBaseURL))
        updateService?.baseURL = Config.updatesBaseURL
        libraryGeneration += 1
        // Walking a 100 GB library for sizes is slow on USB drives: do it off the main thread.
        storageTask?.cancel()
        storageTask = Task.detached(priority: .utility) { [weak self] in
            let report = layout.storageReport()
            await MainActor.run { self?.storage = report }
        }
    }

    /// Bumps whenever library contents change; screens observe this instead of every model change.
    @Published var libraryGeneration = 0

    // MARK: Helpers

    func startHelpers() async {
        await startKiwix()
        if settings.loadModelOnDemand && !llmRequested { chat.setClient(nil, modelName: nil); return }
        await startLLM()
    }

    func startKiwix() async {
        guard let layout else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(at: layout.zim, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "zim" }
        guard !files.isEmpty else { kiwix.stop(); referenceBooks = []; return }
        do {
            try await kiwix.start(zimFiles: files)
            damagedBooks = kiwix.damagedFiles.map { (file: $0.key.lastPathComponent, reason: $0.value) }.sorted { $0.file < $1.file }
            referenceBooks = try await kiwix.books()
            // Enrich DB rows with engine-reported titles.
            for b in referenceBooks {
                if let row = books.first(where: { $0.name == b.name }) {
                    var r = row; r.title = r.title ?? b.title; r.description = r.description ?? b.description; r.language = r.language ?? b.language; r.articleCount = r.articleCount ?? b.articleCount; r.mediaCount = b.mediaCount; r.updatedAt = b.updated ?? r.updatedAt
                    try? database?.upsertZimBook(r)
                } else if let f = files.first(where: { $0.deletingPathExtension().lastPathComponent == b.name }) {
                    try? database?.upsertZimBook(ZimBook(name: b.name, fileName: f.lastPathComponent, title: b.title, description: b.description, language: b.language, articleCount: b.articleCount, mediaCount: b.mediaCount, updatedAt: b.updated))
                }
            }
            books = (try? database?.zimBooks()) ?? books
        } catch { banner = error.userFacing }
    }

    var selectedModel: LocalModel? {
        if let f = settings.selectedModelFile, let m = models.first(where: { $0.id == f }) { return m }
        if let def = models.first(where: { $0.artefactId == Config.defaultModelArtefactId }) { return def }
        return models.first
    }

    func startLLM() async {
        guard let model = selectedModel else { llama.stop(); chat.setClient(nil, modelName: nil); return }
        do {
            try await llama.start(model: model)
            chat.setClient(llama.makeClient(), modelName: model.displayName, profile: model.profile)
        } catch {
            chat.setClient(nil, modelName: nil)
            banner = error.userFacing
        }
    }

    func selectModel(_ m: LocalModel) {
        settings.selectedModelFile = m.id
        Task { await startLLM() }
    }

    func restartHelper(_ b: HelperBinary) {
        Task {
            switch b {
            case .kiwixServe: kiwix.stop(); await startKiwix()
            case .llamaServer: llama.stop(); await startLLM()
            default: break
            }
        }
    }

    // MARK: Updates

    func checkForUpdates(interactive: Bool) async {
        guard let svc = updateService else { if interactive { banner = UserFacingError("No library", message: "Choose a library folder first.") }; return }
        svc.baseURL = Config.updatesBaseURL
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        // A refreshed licence must be seen before the diff is gated.
        await entitlement?.refreshIfDue()
        refreshLibraryState()
        do {
            let fetched = try await svc.fetchManifest()
            let diff = try svc.diff(fetched.manifest)
            svc.cleanStaging(keeping: diff.changes.map(\.artefact))
            updateCheck = UpdateCheck(manifest: fetched.manifest, trust: fetched.trust, diff: diff, checkedAt: Date())
            if interactive || !diff.isEmpty { showUpdateSheet = true }
        } catch {
            if interactive { banner = error.userFacing }
        }
    }

    /// The one place downloads start. Setup, the updates sheet and the model offer all come through here.
    func applyUpdates(_ changes: [ManifestDiff.Change]) {
        guard let check = updateCheck else { return }
        let (allowed, denied) = entitlements.partition(changes)
        if let (_, d) = denied.first { show(d) }
        guard !allowed.isEmpty else { return }
        downloads.enqueue(changes: allowed, manifestVersion: check.manifest.version)
        section = .downloads
    }

    func show(_ denial: Denial) {
        let recovery: String
        switch denial.fix {
        case .buy: recovery = "See plans and prices at \(Config.pricingURL.host ?? "offlinevault"), or activate a key in Settings › Licence."
        case .activate: recovery = "Buy a year of refreshes on the website with your key; the app picks the new date up on its own when online."
        case .upgrade: recovery = "Upgrade to Household on the website; your key stays the same."
        }
        let b = UserFacingError(denial.title, message: denial.message, recovery: recovery)
        bannerFixes[b] = denial.fix
        banner = b
    }

    private func artefactInstalled(_ a: Artefact) async {
        refreshLibraryState()
        switch a.kind {
        case .zim: await startKiwix()
        case .model: if llama.loadedModel == nil { await startLLM() }
        case .pagePack: _ = try? pageService?.rescanFolder()
        case .documentPack: if let ds = documentService { await Task.detached(priority: .utility) { _ = try? ds.rescanFolder() }.value }
        case .videoPack: _ = try? videoLibrary?.rescanFolder()
        case .map: libraryGeneration += 1
        case .catalogue: break
        }
        chat.refreshRetrieverAvailability()
    }

    // MARK: Sharing

    func setSharing(_ on: Bool) {
        guard let server = shareServer else { return }
        if on {
            // Only turning sharing on consults the plan; sharing already running is never switched off by it.
            if let d = entitlements.sharingDenial { show(d); return }
            do {
                try server.start()
                // kiwix-serve must listen on all interfaces for phones to open reference books.
                Task { await restartKiwix(lan: true) }
                isSharing = true
            } catch { banner = error.userFacing }
        } else {
            server.stop(); isSharing = false
            Task { await restartKiwix(lan: false) }
        }
    }

    private func restartKiwix(lan: Bool) async {
        kiwix.listenOnAllInterfaces = lan
        kiwix.stop()
        await startKiwix()
    }

    // MARK: Licence

    func importLicence(from url: URL) {
        guard let entitlement else { return }
        do { _ = try entitlement.importLicence(from: url); seats = nil; refreshLibraryState() } catch { banner = error.userFacing }
    }

    static let malformedKey = UserFacingError("That does not look like an OfflineVault key", message: "Keys read OV-XXXX-XXXX-XXXX-XXXX and use no 0, O, 1 or I.", recovery: "Copy it from your receipt page.")

    /// Activates a typed or confirmed key. A different key than the one this Mac holds replaces it and frees the old seat.
    func activateLicence(key input: String) async {
        guard let key = LicenceKey(userInput: input) else { banner = Self.malformedKey; return }
        guard let entitlement else { banner = UserFacingError("No library yet", message: "Choose where to keep the library first; the key is kept for you.", recovery: nil); settings.pendingActivationKey = key.rawValue; return }
        activating = true; defer { activating = false }
        do {
            _ = try await entitlement.switchActivation(to: key)
            settings.pendingActivationKey = nil
            refreshLibraryState()
            await refreshSeats()
        } catch let e as ActivationError { banner = e.userFacing } catch { banner = error.userFacing }
    }

    func refreshSeats() async {
        guard let entitlement, entitlement.activationKey != nil else { seats = nil; return }
        if let s = try? await entitlement.seats() { seats = s; refreshLibraryState() }
    }

    /// Frees a seat. Deactivating this Mac also removes the licence here.
    func deactivate(deviceId: String) async {
        guard let entitlement else { return }
        activating = true; defer { activating = false }
        do { seats = try await entitlement.deactivate(deviceId: deviceId); refreshLibraryState() }
        catch let e as ActivationError { banner = e.userFacing } catch { banner = error.userFacing }
    }

    func removeLicence() {
        entitlement?.removeLicence(); seats = nil; refreshLibraryState()
    }

    func buyLicence() { NSWorkspace.shared.open(Config.pricingURL) }

    /// `offlinevault://activate?key=OV-...` from the receipt page. Any web page can open this URL, so nothing
    /// activates until the user confirms in RootView's alert. With no library open yet the key is parked for Setup.
    func handle(url: URL) {
        guard url.scheme == "offlinevault", url.host == "activate",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value else { return }
        guard let key = LicenceKey(userInput: raw) else { banner = Self.malformedKey; return }
        guard entitlement != nil else { settings.pendingActivationKey = key.rawValue; return }
        pendingURLActivation = key
    }

    /// What confirming `key` does to this Mac, for the alert.
    func urlActivationMessage(for key: LicenceKey) -> String {
        if entitlement?.activationKey == key { return "This Mac already uses this key. Activating again refreshes its licence." }
        if let plan = entitlements.plan { return "This replaces the \(plan.title) licence on this Mac and frees its seat on that plan. Everything installed keeps working." }
        return "Activation needs internet once. This Mac then has the plan the key belongs to."
    }

    func confirmURLActivation(_ key: LicenceKey) {
        pendingURLActivation = nil
        section = .settings; settingsTab = .licence
        Task { await activateLicence(key: key.rawValue) }
    }

    // MARK: Navigation

    func open(_ ref: SourceRef, highlight: String? = nil) {
        pendingHighlight = nil
        switch ref {
        case .zimArticle(let book, let path, _): pendingArticle = (book, path); pendingHighlight = highlight; section = .library
        case .page(let id, _, _): pendingPageId = id; pendingHighlight = highlight; section = .pages
        case .video(let id, _, let s): pendingVideo = (id, s); section = .videos
        case .document(let id, _, let page): pendingDocument = (id, page); section = .documents
        }
    }

    func takePendingHighlight() -> String? { defer { pendingHighlight = nil }; return pendingHighlight }

    // MARK: Readiness & maintenance

    func runReadiness() {
        guard let layout, let database, !readinessRunning else { return }
        readinessRunning = true
        let deps = ReadinessCheck.Dependencies(layout: layout, database: database, reference: kiwix, llm: llama.isRunning ? llama.makeClient() : nil, llmModelName: llama.loadedModel?.displayName,
                                               coordinator: chat.coordinator, backupService: backupService, entitlements: entitlements, licence: licenceStatus.licence, kiwixState: kiwixState, llamaState: llamaState)
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = await ReadinessCheck(deps: deps).run { r in Task { @MainActor in self?.readinessReport = r } }
            await MainActor.run { self?.readinessReport = report; self?.readinessRunning = false; try? database.setValue(Self.readinessSummary(report), forKey: "readiness.last") }
        }
    }

    static func readinessSummary(_ r: ReadinessReport) -> String {
        let c = r.counts
        return "\(ISO8601DateFormatter().string(from: r.finishedAt ?? Date()))|\(r.overall.rawValue)|\(c.pass)|\(c.warn)|\(c.fail)"
    }

    /// Fix actions offered by readiness items.
    func performFix(_ id: String) {
        switch id {
        case "install-rosetta": installRosetta()
        case "backup": section = .backup
        case "licence": section = .settings; settingsTab = .licence
        case "buy": buyLicence()
        case "maps": section = .maps
        case "updates": Task { await checkForUpdates(interactive: true) }
        case "rebuild-index", "verify": section = .maintenance
        case "restart-kiwix": restartHelper(.kiwixServe)
        case "restart-llm": llmRequested = true; restartHelper(.llamaServer)
        case "reinstall": banner = UserFacingError("Components missing", message: "This copy of OfflineVault is incomplete.", recovery: "Download OfflineVault again and reinstall it.")
        default: break
        }
    }

    @Published var installingRosetta = false
    func installRosetta() {
        guard !installingRosetta else { return }
        installingRosetta = true
        Task.detached { [weak self] in
            let script = NSAppleScript(source: "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges")
            var err: NSDictionary?
            script?.executeAndReturnError(&err)
            let message = err?["NSAppleScriptErrorMessage"] as? String
            await MainActor.run {
                guard let self else { return }
                self.installingRosetta = false
                self.rosettaMissing = RosettaStatus.neededByHelpers && !RosettaStatus.isInstalled()
                if let message, self.rosettaMissing { self.banner = UserFacingError("Rosetta was not installed", message: message, recovery: "Try again while online, or run in Terminal: softwareupdate --install-rosetta --agree-to-license") }
                else if !self.rosettaMissing { Task { await self.startKiwix() } }
            }
        }
    }

    /// Writes a support bundle (versions, helper output, readiness summary, index stats) to a folder of the user's choice.
    func exportDiagnostics(to folder: URL) throws -> URL {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let out = folder.appendingPathComponent("OfflineVault-diagnostics-\(f.string(from: Date()).replacingOccurrences(of: ":", with: "-")).txt")
        var t = "OfflineVault \(Config.appVersion) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · RAM \(ByteFormat.string(MemoryPressureMonitor.physicalMemoryBytes))\n"
        t += "Library: \(layout?.root.path ?? "none") · state \(String(describing: libraryState))\n"
        t += "Helpers: " + HelperBinary.allCases.map { "\($0.rawValue)=\($0.locate()?.url.path ?? "missing")" }.joined(separator: "; ") + "\n"
        if let v = Bundle.main.resourceURL.flatMap({ try? String(contentsOf: $0.appendingPathComponent("bin/VERSIONS.txt"), encoding: .utf8) }) { t += v + "\n" }
        t += "Rosetta needed: \(RosettaStatus.neededByHelpers) installed: \(RosettaStatus.isInstalled())\n"
        t += "kiwix: \(kiwixState.label) · llama: \(llamaState.label) (\(llama.loadedModel?.displayName ?? "none"))\n"
        t += "Damaged books: \(damagedBooks.map { "\($0.file): \($0.reason)" }.joined(separator: "; "))\n"
        t += "Installed artefacts: \(installed.map { "\($0.id)@\($0.manifestVersion ?? "?")" }.joined(separator: ", "))\n"
        t += "Licence: \(licenceStatus.summary) · plan \(entitlements.label) · source \(String(describing: entitlements.source))\n"
        if let r = readinessReport { t += "\nREADINESS (\(r.overall.rawValue)):\n" + r.items.map { "  [\($0.status.rawValue)] \($0.title): \($0.detail)" }.joined(separator: "\n") + "\n" }
        t += "\n--- kiwix-serve output ---\n\(kiwix.recentOutput)\n\n--- llama-server output ---\n\(llama.recentOutput)\n"
        try t.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    // MARK: World map

    /// The Protomaps daily planet build: one PMTiles file with full street detail for the whole world (~130 GB).
    static var planetBuildURL: URL {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.timeZone = TimeZone(identifier: "UTC")
        return URL(string: "https://build.protomaps.com/\(f.string(from: Date().addingTimeInterval(-86400))).pmtiles")!
    }
    var fullWorldMapInstalled: Bool { mapsService?.maps().contains { ($0.header?.maxZoom ?? 0) >= 14 && (($0.header?.maxLon ?? 0) - ($0.header?.minLon ?? 0)) > 300 } ?? false }
    var fullWorldMapDownloading: Bool { downloads.items.contains { $0.id == "file:world-full.pmtiles" && $0.state != .completed } }

    /// Starts (or resumes) the full-detail world map download after confirming size and free space.
    func downloadFullWorldMap() {
        guard let layout else { return }
        Task {
            do {
                let url = Self.planetBuildURL
                let size = try await ResumableDownloader.remoteSize(of: url)
                guard layout.hasSpace(forAdditionalBytes: size) else {
                    banner = UserFacingError("Not enough space for the full world map", message: "It is \(ByteFormat.string(size)); the library drive has \(ByteFormat.string(layout.volumeCapacity().free)) free.", recovery: "Move the library to a larger external SSD (Settings › General), then try again.")
                    return
                }
                guard Panels.confirm("Download the full-detail world map?", message: "\(ByteFormat.string(size)) with street-level detail for the whole planet. It downloads in the background, resumes after interruptions, and the map works offline afterwards. Free: \(ByteFormat.string(layout.volumeCapacity().free)).", button: "Download") else { return }
                downloads.enqueue(fileURL: url, destination: layout.maps.appendingPathComponent("world-full.pmtiles"), sizeBytes: size, title: "World map — full street detail")
                section = .downloads
            } catch { banner = error.userFacing }
        }
    }

    // MARK: Drag & drop / file import

    /// Routes a dropped file or folder to the right importer.
    func importDropped(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue { showImportSheet = true; NotificationCenter.default.post(name: .importFolderChosen, object: url); return }
        switch url.pathExtension.lowercased() {
        case "pmtiles":
            guard let svc = mapsService else { return }
            mapsScreen.importing = true
            Task.detached(priority: .userInitiated) { [weak self] in
                do { let m = try svc.importMap(from: url); await MainActor.run { self?.mapsScreen.importing = false; self?.mapsScreen.selected = m; self?.libraryGeneration += 1; self?.section = .maps } }
                catch { await MainActor.run { self?.mapsScreen.importing = false; self?.banner = error.userFacing } }
            }
        case "json": importLicence(from: url)
        case "zim":
            banner = UserFacingError("Reference books come from Library updates", message: "Copy the file into the library's zim folder and choose Maintenance › Rebuild Index to add it by hand.", recovery: nil)
        default:
            if DocumentService.supportedExtensions.contains(url.pathExtension.lowercased()) || LibraryImporter.videoExtensions.contains(url.pathExtension.lowercased()) || LibraryImporter.pageExtensions.contains(url.pathExtension.lowercased()) { importFiles([url]) }
            else { banner = UserFacingError("Unsupported file", message: "\(url.lastPathComponent) is not a PDF, EPUB, text, video, web page or map file.") }
        }
    }

    /// Imports a set of files with progress (documents, videos, pages).
    func importFiles(_ urls: [URL]) {
        guard let importer else { return }
        documentsScreen.importing = true; documentsScreen.importProgress = 0; documentsScreen.importStatus = "Importing…"
        Task.detached(priority: .userInitiated) { [weak self] in
            var imported = 0, dup = 0, failed = 0
            var last: LibraryDocument?
            for (i, u) in urls.enumerated() {
                await MainActor.run { self?.documentsScreen.importStatus = "Importing \(u.lastPathComponent)…"; self?.documentsScreen.importProgress = Double(i) / Double(max(urls.count, 1)) }
                do {
                    let ext = u.pathExtension.lowercased()
                    if DocumentService.supportedExtensions.contains(ext) { if let d = try importer.documents.importDocument(from: u) { imported += 1; last = d } else { dup += 1 } }
                    else if LibraryImporter.videoExtensions.contains(ext) { if try importer.importVideo(u, copy: true) { imported += 1 } else { dup += 1 } }
                    else { let dest = importer.layout.pages.appendingPathComponent(u.lastPathComponent); if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: u, to: dest) }; try importer.pages.indexExistingFile(dest, url: nil, title: nil); imported += 1 }
                } catch { failed += 1; await MainActor.run { self?.banner = error.userFacing } }
            }
            await MainActor.run {
                guard let self else { return }
                self.documentsScreen.importing = false; self.documentsScreen.importStatus = nil; self.documentsScreen.importProgress = nil
                self.libraryGeneration += 1
                if let last { self.documentsScreen.selected = last }
                if dup > 0 || urls.count > 1 { self.banner = UserFacingError("Import finished", message: "\(imported) added" + (dup > 0 ? ", \(dup) already in the library" : "") + (failed > 0 ? ", \(failed) failed" : "") + ".", recovery: nil) }
            }
        }
    }

    /// Retrieval without generation (scenario cards' "verify in library").
    func retrievePassages(_ query: String) async -> [RetrievedPassage] { await chat.retrieve(query) }

    func backupReminderText() -> String? {
        guard let b = backupService, b.isReminderDue else { return nil }
        if let d = b.lastBackupDate { return "Your last library backup was \(d.formatted(.relative(presentation: .named))). Plug in the backup drive and verify it (Settings › Backup)." }
        return "No backup of this library yet. Two is one, one is none — clone it to a second drive in Settings › Backup."
    }

    func resetLibrary() {
        kiwix.stop(); llama.stop(); downloads.cancelAll(); shareServer?.stop(); isSharing = false
        settings.libraryPath = nil; settings.setupCompleted = false
        layout = nil; database = nil; books = []; models = []; installed = []
    }
}
