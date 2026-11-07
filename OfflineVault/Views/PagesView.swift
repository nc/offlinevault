import SwiftUI
import UniformTypeIdentifiers
import OfflineVaultCore

struct PagesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { PagesBody(st: model.pagesScreen) }
}

struct PagesBody: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var st: PagesScreen
    @StateObject private var bridge = ReaderBridge()
    @State private var pages: [SavedPage] = []
    @State private var showAdd = false

    var body: some View {
        ListDetail { list } detail: { detail }
        .navigationTitle(st.selected?.title ?? "Saved Pages")
        .navigationSubtitle("\(pages.count) pages · stored offline")
        .searchable(text: $st.query, placement: .toolbar, prompt: "Search saved pages")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showAdd = true } label: { Label("Save a Page", systemImage: "plus") }.help("Save a web page for offline reading")
                Button { if let p = st.selected { refresh(p) } } label: { Label("Refresh from Source", systemImage: "arrow.clockwise") }.disabled(st.selected == nil || st.capturing).help("Re-capture this page (needs internet)")
                Button { bridge.print() } label: { Label("Print", systemImage: "printer") }.disabled(st.selected == nil).keyboardShortcut("p", modifiers: .command)
            }
        }
        .popover(isPresented: $showAdd) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Save a web page").font(.headline)
                TextField("https://…", text: $st.newURL).textFieldStyle(.roundedBorder).frame(width: 360).onSubmit { capture() }
                Text("The page is stored as a single file with images; scripts and trackers are removed, and it opens with no internet.").font(.caption).foregroundStyle(.secondary).frame(width: 360)
                HStack { Spacer(); Button("Cancel") { showAdd = false }; Button("Save") { capture() }.buttonStyle(.borderedProminent).disabled(st.newURL.isEmpty || st.capturing) }
            }.padding(16)
        }
        .task { reload() }
        .onReceive(model.$libraryGeneration) { _ in reload() }
        .debouncedSearch(st.query) { search() }
        .onChange(of: model.pendingPageId) { _, _ in consumePending() }
        .onAppear { consumePending() }
        .onDrop(of: [.url, .fileURL], isTargeted: nil) { providers in
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                p.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                    if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil), u.scheme?.hasPrefix("http") == true { Task { @MainActor in st.newURL = u.absoluteString; capture() } }
                    else if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil), u.isFileURL { Task { @MainActor in model.importDropped(u) } }
                }
            }
            return true
        }
    }

    var list: some View {
        Group {
            if st.capturing { HStack { ProgressView().controlSize(.small); Text("Saving page…").font(.caption).foregroundStyle(.secondary) }.padding(8) }
            if pages.isEmpty {
                EmptyState(icon: "doc.text", title: "No saved pages", message: "Save how-to articles, forum posts and guides you want to keep. Drag a link from Safari here, or click Save a Page.", action: ("Save a Page…", { showAdd = true }))
            } else if !st.query.trimmingCharacters(in: .whitespaces).isEmpty {
                List(st.hits, selection: Binding(get: { st.selected?.id }, set: { id in st.selected = pages.first { $0.id == id } })) { h in
                    VStack(alignment: .leading, spacing: 2) { Text(h.page.title).font(.headline).lineLimit(1); Text(h.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(3) }.tag(h.page.id)
                }.overlay { if st.hits.isEmpty { Text("No matches").foregroundStyle(.secondary) } }
            } else {
                List(pages, selection: $st.selected) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.title.isEmpty ? p.url.host ?? "Page" : p.title).font(.headline).lineLimit(1)
                        Text(p.url.host ?? p.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack { Meta(["Saved \(p.capturedAt.formatted(date: .abbreviated, time: .omitted))", ByteFormat.string(p.sizeBytes)]); if let e = p.lastError { Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1) } }
                    }.tag(p)
                    .contextMenu {
                        Button("Refresh from Source") { refresh(p) }
                        Button("Copy Original Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p.url.absoluteString, forType: .string) }
                        Divider()
                        Button("Move to Trash…", role: .destructive) { delete(p) }
                    }
                }
                .onDeleteCommand { if let p = st.selected { delete(p) } }
            }
        }
    }

    @ViewBuilder var detail: some View {
        if let p = st.selected, let svc = model.pageService, let layout = model.layout {
            VStack(spacing: 0) {
                HStack { Text(p.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled); Spacer(); Label("Offline copy", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary) }.padding(8)
                Divider()
                WebView(url: svc.fileURL(for: p), mode: .localFile(readAccess: layout.pages), onNavigationState: { _, _ in bridge.highlight(model.takePendingHighlight()) }, bridge: bridge)
            }
        } else {
            EmptyState(icon: "doc.richtext", title: "Choose a page", message: "Saved pages open from disk and look the same with the internet down.")
        }
    }

    func delete(_ p: SavedPage) {
        guard Panels.confirm("Move “\(p.title)” to the Trash?", message: "The saved copy goes to the Trash and leaves the search index.", button: "Move to Trash") else { return }
        try? model.pageService?.delete(p); if st.selected?.id == p.id { st.selected = nil }; reload()
    }
    func consumePending() { guard let id = model.pendingPageId else { return }; model.pendingPageId = nil; reload(); st.selected = pages.first { $0.id == id } }
    func reload() { pages = (try? model.pageService?.pages()) ?? []; search() }
    func search() { st.hits = (try? model.pageService?.search(st.query)) ?? [] }
    func capture() {
        var s = st.newURL.trimmingCharacters(in: .whitespacesAndNewlines); if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), url.host != nil, let svc = model.pageService else { model.banner = UserFacingError("Not a valid link", message: "“\(st.newURL)” is not a web address."); return }
        st.capturing = true; showAdd = false
        Task {
            defer { st.capturing = false }
            do { let p = try await svc.capture(url); st.newURL = ""; reload(); st.selected = p }
            catch {
                var e = error.userFacing
                if e.message.contains("HTTP 403") || e.message.contains("HTTP 429") { e = UserFacingError("This site blocks automatic saving", message: e.message, recovery: "Open the page in Safari and choose File › Export as PDF, then drop the PDF on Documents.") }
                model.banner = e
            }
        }
    }
    func refresh(_ p: SavedPage) {
        guard let svc = model.pageService else { return }
        st.capturing = true
        Task { defer { st.capturing = false }; do { let np = try await svc.refresh(p); reload(); st.selected = np } catch { model.banner = error.userFacing; reload() } }
    }
}
