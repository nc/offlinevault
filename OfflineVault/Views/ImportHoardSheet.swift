import SwiftUI
import OfflineVaultCore

/// "Import my hoard": point at a folder of PDFs/EPUBs/videos/pages, watch it get indexed, tagged and de-duplicated.
struct ImportHoardSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var folder: URL?
    @State private var copyVideos = true
    @State private var progress = LibraryImporter.Progress()
    @State private var running = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import a folder of files").font(.title2.bold())
            Text("Every PDF, EPUB, text file, video (with .vtt/.srt subtitles alongside) and saved HTML page under the folder is copied into the library, indexed for search and the assistant, tagged by subject, and de-duplicated by content. Nothing is modified in the source folder.").foregroundStyle(.secondary)
            HStack {
                Text(folder?.path ?? "No folder chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(folder == nil ? .secondary : .primary)
                Spacer()
                Button("Choose folder…") { if let u = Panels.chooseFolder(prompt: "Import") { folder = u } }.disabled(running)
            }
            Toggle("Copy videos into the library (off = link to the originals; the drive must stay connected)", isOn: $copyVideos).disabled(running)
            if progress.total > 0 || running {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.scanned), total: Double(max(progress.total, 1)))
                    Text("\(progress.scanned) / \(progress.total) · \(progress.imported) imported · \(progress.duplicates) duplicates · \(progress.failed) failed").font(.caption).monospacedDigit()
                    if !progress.current.isEmpty { Text(progress.current).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    if !progress.bySubject.isEmpty {
                        FlowLayoutSimple(items: progress.bySubject.sorted { $0.value > $1.value }.map { "\($0.key.title): \($0.value)" })
                    }
                    if !progress.errors.isEmpty {
                        DisclosureGroup("Problems (\(progress.errors.count))") { ForEach(progress.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) } }.font(.caption)
                    }
                }
            }
            HStack {
                Button(running ? "Stop" : "Close") { if running { task?.cancel() } else { dismiss() } }
                Spacer()
                Button("Import") { start() }.buttonStyle(.borderedProminent).disabled(folder == nil || running)
            }
        }
        .padding(20).frame(width: 560)
        .onReceive(NotificationCenter.default.publisher(for: .importFolderChosen)) { n in if let u = n.object as? URL { folder = u } }
    }

    func start() {
        guard let folder, let importer = model.importer else { return }
        running = true; progress = LibraryImporter.Progress()
        task = Task.detached(priority: .userInitiated) {
            let report = await importer.importFolder(folder, copyVideos: copyVideos) { p in Task { @MainActor in progress = p } }
            await MainActor.run { progress = report; running = false; model.refreshLibraryState(); model.objectWillChange.send() }
        }
    }
}

struct FlowLayoutSimple: View {
    let items: [String]
    var body: some View {
        FlowLayout(spacing: 6) { ForEach(items, id: \.self) { Text($0).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary, in: Capsule()) } }
    }
}

/// Simple wrapping layout for chips (shared).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews { let sz = s.sizeThatFits(.unspecified); if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }; x += sz.width + spacing; rowH = max(rowH, sz.height) }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews { let sz = s.sizeThatFits(.unspecified); if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }; s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz)); x += sz.width + spacing; rowH = max(rowH, sz.height) }
    }
}
