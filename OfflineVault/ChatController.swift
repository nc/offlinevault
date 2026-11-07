import SwiftUI
import OfflineVaultCore

/// Drives the chat screen: retrieval → prompt → streaming answer → persistence.
@MainActor
final class ChatController: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var current: Conversation?
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isGenerating = false
    @Published var modelName: String?
    @Published var statusLine: String?
    @Published var retrieverSummary = ""
    /// Mirrors AppSettings.chatSearchesLibrary (on by default).
    @Published var searchLibrary: Bool = AppSettings.shared.chatSearchesLibrary { didSet { AppSettings.shared.chatSearchesLibrary = searchLibrary } }

    private var store: ChatStore?
    private(set) var coordinator: RetrievalCoordinator?
    var retrievers: [Retriever] { coordinator?.retrievers ?? [] }
    private var client: LLMClient?
    private var task: Task<Void, Never>?

    func configure(store: ChatStore, coordinator: RetrievalCoordinator) {
        self.store = store
        self.coordinator = coordinator
        conversations = (try? store.conversations()) ?? []
        if current == nil, let first = conversations.first { select(first) }
        refreshRetrieverAvailability()
    }

    private var profile: ModelProfile = .qwen3
    func setClient(_ c: LLMClient?, modelName: String?, profile: ModelProfile = .qwen3) { client = c; self.modelName = modelName; self.profile = profile }

    func modelUnavailable(_ reason: String) { statusLine = reason }

    func refreshRetrieverAvailability() {
        retrieverSummary = "Answers are grounded in your library: reference articles, saved pages and video transcripts."
    }

    var canSend: Bool { !input.trimmingCharacters(in: .whitespaces).isEmpty && !isGenerating && client != nil }
    var canSendAnything: Bool { !isGenerating && client != nil }

    func rename(_ c: Conversation, to title: String) {
        let t = title.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        try? store?.rename(c.id, title: t)
        if let i = conversations.firstIndex(where: { $0.id == c.id }) { conversations[i].title = t }
        if current?.id == c.id { current?.title = t }
    }

    // MARK: Conversations

    func newConversation() {
        guard let store else { return }
        if let c = try? store.create(title: "New conversation", model: modelName) {
            conversations.insert(c, at: 0); select(c)
        }
    }

    func select(_ c: Conversation) {
        current = c
        messages = (try? store?.messages(in: c.id)) ?? []
    }

    func delete(_ c: Conversation) {
        try? store?.delete(c.id)
        conversations.removeAll { $0.id == c.id }
        if current?.id == c.id { current = nil; messages = []; if let f = conversations.first { select(f) } }
    }

    // MARK: Sending

    func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isGenerating else { return }
        input = ""
        if current == nil { newConversation() }
        guard let conv = current, let store else { return }
        let userMsg = ChatMessage(role: .user, content: question)
        messages.append(userMsg)
        try? store.save(userMsg, in: conv.id)
        if messages.filter({ $0.role == .user }).count == 1 {
            let title = question.count > 60 ? String(question.prefix(57)).trimmingCharacters(in: .whitespaces) + "…" : question
            try? store.rename(conv.id, title: title)
            if let i = conversations.firstIndex(where: { $0.id == conv.id }) { conversations[i].title = title; current?.title = title }
        }
        generate(for: question, in: conv)
    }

    func regenerate() {
        guard !isGenerating, let conv = current, let lastAssistant = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        guard let question = messages[..<lastAssistant].last(where: { $0.role == .user })?.content else { return }
        let removed = messages.remove(at: lastAssistant)
        try? store?.deleteMessage(removed.id)
        generate(for: question, in: conv)
    }

    func stop() { task?.cancel() }

    /// Retrieval only (used by scenario cards).
    func retrieve(_ query: String) async -> [RetrievedPassage] { await coordinator?.retrieve(query) ?? [] }

    private func generate(for question: String, in conv: Conversation) {
        // High-stakes questions (plant/mushroom ID, dosing, chemical mixing) are never answered from the model's memory.
        if let category = Prompting.highStakes(question), !searchLibrary {
            var m = ChatMessage(role: .assistant, content: Prompting.refusal(for: category, libraryOn: false), usedLibrary: true) // refusal: no "unverified" footer
            messages.append(m); try? store?.save(m, in: conv.id)
            return
        }
        guard let client else {
            var m = ChatMessage(role: .assistant, content: ""); m.error = "No AI model is loaded. Download a model from Settings › Models, then try again."
            messages.append(m); return
        }
        isGenerating = true
        let useLibrary = searchLibrary
        statusLine = useLibrary ? "Searching your library…" : "Generating (library search off)…"
        let history = Array(messages.dropLast()) // without the question just added
        task = Task { [weak self] in
            guard let self else { return }
            let passages = useLibrary ? (await self.coordinator?.retrieve(question) ?? []) : []
            if Task.isCancelled { self.finish(); return }
            if let category = Prompting.highStakes(question) {
                // Never let the model compute a dose, a mix ratio or an identification: refuse without sources, quote with them.
                let content = passages.isEmpty ? Prompting.refusal(for: category, libraryOn: true) : Prompting.sourcesOnlyAnswer(for: category, passages: passages)
                var m = ChatMessage(role: .assistant, content: content, sources: passages, usedLibrary: true)
                m.isStreaming = false
                self.messages.append(m); try? self.store?.save(m, in: conv.id)
                self.finish(); return
            }
            var answer = ChatMessage(role: .assistant, content: "", sources: passages, usedLibrary: useLibrary)
            answer.leadingPassageLabel = RetrievalCoordinator.fieldGuideLead(for: question, in: passages)?.label
            if answer.leadingPassageLabel != nil, Prompting.isSafetyCritical(question) {
                // A human-checked procedure answers a safety-critical question on its own; no model commentary beneath it.
                answer.content = Prompting.fieldGuideOnlyNote
                self.messages.append(answer); try? self.store?.save(answer, in: conv.id)
                self.finish(); return
            }
            answer.isStreaming = true
            self.messages.append(answer)
            let idx = self.messages.count - 1
            if useLibrary {
                self.statusLine = passages.isEmpty ? (RetrievalCoordinator.shouldRetrieve(question) ? "No matching sources found — the model will say so." : "Generating…") : "Found \(passages.count) source\(passages.count == 1 ? "" : "s"); generating…"
            }
            let prompt = Prompting.messages(history: history, userQuestion: question, passages: passages, useLibrary: useLibrary, leading: answer.leadingPassageLabel)
            do {
                var pending = ""
                var lastFlush = Date()
                let started = Date()
                for try await event in client.streamEvents(messages: prompt, options: ChatOptions(profile: self.profile)) {
                    switch event {
                    case .reasoning(let chars):
                        if self.messages[idx].content.isEmpty { self.statusLine = String(format: "Thinking… %.0fs (%@ reasons before it answers)", Date().timeIntervalSince(started), self.profile.displayName) ; _ = chars }
                    case .content(let delta):
                        if self.statusLine?.hasPrefix("Thinking") == true { self.statusLine = "Writing the answer…" }
                        pending += delta
                        if Date().timeIntervalSince(lastFlush) > 0.05 {
                            self.messages[idx].content += pending; pending = ""; lastFlush = Date()
                        }
                    }
                }
                self.messages[idx].content += pending
                // Correct citation labels the model mixed up, using the passages it was given.
                if !passages.isEmpty {
                    let (fixed, corrections) = CitationVerifier.correct(answer: self.messages[idx].content, passages: passages)
                    if !corrections.isEmpty { self.messages[idx].content = fixed }
                }
            } catch is CancellationError {
                self.messages[idx].content += self.messages[idx].content.isEmpty ? "(stopped)" : "\n\n_(stopped)_"
            } catch {
                if (error as NSError).code == NSURLErrorCancelled { self.messages[idx].content += "\n\n_(stopped)_" }
                else { self.messages[idx].error = error.userFacing.message + (error.userFacing.recovery.map { " " + $0 } ?? "") }
            }
            self.messages[idx].isStreaming = false
            if self.messages[idx].content.isEmpty && self.messages[idx].error == nil { self.messages[idx].content = "(no answer)" }
            try? self.store?.save(self.messages[idx], in: conv.id)
            self.finish()
        }
    }

    private func finish() {
        isGenerating = false
        statusLine = nil
        task = nil
    }
}
