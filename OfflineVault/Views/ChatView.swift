import SwiftUI
import OfflineVaultCore

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var chat: ChatController
    @FocusState private var inputFocused: Bool
    @State private var conversationQuery = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""

    var body: some View {
        ListDetail {
            conversationList
        } detail: {
            VStack(spacing: 0) {
                messages
                Divider()
                composer
            }
        }
        .navigationTitle("Chat")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $chat.searchLibrary) { Label("Answer from library", systemImage: "books.vertical") }
                    .toggleStyle(.button).help(chat.searchLibrary ? "On: answers are grounded in your library and cited. Click to answer from the model alone." : "Off: the model answers from its own knowledge, unverified. Click to ground answers in your library.")
                Button { chat.newConversation(); inputFocused = true } label: { Label("New Conversation", systemImage: "square.and.pencil") }.help("New conversation (⌘N)")
            }
        }
        .onAppear { model.ensureLLMLoaded(); inputFocused = true }
        .alert("Rename conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") { if let c = renaming { chat.rename(c, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    var subtitle: String {
        if let m = chat.modelName { return ModelNames.friendly(m) + (chat.searchLibrary ? " · grounded in your library" : " · model only, unverified") }
        if model.llamaState == .starting { return "Loading the AI model…" }
        return "No model loaded"
    }

    var conversationList: some View {
        VStack(spacing: 0) {
            let filtered = conversationQuery.isEmpty ? chat.conversations : chat.conversations.filter { $0.title.localizedCaseInsensitiveContains(conversationQuery) }
            List(selection: Binding(get: { chat.current?.id }, set: { id in if let c = chat.conversations.first(where: { $0.id == id }) { chat.select(c) } })) {
                ForEach(filtered) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).lineLimit(1)
                        Text(c.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }.tag(c.id)
                    .contextMenu {
                        Button("Rename…") { renaming = c; renameText = c.title }
                        Button("Delete…", role: .destructive) { if Panels.confirm("Delete “\(c.title)”?", message: "The conversation and its cited sources are removed. This cannot be undone.") { chat.delete(c) } }
                    }
                }
            }
            .searchable(text: $conversationQuery, placement: .sidebar, prompt: "Filter conversations")
            .overlay { if chat.conversations.isEmpty { Text("No conversations yet").foregroundStyle(.secondary) } }
        }
    }

    var messages: some View {
        VStack(spacing: 0) {
            if chat.messages.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 40)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Ask your library").font(.title3.weight(.semibold))
                    Text("Questions are answered from the reference books, manuals, saved pages and video transcripts on this Mac. Every factual claim is cited; click a source to open the page.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
                    if model.llamaState == .starting { HStack { ProgressView().controlSize(.small); Text("Loading the AI model — about a minute the first time.").font(.callout).foregroundStyle(.secondary) } }
                    else if chat.modelName == nil { Button("Load the AI model") { model.ensureLLMLoaded() } }
                    HStack(spacing: 8) {
                        ForEach(["How much water should I store per person?", "How do I treat hypothermia?", "What goes in a 72-hour kit?"], id: \.self) { q in
                            Button(q) { chat.input = q; chat.send() }.buttonStyle(.bordered).controlSize(.small).disabled(!chat.canSendAnything)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptView(messages: chat.messages) { model.open($0, highlight: $1) }
                    .contextMenu {
                        Button("Copy Conversation") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(chat.messages.map { ($0.role == .user ? "You: " : "OfflineVault: ") + $0.content }.joined(separator: "\n\n"), forType: .string)
                        }
                        Button("Print / Save as PDF…") { PDFExport.printText(chat.messages.map { ($0.role == .user ? "You: " : "OfflineVault: ") + $0.content }.joined(separator: "\n\n"), title: chat.current?.title ?? "Conversation") }
                    }
            }
            if let s = chat.statusLine { HStack { ProgressView().controlSize(.small); Text(s).font(.caption).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 14).padding(.vertical, 6) }
        }
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                ComposerTextView(text: $chat.input, placeholder: chat.searchLibrary ? "Ask your library… (Return to send, Shift-Return for a new line)" : "Ask the model… answers are not checked against your library", onSend: { if chat.canSend { chat.send() } })
                    .frame(minHeight: 36, maxHeight: 140)
                if chat.isGenerating {
                    Button { chat.stop() } label: { Label("Stop", systemImage: "stop.fill") }.keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { chat.send() } label: { Label("Send", systemImage: "paperplane.fill") }.keyboardShortcut(.return, modifiers: .command).disabled(!chat.canSend).buttonStyle(.borderedProminent)
                    Button { chat.regenerate() } label: { Image(systemName: "arrow.clockwise") }.help("Regenerate the last answer").accessibilityLabel("Regenerate").disabled(chat.messages.last?.role != .assistant)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: chat.searchLibrary ? "checkmark.shield" : "exclamationmark.shield").foregroundStyle(chat.searchLibrary ? Color.secondary : .orange).accessibilityHidden(true)
                Text(chat.searchLibrary ? "For medical, electrical and structural topics read the cited source itself, not just the summary." : "Library search is off: answers are the model's general knowledge and unverified. Turn it on for safety-critical questions.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.memoryLevel != .normal { Label("Memory \(model.memoryLevel.rawValue)", systemImage: "memorychip").font(.caption).foregroundStyle(.orange) }
            }
        }.padding(12)
    }
}

/// NSTextView-backed composer: Return sends, Shift-Return inserts a newline, grows up to a few lines.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSend: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        init(_ p: ComposerTextView) { parent = p }
        func textDidChange(_ n: Notification) { if let tv = n.object as? NSTextView { parent.text = tv.string; (tv.superview?.superview as? PlaceholderScrollView)?.updatePlaceholder() } }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) { textView.insertNewlineIgnoringFieldEditor(nil); return true }
                parent.onSend(); return true
            }
            return false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> PlaceholderScrollView {
        let scroll = PlaceholderScrollView()
        let tv = NSTextView()
        tv.delegate = context.coordinator; tv.isRichText = false; tv.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        tv.textContainerInset = NSSize(width: 6, height: 8); tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.allowsUndo = true; tv.isVerticallyResizable = true; tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.setAccessibilityLabel("Message")
        scroll.documentView = tv; scroll.hasVerticalScroller = false; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 8; scroll.layer?.borderWidth = 1; scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.placeholder.stringValue = placeholder
        scroll.updatePlaceholder()
        return scroll
    }
    func updateNSView(_ scroll: PlaceholderScrollView, context: Context) {
        context.coordinator.parent = self
        if let tv = scroll.documentView as? NSTextView, tv.string != text { tv.string = text }
        scroll.placeholder.stringValue = placeholder
        scroll.updatePlaceholder()
    }
}

final class PlaceholderScrollView: NSScrollView {
    let placeholder: NSTextField = { let t = NSTextField(labelWithString: ""); t.textColor = .placeholderTextColor; t.font = .systemFont(ofSize: NSFont.systemFontSize + 1); t.lineBreakMode = .byTruncatingTail; return t }()
    override init(frame: NSRect) { super.init(frame: frame); addSubview(placeholder); placeholder.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11), placeholder.topAnchor.constraint(equalTo: topAnchor, constant: 8), placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)]) }
    required init?(coder: NSCoder) { fatalError() }
    func updatePlaceholder() { placeholder.isHidden = !((documentView as? NSTextView)?.string.isEmpty ?? true) }
}
