import Foundation

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public var id: String
    public var role: Role
    public var content: String
    public var createdAt: Date
    /// Sources offered to the model for this assistant turn (so citations stay tappable after reload).
    public var sources: [RetrievedPassage]
    public var isStreaming: Bool = false
    public var error: String?
    /// Whether library search was on when this assistant turn was generated.
    public var usedLibrary: Bool = true
    /// Label of the Field Guide passage the transcript shows word for word before `content`
    /// (`RetrievalCoordinator.fieldGuideLead`); the text lives in `sources`, not in `content`.
    public var leadingPassageLabel: Int?
    public var leadingPassage: RetrievedPassage? { leadingPassageLabel.flatMap { l in sources.first { $0.label == l } } }

    public init(id: String = UUID().uuidString, role: Role, content: String, createdAt: Date = Date(), sources: [RetrievedPassage] = [], usedLibrary: Bool = true, leadingPassageLabel: Int? = nil) {
        self.id = id; self.role = role; self.content = content; self.createdAt = createdAt; self.sources = sources; self.usedLibrary = usedLibrary; self.leadingPassageLabel = leadingPassageLabel
    }
}

public struct ChatOptions: Sendable {
    public var temperature: Double = 0.3
    public var topP: Double = 0.9
    public var topK: Int? = nil
    public var maxTokens: Int = 1024
    /// Small models loop at low temperature; llama-server honours these OpenAI-style and llama.cpp-specific penalties.
    public var repeatPenalty: Double = 1.15
    public var frequencyPenalty: Double = 0.3
    public var presencePenalty: Double = 0.2
    /// Chat-template arguments (Qwen3: enable_thinking=false; Muse Glimmer: reasoning_strength=low).
    public var templateKwargs: [String: String] = ["enable_thinking": "false"]
    public init() {}
    public init(profile: ModelProfile) {
        temperature = profile.temperature; topP = profile.topP; topK = profile.topK; repeatPenalty = profile.repeatPenalty
        templateKwargs = profile.templateKwargs
        if profile == .museGlimmer { frequencyPenalty = 0; presencePenalty = 0 }
    }
}

/// What a streaming backend emits: visible text, or progress of a hidden reasoning phase.
public enum ChatEvent: Sendable, Equatable { case content(String), reasoning(characters: Int) }

/// Abstracts the model backend so the chat pipeline can be tested with a fake.
public protocol LLMClient: Sendable {
    /// Streams visible content deltas only.
    func streamChat(messages: [(role: String, content: String)], options: ChatOptions) -> AsyncThrowingStream<String, Error>
    /// Streams content deltas plus reasoning progress (models like Muse Glimmer think before answering).
    func streamEvents(messages: [(role: String, content: String)], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error>
}

public extension LLMClient {
    func streamEvents(messages: [(role: String, content: String)], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { do { for try await s in streamChat(messages: messages, options: options) { continuation.yield(.content(s)) }; continuation.finish() } catch { continuation.finish(throwing: error) } }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Client for llama-server's OpenAI-compatible `/v1/chat/completions` with SSE streaming.
public struct OpenAICompatibleClient: LLMClient {
    public let baseURL: URL
    public let model: String
    public init(baseURL: URL, model: String = "local") { self.baseURL = baseURL; self.model = model }

    public func streamChat(messages: [(role: String, content: String)], options: ChatOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { do { for try await ev in streamEvents(messages: messages, options: options) { if case .content(let s) = ev { continuation.yield(s) } }; continuation.finish() } catch { continuation.finish(throwing: error) } }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func streamEvents(messages: [(role: String, content: String)], options: ChatOptions) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 600
                    var body: [String: Any] = [
                        "model": model,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                        "stream": true,
                        "temperature": options.temperature,
                        "top_p": options.topP,
                        "max_tokens": options.maxTokens,
                        "repeat_penalty": options.repeatPenalty,
                        "frequency_penalty": options.frequencyPenalty,
                        "presence_penalty": options.presencePenalty,
                    ]
                    if let k = options.topK { body["top_k"] = k }
                    if !options.templateKwargs.isEmpty {
                        body["chat_template_kwargs"] = options.templateKwargs.mapValues { v -> Any in if v == "true" { return true }; if v == "false" { return false }; return v }
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await LocalHTTP.session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var errText = ""
                        for try await line in bytes.lines { errText += line }
                        throw UserFacingError("The AI model returned an error", message: "HTTP \(http.statusCode): \(errText.prefix(300))", recovery: "Restart the model from Settings › Models. If the context is too long, start a new conversation.")
                    }
                    var filter = ThinkingFilter()
                    var reasoningChars = 0
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { throw UserFacingError("The AI model returned an error", message: msg) }
                        guard let choices = obj["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any] else { continue }
                        if let r = delta["reasoning_content"] as? String, !r.isEmpty { reasoningChars += r.count; continuation.yield(.reasoning(characters: reasoningChars)) }
                        if let content = delta["content"] as? String, !content.isEmpty {
                            let visible = filter.feed(content)
                            if !visible.isEmpty { continuation.yield(.content(visible)) }
                        }
                    }
                    let tail = filter.flush()
                    if !tail.isEmpty { continuation.yield(.content(tail)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Removes `<think>…</think>` blocks from a token stream (defence in depth when a template still emits them).
public struct ThinkingFilter: Sendable {
    private var buffer = ""
    private var inThink = false
    public init() {}

    public mutating func feed(_ chunk: String) -> String {
        buffer += chunk
        var out = ""
        while true {
            if inThink {
                if let r = buffer.range(of: "</think>") { buffer = String(buffer[r.upperBound...]); inThink = false; continue }
                buffer = String(buffer.suffix(8)); return out // keep a tail in case the closing tag is split
            } else {
                if let r = buffer.range(of: "<think>") {
                    out += String(buffer[..<r.lowerBound]); buffer = String(buffer[r.upperBound...]); inThink = true; continue
                }
                // Emit everything except a possible partial "<think" prefix at the end.
                if let lt = buffer.lastIndex(of: "<"), "<think>".hasPrefix(String(buffer[lt...])) {
                    out += String(buffer[..<lt]); buffer = String(buffer[lt...])
                } else { out += buffer; buffer = "" }
                return out
            }
        }
    }

    public mutating func flush() -> String {
        defer { buffer = "" }
        return inThink ? "" : buffer
    }
}
