import SwiftUI
import AVKit
import OfflineVaultCore

struct VideosView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { VideosBody(st: model.videosScreen) }
}

struct VideosBody: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadManager
    @ObservedObject var st: VideosScreen
    @State private var videos: [Video] = []
    @State private var sources: [VideoSource] = []
    @FocusState private var searchFocused: Bool

    var completedCount: Int { downloads.items.filter { $0.state == .completed }.count }

    var body: some View {
        ListDetail { list } detail: { detail }
        .navigationTitle(st.selected?.title ?? "Videos")
        .navigationSubtitle("\(videos.count) downloaded")
        .searchable(text: $st.query, placement: .toolbar, prompt: "Search titles and what was said")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Source", selection: $st.sourceFilter) { Text("All sources").tag(Int64?.none); ForEach(sources) { s in Text(s.displayTitle).tag(Int64?.some(s.id)) } }
                Button { model.section = .sources } label: { Label("Add Videos", systemImage: "plus") }.help("Add a channel or playlist and choose videos to download")
            }
        }
        .task { reload() }
        .onReceive(model.$libraryGeneration) { _ in reload() }
        .onChange(of: completedCount) { _, _ in reload() }
        .debouncedSearch(st.query) { reload() }
        .onChange(of: st.sourceFilter) { _, _ in reload() }
        .onChange(of: model.pendingVideo?.id) { _, _ in consumePending() }
        .onChange(of: model.pendingVideo?.seconds) { _, _ in consumePending() }
        .onAppear { consumePending() }
    }

    var list: some View {
        Group {
            if videos.isEmpty {
                EmptyState(icon: "play.rectangle.on.rectangle", title: st.query.isEmpty ? "No videos yet" : "No matches", message: st.query.isEmpty ? "Add a YouTube channel or playlist, pick the videos worth keeping, and they download for offline viewing with searchable subtitles." : "Transcripts are searched too — try other words.", action: st.query.isEmpty ? ("Add Videos…", { model.section = .sources }) : nil)
            } else {
                List(videos, selection: $st.selected) { v in
                    HStack(spacing: 10) {
                        FileImage(url: model.videoLibrary?.thumbnailURL(for: v)).frame(width: 104, height: 58).clipShape(RoundedRectangle(cornerRadius: 5)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(v.title).font(.headline).lineLimit(2)
                            Meta([v.channel, DurationFormat.string(v.durationSeconds), ByteFormat.string(v.fileSize ?? 0)])
                        }
                    }.tag(v)
                    .contextMenu {
                        Button("Quick Look") { if let u = model.videoLibrary?.fileURL(for: v) { QuickLook.show([u]) } }
                        Button("Show in Finder") { if let u = model.videoLibrary?.fileURL(for: v) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                        if let w = v.webpageURL { Button("Copy Original Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(w, forType: .string) } }
                        Divider()
                        Button("Delete Downloaded File…", role: .destructive) { delete(v) }
                    }
                }
                .onDeleteCommand { if let v = st.selected { delete(v) } }
                .onChange(of: st.selected) { _, v in if let v, st.player.videoId != v.id { st.startAt = nil } }
            }
        }
    }

    @ViewBuilder var detail: some View {
        if let v = st.selected {
            VideoPlayerPane(video: v, startAt: st.startAt, controller: st.player)
        } else {
            EmptyState(icon: "play.rectangle", title: "Choose a video", message: "Plays here with resume memory, speed control, subtitles and a clickable transcript. Switching sections pauses it; come back and continue.")
        }
    }

    func delete(_ v: Video) {
        guard Panels.confirm("Delete the downloaded file for “\(v.title)”?", message: "\(ByteFormat.string(v.fileSize ?? 0)) is freed. The video stays listed under its source so you can download it again.") else { return }
        if st.player.videoId == v.id { st.player.unload() }
        do { try model.videoLibrary?.deleteDownloadedFiles(v, keepCatalogueEntry: true); if st.selected?.id == v.id { st.selected = nil }; reload() } catch { model.banner = error.userFacing }
    }
    func consumePending() {
        guard let p = model.pendingVideo, let lib = model.videoLibrary, let v = try? lib.video(id: p.id) else { return }
        model.pendingVideo = nil; st.startAt = p.seconds; st.selected = v
    }
    func reload() {
        guard let lib = model.videoLibrary else { return }
        sources = (try? lib.sources()) ?? []
        var list = st.query.trimmingCharacters(in: .whitespaces).isEmpty ? ((try? lib.videos(status: .downloaded)) ?? []) : ((try? lib.search(st.query)) ?? [])
        if let s = st.sourceFilter { list = list.filter { $0.sourceId == s } }
        if list != videos { videos = list }
    }
}

/// Native AVKit player; the controller lives in the screen state so playback survives navigation (paused).
struct VideoPlayerPane: View {
    @EnvironmentObject var model: AppModel
    let video: Video
    let startAt: Double?
    @ObservedObject var controller: PlayerController
    @State private var showSubtitles = true
    @State private var speed: Double = AppSettings.shared.playbackSpeed

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) { Text(video.title).font(.headline).lineLimit(1); Meta([video.channel, video.formattedUploadDate, DurationFormat.string(video.durationSeconds)]) }
                Spacer()
                Picker("Speed", selection: $speed) { ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) } }.frame(width: 110).onChange(of: speed) { _, s in controller.setRate(Float(s)); AppSettings.shared.playbackSpeed = s }
                if !controller.cues.isEmpty { Toggle("Subtitles", isOn: $showSubtitles).toggleStyle(.switch).controlSize(.small) }
            }.padding(10)
            Divider()
            HSplitView {
                ZStack(alignment: .bottom) {
                    AVPlayerViewRepresentable(player: controller.player)
                    if showSubtitles, !controller.currentCue.isEmpty {
                        Text(controller.currentCue).font(.title3).padding(8).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.white).padding(.bottom, 64).multilineTextAlignment(.center).allowsHitTesting(false)
                    }
                }.frame(minWidth: 360, minHeight: 240)
                if !controller.transcript.isEmpty {
                    List(controller.transcript, id: \.start) { c in
                        Button { controller.seek(c.start) } label: {
                            HStack(alignment: .top) {
                                Text(DurationFormat.string(c.start)).monospacedDigit().foregroundStyle(c.start <= controller.currentTime && controller.currentTime < c.end ? Color.accentColor : .secondary).frame(width: 50, alignment: .leading)
                                Text(c.text).font(.callout)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }.frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                }
            }
        }
        .onAppear { controller.load(video: video, library: model.videoLibrary, startAt: startAt, rate: Float(speed)) }
        .onChange(of: video.id) { _, _ in controller.load(video: video, library: model.videoLibrary, startAt: startAt, rate: Float(speed)) }
        .onChange(of: startAt) { _, s in if let s { controller.seek(s) } }
    }
}

struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView(); v.player = player; v.controlsStyle = .floating; v.showsFullScreenToggleButton = true; v.allowsPictureInPicturePlayback = true; v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}
