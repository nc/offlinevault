import SwiftUI
import OfflineVaultCore

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { LibraryBody(st: model.libraryScreen) }
}

struct LibraryBody: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var st: LibraryScreen
    @StateObject private var bridge = ReaderBridge()
    @FocusState private var searchFocused: Bool
    @State private var findVisible = false

    var body: some View {
        ListDetail {
            bookList
        } detail: {
            reader
        }
        .navigationTitle(st.articleTitle.isEmpty ? "Reference" : st.articleTitle)
        .navigationSubtitle(st.articleTitle.isEmpty ? "\(model.books.count) books" : (st.selectedBook?.displayTitle ?? ""))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { bridge.back() } label: { Label("Back", systemImage: "chevron.left") }.disabled(!st.canGoBack).help("Back")
                Button { bridge.forward() } label: { Label("Forward", systemImage: "chevron.right") }.disabled(!st.canGoForward).help("Forward")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { findVisible.toggle() } label: { Label("Find in Article", systemImage: "doc.text.magnifyingglass") }.disabled(st.articleURL == nil).help("Find in article")
                Menu { Button("Smaller") { st.zoom = max(0.6, st.zoom - 0.1) }; Button("Actual Size") { st.zoom = 1 }; Button("Larger") { st.zoom = min(2.0, st.zoom + 0.1) } } label: { Label("Text Size", systemImage: "textformat.size") }.disabled(st.articleURL == nil)
                Button { bridge.print() } label: { Label("Print", systemImage: "printer") }.disabled(st.articleURL == nil).keyboardShortcut("p", modifiers: .command).help("Print or save as PDF")
                Button { if let u = st.articleURL { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.absoluteString, forType: .string) } } label: { Label("Copy Link", systemImage: "link") }.disabled(st.articleURL == nil)
            }
        }
        .searchFocusable($searchFocused)
        .onChange(of: model.pendingArticle?.path) { _, _ in consumePending() }
        .onAppear { consumePending() }
    }

    var bookList: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search all reference books", text: $st.query).textFieldStyle(.roundedBorder).focused($searchFocused).onSubmit { Task { await search() } }
                if st.searching { ProgressView().controlSize(.small) }
            }.padding(8)
            Divider()
            if !st.query.isEmpty && !st.hits.isEmpty {
                List(st.hits) { h in
                    Button { open(book: h.bookName, path: h.path, title: h.title) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.title).font(.headline)
                            Text(h.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            Meta([bookTitle(h.bookName)])
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            } else if !st.query.isEmpty && !st.searching {
                EmptyState(icon: "magnifyingglass", title: "No articles found", message: "Try different words, or press ⌘K to search manuals, pages and videos too.")
            } else if model.books.isEmpty && model.damagedBooks.isEmpty {
                EmptyState(icon: "books.vertical", title: "No reference books yet", message: "Encyclopaedias, medical references and manuals come from Library updates and work with no internet.", action: ("Check for Updates", { Task { await model.checkForUpdates(interactive: true) } }))
            } else {
                // Choosing a book in the list opens its main page; a citation selects the book programmatically and must keep its article.
                List(selection: Binding(get: { st.selectedBook }, set: { b in st.selectedBook = b; if let b { st.articleURL = model.kiwix.mainPageURL(bookName: b.name); st.articleTitle = b.displayTitle } })) {
                    if !model.damagedBooks.isEmpty {
                        Section {
                            ForEach(model.damagedBooks, id: \.file) { d in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(d.file).font(.headline)
                                        Text(d.reason).font(.callout).foregroundStyle(.secondary)
                                        Text("Your other books keep working. Download this one again or restore it from your backup.").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Updates") { Task { await model.checkForUpdates(interactive: true) } }.controlSize(.small)
                                }
                            }
                        } header: { Label("Damaged books (skipped)", systemImage: "exclamationmark.triangle") }
                    }
                    ForEach(BookRole.allCases, id: \.self) { role in
                        let books = model.books.filter { ($0.role ?? .encyclopaedic) == role }
                        if !books.isEmpty {
                            Section(role.title) {
                                ForEach(books) { b in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(b.displayTitle).font(.headline)
                                        if let d = b.description, !d.isEmpty { Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                                        HStack(spacing: 6) {
                                            Meta([b.articleCount.map { "\($0) articles" }, b.sizeBytes.map(ByteFormat.string)])
                                            if let f = b.freshnessLabel { Text(f).font(.caption).padding(.horizontal, 5).padding(.vertical, 1).background(b.isPreLLMSnapshot ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15), in: Capsule()).help(b.isPreLLMSnapshot ? "Content snapshot predates AI-generated text (Nov 2022)" : "Date of this book's content snapshot") }
                                            if let t = b.tier, t != .core { Text(t.title).font(.caption).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                                            if b.isExternal { ExternalTag() }
                                        }
                                    }.tag(b)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let check = model.updateCheck { CatalogueBadge(trust: check.trust, release: check.manifest.version) }
                HStack {
                    StatusDot(state: model.kiwixState); Text(model.kiwixState == .running ? "Books are served offline on this Mac" : model.kiwixState.label).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if case .failed = model.kiwixState { Button("Restart") { model.restartHelper(.kiwixServe) }.controlSize(.small) }
                    if case .crashed = model.kiwixState { Button("Restart") { model.restartHelper(.kiwixServe) }.controlSize(.small) }
                }
            }.padding(8)
        }
        .debouncedSearch(st.query) { Task { await search() } }
    }

    @ViewBuilder var reader: some View {
        VStack(spacing: 0) {
            if findVisible {
                HStack { TextField("Find in article", text: $st.findText).textFieldStyle(.roundedBorder).onSubmit { bridge.find(st.findText) }; Button("Find") { bridge.find(st.findText) }; Button { findVisible = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close find") }.padding(8)
                Divider()
            }
            if let url = st.articleURL, model.kiwixState == .running {
                WebView(url: url, mode: .localServer(base: model.kiwix.baseURL), onTitle: { st.articleTitle = $0 }, onNavigationState: { b, f in st.canGoBack = b; st.canGoForward = f; bridge.highlight(model.takePendingHighlight()) }, bridge: bridge, zoom: st.zoom)
            } else if model.kiwixState == .starting {
                VStack { ProgressView(); Text("Starting the reference library…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.rosettaMissing {
                EmptyState(icon: "exclamationmark.triangle", title: "Reference books need Rosetta 2", message: "macOS can only install Rosetta from the internet. Install it now so your books work in an outage.", action: ("Install Rosetta 2…", { model.installRosetta() }))
            } else {
                EmptyState(icon: "text.book.closed", title: st.articleURL == nil ? "Choose a book or search" : "Reference library not running", message: st.articleURL == nil ? "Articles open here and work with no internet. Click a source in Chat to jump straight to the cited article." : model.kiwixState.label)
            }
        }
    }

    func bookTitle(_ name: String) -> String { model.books.first { $0.name == name }?.displayTitle ?? name }
    func consumePending() { guard let p = model.pendingArticle else { return }; model.pendingArticle = nil; open(book: p.book, path: p.path, title: p.path) }
    func open(book: String, path: String, title: String) { st.articleURL = model.kiwix.articleURL(bookName: book, path: path); st.articleTitle = title; st.selectedBook = model.books.first { $0.name == book } }
    func search() async {
        let q = st.query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { st.hits = []; return }
        st.searching = true; defer { st.searching = false }
        do { st.hits = try await model.kiwix.search(q, books: nil, limit: 30) } catch { model.banner = error.userFacing }
    }
}
