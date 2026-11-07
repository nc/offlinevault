import SwiftUI
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers
import OfflineVaultCore

struct DocumentsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { DocumentsBody(st: model.documentsScreen) }
}

struct DocumentsBody: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var st: DocumentsScreen
    @State private var documents: [LibraryDocument] = []
    @State private var counts: [Subject: Int] = [:]
    @State private var urlField = ""
    @State private var fetcher = BrowserFetcher()
    @FocusState private var searchFocused: Bool

    var filtered: [LibraryDocument] { st.subjectFilter.map { f in documents.filter { ($0.subject ?? .general) == f } } ?? documents }

    var body: some View {
        ListDetail {
            list
        } detail: {
            detail
        }
        .navigationTitle(st.selected?.title ?? "Documents")
        .navigationSubtitle("\(documents.count) documents" + (st.subjectFilter.map { " · \($0.title)" } ?? ""))
        .searchable(text: $st.query, placement: .toolbar, prompt: "Search manuals and books")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Subject", selection: $st.subjectFilter) {
                    Text("All subjects").tag(Subject?.none)
                    ForEach(Subject.allCases.filter { (counts[$0] ?? 0) > 0 }) { s in Label("\(s.title) (\(counts[s] ?? 0))", systemImage: s.systemImage).tag(Subject?.some(s)) }
                }.help("Filter by subject")
                Menu {
                    Button("Import Files…") { importFiles() }
                    Button("Import a Folder…") { model.showImportSheet = true }
                    Button("Download from Link…") { urlField = "https://"; st.importStatus = "" }
                } label: { Label("Import", systemImage: "plus") }.help("Import PDFs, EPUBs or text files")
            }
        }
        .task { reload() }
        .onReceive(model.$libraryGeneration) { _ in reload() }
        .debouncedSearch(st.query) { search() }
        .onChange(of: model.pendingDocument?.id) { _, _ in consumePending() }
        .onChange(of: model.pendingDocument?.page) { _, _ in consumePending() }
        .onReceive(NotificationCenter.default.publisher(for: .importFiles)) { _ in importFiles() }
        .onAppear { consumePending() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers { p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { Task { @MainActor in model.importDropped(u) } } } }
            return !providers.isEmpty
        }
    }

    var list: some View {
        VStack(spacing: 0) {
            if st.importStatus != nil {
                HStack {
                    TextField("Paste a link to a PDF (or a page that links one)", text: $urlField).textFieldStyle(.roundedBorder).onSubmit { importFromURL() }
                    if st.importing { ProgressView().controlSize(.small); Button("Cancel") { fetcher.cancel() }.controlSize(.small) } else { Button("Download") { importFromURL() }.disabled(urlField.count < 8) }
                    Button { st.importStatus = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close")
                }.padding(8)
                if let s = st.importStatus, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 6) }
                Divider()
            } else if st.importing, let s = st.importStatus ?? Optional("Importing…") {
                HStack { ProgressView(value: st.importProgress ?? 0).frame(width: 140); Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }.padding(8); Divider()
            }
            if documents.isEmpty {
                EmptyState(icon: "doc.richtext", title: "No documents yet", message: "Field manuals, first-aid guides and books. Drop PDFs or EPUBs here, import a whole folder, or install the government document pack from Library updates. Every page is indexed, so the assistant can cite “page 47”.", action: ("Import a Folder…", { model.showImportSheet = true }))
            } else if !st.query.trimmingCharacters(in: .whitespaces).isEmpty {
                List(st.hits) { h in
                    Button { open(h.document, unit: h.page) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(h.document.title).font(.headline).lineLimit(1); Spacer(); Text("\(h.document.unitLabel) \(h.page)").font(.caption).foregroundStyle(.secondary) }
                            Text(h.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.overlay { if st.hits.isEmpty { Text("No matches").foregroundStyle(.secondary) } }
            } else {
                List(filtered, selection: $st.selected) { d in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.title).font(.headline).lineLimit(2)
                        HStack(spacing: 6) {
                            Label((d.subject ?? .general).title, systemImage: (d.subject ?? .general).systemImage).font(.caption).foregroundStyle(.secondary)
                            Meta([d.publisher, "\(d.pageCount) \(d.unitLabel)s", ByteFormat.string(d.sizeBytes), d.kind == .pdf ? nil : d.kind.rawValue.uppercased()])
                        }
                        if let s = d.summary { Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                    }.tag(d)
                    .contextMenu {
                        Menu("Subject") { ForEach(Subject.allCases) { sub in Button(sub.title) { try? model.documentService?.setSubject(sub, for: d); reload() } } }
                        Button("Quick Look") { quickLook(d) }
                        if let u = d.sourceURL { Button("Copy Source Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string) } }
                        Button("Show in Finder") { if let svc = model.documentService { NSWorkspace.shared.activateFileViewerSelecting([svc.fileURL(for: d)]) } }
                        Divider()
                        Button("Move to Trash…", role: .destructive) { delete(d) }
                    }
                }
                .onDeleteCommand { if let d = st.selected { delete(d) } }
            }
        }
    }

    @ViewBuilder var detail: some View {
        if let d = st.selected, let svc = model.documentService {
            if d.kind == .pdf { PDFViewer(url: svc.fileURL(for: d), page: st.targetUnit) } else { TextDocumentViewer(document: d, service: svc, unit: st.targetUnit) }
        } else {
            EmptyState(icon: "doc.richtext", title: "Choose a document", message: "Pages open here with no internet. A source clicked in Chat opens the exact page.")
        }
    }

    func delete(_ d: LibraryDocument) {
        guard Panels.confirm("Move “\(d.title)” to the Trash?", message: "\(ByteFormat.string(d.sizeBytes)) · the file goes to the Trash and its pages leave the search index.", button: "Move to Trash") else { return }
        do { try model.documentService?.delete(d); if st.selected?.id == d.id { st.selected = nil }; reload() } catch { model.banner = error.userFacing }
    }
    func quickLook(_ d: LibraryDocument) { if let svc = model.documentService { QuickLook.show([svc.fileURL(for: d)]) } }
    func consumePending() {
        guard let p = model.pendingDocument, let svc = model.documentService, let d = try? svc.document(id: p.id) else { return }
        model.pendingDocument = nil; reload(); open(d, unit: p.page)
    }
    func open(_ d: LibraryDocument, unit: Int?) { st.targetUnit = unit; st.selected = d }
    func reload() { documents = (try? model.documentService?.documents()) ?? []; counts = (try? model.documentService?.subjectCounts()) ?? [:]; search() }
    func search() { st.hits = (try? model.documentService?.search(st.query)) ?? [] }

    func importFiles() {
        let urls = Panels.chooseFiles(types: ["pdf", "epub", "txt", "md"], prompt: "Import", multiple: true, message: "Choose PDFs, EPUBs or text files to add to your library.")
        guard !urls.isEmpty else { return }
        model.importFiles(urls)
    }

    func importFromURL() {
        var s = urlField.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), url.host != nil, let svc = model.documentService, let layout = model.layout else { model.banner = UserFacingError("Not a valid link", message: "“\(urlField)” is not a web address."); return }
        st.importing = true; st.importStatus = "Fetching from \(url.host ?? "")…"
        Task {
            do {
                let file = try await fetcher.download(url, into: layout.staging)
                st.importStatus = "Indexing \(file.lastPathComponent)…"
                let doc = try await Task.detached(priority: .userInitiated) { try svc.importPDF(from: file) }.value
                try? FileManager.default.removeItem(at: file)
                if var side = try? JSONDecoder().decode(DocumentSidecar.self, from: Data(contentsOf: svc.fileURL(for: doc).deletingPathExtension().appendingPathExtension("json"))) {
                    side.sourceURL = url.absoluteString
                    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try? enc.encode(side).write(to: svc.fileURL(for: doc).deletingPathExtension().appendingPathExtension("json"))
                }
                urlField = ""; st.importStatus = nil; reload(); st.selected = doc
            } catch { st.importStatus = nil; model.banner = error.userFacing }
            st.importing = false
        }
    }
}

