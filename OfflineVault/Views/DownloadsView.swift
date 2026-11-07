import SwiftUI
import OfflineVaultCore

struct DownloadsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        Group {
            if downloads.items.isEmpty {
                EmptyState(icon: "arrow.down.circle", title: "Nothing downloading", message: "Library updates and chosen videos appear here with progress, pause, resume and retry. You can keep using the app while they run; you'll be notified when they finish.", action: ("Check for Library Updates", { Task { await model.checkForUpdates(interactive: true) } }))
            } else {
                List(downloads.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.isArtefact ? "shippingbox" : "play.rectangle").foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(item.title).lineLimit(1); Spacer(); Text(item.state.label).font(.caption).foregroundStyle(stateColor(item.state)) }
                            ProgressView(value: item.fraction).progressViewStyle(.linear).opacity(item.state == .completed ? 0.4 : 1)
                            HStack { Text("\(ByteFormat.string(item.bytesReceived)) of \(item.totalBytes > 0 ? ByteFormat.string(item.totalBytes) : "?")").monospacedDigit(); Spacer(); Text(item.statusText).lineLimit(1) }.font(.caption).foregroundStyle(.secondary)
                            if case .failed(let e) = item.state, let r = e.recovery { Text(r).font(.caption).foregroundStyle(.orange) }
                        }
                        controls(item)
                    }.padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationSubtitle(downloads.items.isEmpty ? "" : "\(downloads.activeCount) active · \(ByteFormat.string(downloads.totalQueuedBytes)) queued")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { downloads.pauseAll() } label: { Label("Pause All", systemImage: "pause") }.disabled(downloads.activeCount == 0)
                Button { downloads.resumeAll() } label: { Label("Resume All", systemImage: "play") }.disabled(!downloads.items.contains { $0.state == .paused })
                Button { downloads.clearCompleted() } label: { Label("Clear Finished", systemImage: "checkmark.circle") }.disabled(!downloads.items.contains { $0.state == .completed })
                Button { Task { await model.checkForUpdates(interactive: true) } } label: { Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath") }.disabled(model.isCheckingUpdates)
            }
        }
    }

    @ViewBuilder func controls(_ item: DownloadItem) -> some View {
        HStack(spacing: 6) {
            switch item.state {
            case .running, .queued: Button { downloads.pause(item.id) } label: { Image(systemName: "pause.fill") }.help("Pause").accessibilityLabel("Pause")
            case .paused: Button { downloads.resume(item.id) } label: { Image(systemName: "play.fill") }.help("Resume").accessibilityLabel("Resume")
            case .failed: Button { downloads.retry(item.id) } label: { Image(systemName: "arrow.clockwise") }.help("Retry").accessibilityLabel("Retry")
            case .completed: EmptyView()
            }
            Button { downloads.remove(item.id) } label: { Image(systemName: "xmark") }.help(item.state == .completed ? "Clear" : "Cancel (partial data is kept for resuming)").accessibilityLabel(item.state == .completed ? "Clear" : "Cancel")
        }.buttonStyle(.borderless)
    }
    func stateColor(_ s: DownloadItem.State) -> Color { switch s { case .completed: return .green; case .failed: return .orange; case .paused: return .secondary; default: return .primary } }
}
