import SwiftUI
import UniformTypeIdentifiers
import OfflineVaultCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadManager
    @State private var showShortcuts = false

    var body: some View {
        Group {
            if model.volumeMissing {
                VolumeMissingView()
            } else if model.needsSetup {
                SetupView()
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    VStack(spacing: 0) {
                        ForEach(model.banners, id: \.self) { b in ErrorBanner(error: b, action: bannerAction(b)) { model.dismiss(b) } }
                        detail
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers) }
            }
        }
        .onOpenURL { model.handle(url: $0) }
        .alert(Text("Activate licence \(model.pendingURLActivation?.masked ?? "")?"), isPresented: Binding(get: { model.pendingURLActivation != nil }, set: { if !$0 { model.pendingURLActivation = nil } }), presenting: model.pendingURLActivation) { key in
            Button("Activate") { model.confirmURLActivation(key) }
            Button("Cancel", role: .cancel) {}
        } message: { key in
            Text(model.urlActivationMessage(for: key))
        }
        .sheet(isPresented: $model.showUpdateSheet) { UpdatesSheet().environmentObject(model) }
        .sheet(isPresented: $model.showImportSheet) { ImportHoardSheet().environmentObject(model) }
        .background(GlobalSearchPresenter(state: model.globalSearch).environmentObject(model))
        .sheet(isPresented: $showShortcuts) { ShortcutsSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .showShortcuts)) { _ in showShortcuts = true }
    }

    func bannerAction(_ b: UserFacingError) -> (title: String, run: () -> Void)? {
        switch model.bannerFixes[b] {
        case .buy?, .upgrade?: return ("See Plans", { model.buyLicence() })
        case .activate?: return ("Open Licence Settings", { model.section = .settings; model.settingsTab = .licence })
        case nil: break
        }
        if b.title.contains("Download") { return ("Show Downloads", { model.section = .downloads }) }
        if b.title.contains("index") { return ("Open Maintenance", { model.section = .maintenance }) }
        if b.title.contains("Rosetta") { return ("Open Maintenance", { model.section = .maintenance }) }
        return nil
    }

    var sidebar: some View {
        List(selection: Binding(get: { Optional(model.section) }, set: { if let s = $0 { model.section = s } })) {
            Section("Knowledge") { ForEach(AppModel.Section.knowledge) { s in sidebarRow(s) } }
            Section("Manage") { ForEach(AppModel.Section.manage) { s in sidebarRow(s) } }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let p = model.layout?.root.lastPathComponent { Label(p, systemImage: "externaldrive").font(.caption).lineLimit(1).truncationMode(.middle) }
                if model.isSharing { Label("Sharing on Wi-Fi", systemImage: "wifi").font(.caption2).foregroundStyle(Color.accentColor) }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder func sidebarRow(_ s: AppModel.Section) -> some View {
        Label(s.title, systemImage: s.systemImage)
            .badge(s == .downloads ? downloads.activeCount : 0)
            .overlay(alignment: .trailing) {
                HStack(spacing: 4) {
                    if s == .chat { StatusDot(state: model.llamaState) }
                    if s == .library { StatusDot(state: model.kiwixState) }
                    if s == .readiness, let r = model.readinessReport { Circle().fill(r.overall == .pass ? Color.green : r.overall == .warn ? Color.orange : Color.red).frame(width: 8, height: 8).accessibilityLabel("Last drill: \(r.overall.rawValue)") }
                }.padding(.trailing, 2)
            }
            .tag(s)
    }

    @ViewBuilder var detail: some View {
        switch model.section {
        case .chat: ChatView()
        case .scenarios: ScenariosView()
        case .library: LibraryView()
        case .documents: DocumentsView()
        case .maps: MapsView()
        case .videos: VideosView()
        case .pages: PagesView()
        case .sources: SourcesView()
        case .downloads: DownloadsView()
        case .readiness: ReadinessView()
        case .backup: BackupView()
        case .share: ShareView()
        case .maintenance: MaintenanceView()
        case .settings: SettingsView()
        }
    }

    /// Files dropped anywhere on the window: PDFs/EPUBs → Documents, .pmtiles → Maps, licence JSON → Settings, folders → import sheet.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in model.importDropped(url) }
            }
        }
        return handled
    }
}

