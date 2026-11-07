import SwiftUI
import OfflineVaultCore

/// Notice banner (queued in AppModel, newest on top).
struct ErrorBanner: View {
    let error: UserFacingError
    var action: (title: String, run: () -> Void)? = nil
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(.headline)
                Text(error.message).font(.callout)
                if let r = error.recovery { Text(r).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            if let a = action { Button(a.title, action: a.run).controlSize(.small) }
            Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss notice")
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            if let a = action { Button(a.title, action: a.run).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Status indicator with an accessible label and a shape change for failure (not colour alone).
struct StatusDot: View {
    let state: ManagedProcess.State
    var body: some View {
        Group {
            switch state {
            case .running: Circle().fill(.green)
            case .starting: Circle().fill(.yellow)
            case .stopped: Circle().fill(.gray)
            case .crashed, .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.system(size: 9))
            }
        }
        .frame(width: 8, height: 8).help(state.label).accessibilityLabel(state.label)
    }
}

/// Loads an image from disk off the main thread.
struct FileImage: View {
    let url: URL?
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .clipped()
        .task(id: url) {
            guard let url else { image = nil; return }
            let img = await Task.detached { NSImage(contentsOf: url) }.value
            image = img
        }
    }
}

/// The one list/detail layout every content screen uses, so widths and dividers match.
struct ListDetail<List: View, Detail: View>: View {
    @ViewBuilder let list: () -> List
    @ViewBuilder let detail: () -> Detail
    var body: some View {
        HSplitView {
            list().frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
            detail().frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Metadata line style readable on non-Retina displays.
struct Meta: View {
    let parts: [String]
    init(_ parts: [String?]) { self.parts = parts.compactMap { $0 }.filter { !$0.isEmpty } }
    var body: some View { Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
}

extension View {
    func searchFocusable(_ focus: FocusState<Bool>.Binding) -> some View {
        self.onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in focus.wrappedValue = true }
    }
    /// Debounced live search: fires `action` 250 ms after the user stops typing.
    func debouncedSearch(_ text: String, perform action: @escaping () -> Void) -> some View {
        self.task(id: text) { try? await Task.sleep(nanoseconds: 250_000_000); if !Task.isCancelled { action() } }
    }
}

enum Panels {
    @MainActor static func chooseFolder(prompt: String, message: String? = nil, start: URL? = nil) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.allowsMultipleSelection = false
        p.prompt = prompt; p.directoryURL = start
        p.message = message ?? "Choose a folder."
        return p.runModal() == .OK ? p.url : nil
    }
    @MainActor static func chooseFiles(types: [String], prompt: String, multiple: Bool = false, message: String? = nil) -> [URL] {
        let p = NSOpenPanel()
        p.canChooseDirectories = false; p.canChooseFiles = true; p.allowsMultipleSelection = multiple
        p.allowedContentTypes = types.compactMap { .init(filenameExtension: $0) }
        p.prompt = prompt; if let m = message { p.message = m }
        return p.runModal() == .OK ? p.urls : []
    }
    @MainActor static func chooseFile(types: [String], prompt: String) -> URL? { chooseFiles(types: types, prompt: prompt).first }

    /// Standard destructive confirmation; returns true when the user confirms.
    @MainActor static func confirm(_ title: String, message: String, button: String = "Delete") -> Bool {
        let a = NSAlert(); a.messageText = title; a.informativeText = message; a.alertStyle = .warning
        a.addButton(withTitle: button); a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        return a.runModal() == .alertFirstButtonReturn
    }
}

/// Keyboard shortcuts sheet (Help › Keyboard Shortcuts).
struct ShortcutsSheet: View {
    @Environment(\.dismiss) var dismiss
    let rows: [(String, String)] = [("⌘K", "Search everything"), ("⌘F", "Find in the current screen"), ("⌘N", "New conversation"), ("⌘↩ / ↩", "Send message (Shift-↩ for a new line)"), ("⌘.", "Stop generating"), ("⌘1–⌘7", "Chat, Scenarios, Reference, Documents, Maps, Videos, Saved Pages"), ("⌘8 / ⌘9 / ⌘0", "Downloads, Readiness, Settings"), ("⇧⌘U", "Check for library updates"), ("⇧⌘R", "Run the offline drill"), ("⌘O / ⇧⌘I", "Import files / a folder"), ("Space", "Quick Look a document or video"), ("⌘P", "Print the current article, page or document")]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard shortcuts").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) { ForEach(rows, id: \.0) { r in GridRow { Text(r.0).font(.body.monospaced()).foregroundStyle(.secondary); Text(r.1) } } }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 520)
    }
}
