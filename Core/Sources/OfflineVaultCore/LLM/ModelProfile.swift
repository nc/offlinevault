import Foundation

/// Per-model knowledge the app needs to run a GGUF well: sampling defaults, chat-template arguments, memory
/// needs and speculative-decoding drafters. Detected from the file name so user-imported models work too.
public enum ModelProfile: String, Sendable, CaseIterable {
    case qwen3, museGlimmer, generic

    public static func detect(fileName: String) -> ModelProfile {
        let n = fileName.lowercased()
        if n.contains("muse-glimmer") || n.contains("muse_glimmer") || n.contains("museglimmer") { return .museGlimmer }
        if n.contains("qwen3") || n.contains("qwen-3") { return .qwen3 }
        return .generic
    }

    public var displayName: String {
        switch self { case .qwen3: return "Qwen3"; case .museGlimmer: return "Muse Glimmer"; case .generic: return "GGUF model" }
    }

    /// Sampling the model's authors recommend. Grounded answers run cooler than the general default.
    public var temperature: Double { self == .museGlimmer ? 0.7 : 0.3 }
    public var topP: Double { self == .museGlimmer ? 0.95 : 0.9 }
    public var topK: Int? { self == .museGlimmer ? 64 : nil }
    public var repeatPenalty: Double { self == .museGlimmer ? 1.05 : 1.15 }

    /// Extra chat-template arguments sent with every request (llama-server `chat_template_kwargs`).
    /// Qwen3: thinking off. Muse Glimmer: reasoning cannot be disabled; "low" keeps cited answers fast.
    public var templateKwargs: [String: String] {
        switch self {
        case .qwen3: return ["enable_thinking": "false"]
        case .museGlimmer: return ["reasoning_strength": "low"]
        case .generic: return [:]
        }
    }

    /// Context window to allocate: large contexts cost KV-cache memory a 30B model cannot spare on a 32 GB Mac.
    public func contextSize(physicalMemory: UInt64) -> Int {
        switch self {
        case .museGlimmer: return physicalMemory >= 64 * 1024 * 1024 * 1024 ? 32768 : 16384
        default: return physicalMemory <= 8 * 1024 * 1024 * 1024 ? 8192 : 16384
        }
    }

    /// Memory the OS, helpers and KV cache need on top of the model weights.
    public static let headroomBytes: UInt64 = 6 * 1024 * 1024 * 1024

    /// A speculative-decoding drafter that pairs with this model, if the file is present next to it.
    public func drafter(in directory: URL) -> URL? {
        guard self == .museGlimmer, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return files.first { $0.lastPathComponent.lowercased().hasPrefix("dflash-") && $0.pathExtension.lowercased() == "gguf" }
    }

    /// Server flags for the drafter (llama.cpp DFlash speculative decoding).
    public func drafterArguments(_ draft: URL) -> [String] {
        ["-md", draft.path, "--spec-type", "draft-dflash", "-ngld", "99", "--spec-draft-n-max", "4"]
    }
}

public extension LocalModel {
    var profile: ModelProfile { ModelProfile.detect(fileName: fileURL.lastPathComponent) }
    /// Speculative-decoding drafters are helpers, not models to chat with.
    var isDrafter: Bool { fileURL.lastPathComponent.lowercased().hasPrefix("dflash-") || fileURL.lastPathComponent.lowercased().hasPrefix("mmproj-") }
    /// Rough live memory need: weights plus headroom.
    var memoryNeeded: UInt64 { UInt64(max(sizeBytes, 0)) + ModelProfile.headroomBytes }
    var fitsInMemory: Bool { memoryNeeded <= ProcessInfo.processInfo.physicalMemory }
}