/// Shown when the configured library lives on a drive that is not mounted. Reconnects automatically.
struct VolumeMissingView: View {
    @EnvironmentObject var model: AppModel
    var path: String { if case .volumeMissing(let p) = model.libraryState { return p } else { return "" } }
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.questionmark").font(.system(size: 64)).foregroundStyle(.secondary).symbolEffect(.pulse).accessibilityHidden(true)
            Text("Waiting for your library drive").font(.title.bold())
            Text("Your library is at\n\(path)\nbut that drive is not connected. Plug it in and the library opens by itself.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 480)
            HStack {
                Button("Locate the Library…") {
                    if let u = Panels.chooseFolder(prompt: "Open", message: "Choose the OfflineVault Library folder.") {
                        if LibraryLayout.looksLikeLibrary(u) { do { try model.openLibrary(at: u); Task { await model.startHelpers() } } catch { model.banner = error.userFacing } }
                        else { model.banner = UserFacingError("Not a library", message: "That folder is not an OfflineVault library.", recovery: "Choose the folder named “OfflineVault Library”.") }
                    }
                }
                Button("Start a New Library…") {
                    if Panels.confirm("Start a new library?", message: "The current library on the disconnected drive is left untouched; you can switch back to it later from Settings.", button: "Start New") { model.resetLibrary() }
                }
            }
            ForEach(model.banners, id: \.self) { b in ErrorBanner(error: b) { model.dismiss(b) }.frame(maxWidth: 560) }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// ⌘K: one search across reference books, documents (by page), saved pages and video transcripts.
struct GlobalSearchPresenter: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: GlobalSearchState
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: $state.isPresented) { GlobalSearchBody(state: state).environmentObject(model) }
    }
}

struct GlobalSearchBody: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: GlobalSearchState
    @Environment(\.dismiss) var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search everything in your library", text: $state.query).textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit { if let first = state.results.first { open(first) } }
                if state.searching { ProgressView().controlSize(.small) }
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).keyboardShortcut(.escape, modifiers: []).accessibilityLabel("Close search")
            }.padding(14)
            Divider()
            if state.results.isEmpty {
                VStack(spacing: 6) {
                    Text(state.query.count < 2 ? "Type to search reference books, manuals (by page), saved pages and video transcripts at once." : (state.searching ? "Searching…" : "No matches.")).foregroundStyle(.secondary)
                    Text("Enter opens the first result · Esc closes").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(state.results) { p in
                    Button { open(p) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: p.source.systemImage).foregroundStyle(Color.accentColor).frame(width: 18).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Text(p.source.title).font(.headline).lineLimit(1); Text(subtitle(p)).font(.caption).foregroundStyle(.secondary) }
                                Text(p.text.replacingOccurrences(of: "\n", with: " ")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.frame(minHeight: 320)
            }
        }
        .frame(width: 640)
        .onAppear { focused = true }
        .onChange(of: state.query) { _, _ in state.run { q in await model.chat.retrieve(q) } }
    }

    func subtitle(_ p: RetrievedPassage) -> String {
        switch p.source {
        case .zimArticle(let book, _, _): return "Reference · \(model.books.first { $0.name == book }?.displayTitle ?? book)"
        case .document(_, _, let page): return "Document · page \(page)"
        case .page: return "Saved page"
        case .video(_, _, let s): return "Video" + (s.map { " · \(DurationFormat.string($0))" } ?? "")
        }
    }
    func open(_ p: RetrievedPassage) { dismiss(); model.open(p.source) }
}