enum QuickLook {
    static var urls: [URL] = []
    static let dataSource = Source()
    final class Source: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { QuickLook.urls.count }
        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { QuickLook.urls[index] as NSURL }
    }
    @MainActor static func show(_ u: [URL]) {
        urls = u
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = dataSource; panel.delegate = dataSource
        panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
}

struct PDFViewer: NSViewRepresentable {
    let url: URL
    let page: Int?
    final class Coordinator { var lastURL: URL?; var lastPage: Int? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView(); v.autoScales = true; v.displayMode = .singlePageContinuous; v.displayDirection = .vertical; v.backgroundColor = .windowBackgroundColor
        v.setAccessibilityLabel("Document")
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        if context.coordinator.lastURL != url { v.document = PDFDocument(url: url); context.coordinator.lastURL = url; context.coordinator.lastPage = nil }
        if let page, page != context.coordinator.lastPage, let doc = v.document, page >= 1, page <= doc.pageCount, let p = doc.page(at: page - 1) { v.go(to: p); context.coordinator.lastPage = page }
    }
}

/// Reader for EPUB chapters and text files.
struct TextDocumentViewer: View {
    let document: LibraryDocument
    let service: DocumentService
    let unit: Int?
    @State private var current = 1
    @State private var text = ""
    var body: some View {
        HSplitView {
            if document.pageCount > 1 {
                List(1...max(document.pageCount, 1), id: \.self, selection: Binding(get: { Optional(current) }, set: { if let c = $0 { current = c } })) { i in Text("\(document.unitLabel.capitalized) \(i)").tag(i) }.frame(minWidth: 140, idealWidth: 160, maxWidth: 220)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(document.title).font(.title3.bold()); Spacer(); Button { PDFExport.printText(document.title + "\n\n" + text, title: document.title) } label: { Label("Print / Save PDF", systemImage: "printer") }.keyboardShortcut("p", modifiers: .command) }
                    Text(text.isEmpty ? "(no text in this \(document.unitLabel))" : text).font(.body).textSelection(.enabled).frame(maxWidth: 720, alignment: .leading)
                }.padding(16)
            }
        }
        .onAppear { current = unit ?? 1; load() }
        .onChange(of: current) { _, _ in load() }
        .onChange(of: unit) { _, u in if let u { current = u } }
        .onChange(of: document.id) { _, _ in current = unit ?? 1; load() }
    }
    func load() { text = service.text(of: document, unit: current) }
}
