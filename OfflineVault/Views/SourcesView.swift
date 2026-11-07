import SwiftUI
import OfflineVaultCore

/// Add YouTube channels/playlists, index them (titles only), pick videos to download.
struct SourcesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { SourcesBody(st: model.sourcesScreen) }
}

struct SourcesBody: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadManager
    @ObservedObject var st: SourcesScreen
    @State private var sources: [VideoSource] = []
    @State private var videos: [Video] = []
    @State private var newURL = ""
    @State private var showAdd = false
    @State private var quality: VideoQuality = AppSettings.shared.defaultQuality
    @State private var confirmBatch = false

    var subtitle: String { st.selected != nil ? "\(videos.count) videos indexed" : "\(sources.count) sources" }
    var finishedCount: Int { downloads.items.filter { if case .completed = $0.state { return true }; if case .failed = $0.state { return true }; return false }.count }
    var reindexDisabled: Bool { guard let s = st.selected else { return true }; return st.indexing.contains(s.id) }

    var body: some View {
        content
            .navigationTitle("Video Sources")
            .navigationSubtitle(subtitle)
            .searchable(text: $st.query, placement: .toolbar, prompt: "Filter videos")
            .toolbar { toolbarContent }
            .popover(isPresented: $showAdd) { addPopover }
            .task { reloadSources() }
            .onChange(of: st.selected?.id) { _, _ in reloadVideos(); st.checked.removeAll() }
            .onChange(of: finishedCount) { _, _ in reloadVideos() }
            .confirmationDialog("Download \(st.checked.count) videos (about \(ByteFormat.string(selectedBytes)))?", isPresented: $confirmBatch, titleVisibility: .visible) { Button("Download") { enqueue() } } message: { Text(batchMessage) }
    }

    var content: some View { ListDetail { list } detail: { detail } }
    var batchMessage: String { "Larger than your confirmation threshold (\(ByteFormat.string(AppSettings.shared.batchConfirmBytes)), set in Settings). \(ByteFormat.string(model.storage?.volumeFreeBytes ?? 0)) free." }

    @ToolbarContentBuilder var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Quality", selection: $quality) { ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) } }.help("Download quality")
            Button { showAdd = true } label: { Label("Add Source", systemImage: "plus") }.help("Add a channel, playlist or video link")
            Button { if let s = st.selected { index(s) } } label: { Label("Re-index", systemImage: "arrow.clockwise") }.disabled(reindexDisabled).help("Check the source for new videos")
        }
    }

    var addPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a video source").font(.headline)
            TextField("Channel, playlist or video link", text: $newURL).textFieldStyle(.roundedBorder).frame(width: 380).onSubmit { addSource() }
            Text("OfflineVault lists what the source contains first — nothing is downloaded until you choose. Your Mac fetches the videos you pick, for your own offline use.").font(.caption).foregroundStyle(.secondary).frame(width: 380)
            HStack { Spacer(); Button("Cancel") { showAdd = false }; Button("Add") { addSource() }.buttonStyle(.borderedProminent).disabled(newURL.isEmpty) }
        }.padding(16)
    }

    var list: some View {
        Group {
            if sources.isEmpty {
                EmptyState(icon: "antenna.radiowaves.left.and.right", title: "No sources yet", message: "Add a YouTube channel, playlist or video. You pick what to download; subtitles are indexed so you can search what was said.", action: ("Add Source…", { showAdd = true }))
            } else {
                List(sources, selection: $st.selected) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(s.displayTitle).font(.headline).lineLimit(1); Spacer(); if st.indexing.contains(s.id) { ProgressView().controlSize(.mini) } }
                        Meta([s.kind.rawValue.capitalized, "\(s.itemCount) videos", s.lastIndexedAt.map { "checked \($0.formatted(.relative(presentation: .named)))" }])
                        if let e = s.lastError { Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(2) }
                    }.tag(s)
                    .contextMenu {
                        Button("Re-index") { index(s) }
                        Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.url, forType: .string) }
                        Divider()
                        Button("Remove Source…", role: .destructive) { if Panels.confirm("Remove “\(s.displayTitle)”?", message: "Downloaded videos are kept; the list of not-yet-downloaded videos from this source is removed.", button: "Remove") { try? model.videoLibrary?.removeSource(s.id, deleteIndexedEntries: true); if st.selected?.id == s.id { st.selected = nil }; reloadSources() } }
                    }
                }
            }
        }
    }

    @ViewBuilder var detail: some View {
        if let s = st.selected {
            VStack(spacing: 0) {
                if videos.isEmpty {
                    EmptyState(icon: "list.bullet.rectangle", title: st.indexing.contains(s.id) ? "Checking the source…" : "Nothing listed yet", message: s.lastError ?? "Index this source to list its videos.", action: st.indexing.contains(s.id) ? nil : ("Index Now", { index(s) }))
                } else {
                    Table(filtered) {
                        TableColumn("") { v in
                            if v.status == .downloaded { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Downloaded").accessibilityLabel("Downloaded") }
                            else if v.status == .queued || v.status == .downloading { ProgressView().controlSize(.mini) }
                            else { Toggle("", isOn: Binding(get: { st.checked.contains(v.id) }, set: { on in if on { st.checked.insert(v.id) } else { st.checked.remove(v.id) } })).labelsHidden().accessibilityLabel("Select \(v.title)") }
                        }.width(28)
                        TableColumn("Title") { v in VStack(alignment: .leading) { Text(v.title).lineLimit(1); Text(v.channel ?? "").font(.caption).foregroundStyle(.secondary) } }
                        TableColumn("Length") { v in Text(DurationFormat.string(v.durationSeconds)).monospacedDigit() }.width(70)
                        TableColumn("Uploaded") { v in Text(v.formattedUploadDate ?? "–").font(.caption) }.width(90)
                        TableColumn("Size at \(quality.rawValue)") { v in Text(SizeEstimator.estimate(duration: v.durationSeconds, quality: quality).map(ByteFormat.string) ?? "–").monospacedDigit() }.width(110)
                        TableColumn("Status") { v in Text(v.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) }.width(90)
                    }
                }
                Divider()
                HStack {
                    Button("Select All New") { st.checked = Set(filtered.filter { $0.status == .indexed || $0.status == .failed }.map(\.id)) }
                    Button("Clear") { st.checked.removeAll() }.disabled(st.checked.isEmpty)
                    Spacer()
                    Text("\(st.checked.count) selected · about \(ByteFormat.string(selectedBytes))").font(.callout).monospacedDigit()
                    Button("Download Selected") { startBatch() }.buttonStyle(.borderedProminent).disabled(st.checked.isEmpty)
                }.padding(10)
            }
        } else {
            EmptyState(icon: "square.and.arrow.down.on.square", title: "Choose a source", message: "Pick a source on the left to see its videos and choose what to download.")
        }
    }

    var filtered: [Video] { let q = st.query.trimmingCharacters(in: .whitespaces).lowercased(); return q.isEmpty ? videos : videos.filter { $0.title.lowercased().contains(q) || ($0.channel ?? "").lowercased().contains(q) } }
    var selectedBytes: Int64 { videos.filter { st.checked.contains($0.id) }.reduce(0) { $0 + (SizeEstimator.estimate(duration: $1.durationSeconds, quality: quality) ?? 0) } }
    func reloadSources() { sources = (try? model.videoLibrary?.sources()) ?? []; if let s = st.selected { st.selected = sources.first { $0.id == s.id } } }
    func reloadVideos() { guard let s = st.selected else { videos = []; return }; videos = (try? model.videoLibrary?.videos(sourceId: s.id)) ?? [] }
    func addSource() {
        guard let lib = model.videoLibrary else { return }
        do { let s = try lib.addSource(url: newURL); newURL = ""; showAdd = false; reloadSources(); st.selected = s; index(s) } catch { model.banner = error.userFacing }
    }
    func index(_ s: VideoSource) {
        guard let yt = model.youtube else { return }
        st.indexing.insert(s.id)
        Task { defer { st.indexing.remove(s.id); reloadSources(); reloadVideos() }; do { _ = try await yt.indexSource(s) } catch { model.banner = error.userFacing } }
    }
    func startBatch() {
        guard let layout = model.layout else { return }
        if !layout.hasSpace(forAdditionalBytes: selectedBytes) { model.banner = UserFacingError("Not enough space", message: "The selected videos need about \(ByteFormat.string(selectedBytes)) and the library drive is nearly full.", recovery: "Pick fewer videos, choose a lower quality, or free up space."); return }
        if selectedBytes > AppSettings.shared.batchConfirmBytes { confirmBatch = true } else { enqueue() }
    }
    func enqueue() {
        let chosen = videos.filter { st.checked.contains($0.id) }
        downloads.enqueue(videos: chosen, quality: quality) { SizeEstimator.estimate(duration: $0.durationSeconds, quality: quality) }
        st.checked.removeAll(); reloadVideos(); model.section = .downloads
    }
}
