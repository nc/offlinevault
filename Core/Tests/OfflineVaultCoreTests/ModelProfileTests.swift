import XCTest
@testable import OfflineVaultCore

final class ModelProfileTests: XCTestCase {
    func testProfileDetectionAndOptions() {
        XCTAssertEqual(ModelProfile.detect(fileName: "Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf"), .museGlimmer)
        XCTAssertEqual(ModelProfile.detect(fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"), .qwen3)
        XCTAssertEqual(ModelProfile.detect(fileName: "mistral-7b.gguf"), .generic)
        let g = ChatOptions(profile: .museGlimmer)
        XCTAssertEqual(g.templateKwargs["reasoning_strength"], "low"); XCTAssertEqual(g.topK, 64); XCTAssertEqual(g.temperature, 0.7, accuracy: 0.001)
        let q = ChatOptions(profile: .qwen3)
        XCTAssertEqual(q.templateKwargs["enable_thinking"], "false"); XCTAssertNil(q.topK)
        XCTAssertEqual(ModelProfile.museGlimmer.contextSize(physicalMemory: 32 << 30), 16384)
        XCTAssertEqual(ModelProfile.museGlimmer.contextSize(physicalMemory: 64 << 30), 32768)
        XCTAssertEqual(ModelProfile.qwen3.contextSize(physicalMemory: 8 << 30), 8192)
    }

    func testServerArgumentsIncludeTemplateKwargsAndDrafter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let modelURL = dir.appendingPathComponent("Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf"); try Data("x".utf8).write(to: modelURL)
        let draftURL = dir.appendingPathComponent("dflash-Muse-Glimmer-30B-Q4_K_M.gguf"); try Data("y".utf8).write(to: draftURL)
        let scanned = LocalModel.scan(dir)
        XCTAssertEqual(scanned.map(\.id), [modelURL.lastPathComponent], "drafter is not offered as a chat model")
        let m = scanned[0]
        XCTAssertEqual(m.profile.drafter(in: dir)?.lastPathComponent, draftURL.lastPathComponent)
        let args = LlamaServerService.arguments(for: m, port: 8766, physicalMemory: 32 << 30, drafter: draftURL)
        XCTAssertTrue(args.contains("--chat-template-kwargs")); XCTAssertTrue(args.contains { $0.contains("reasoning_strength") && $0.contains("low") })
        XCTAssertTrue(args.contains("-md") && args.contains("draft-dflash")); XCTAssertEqual(args[args.firstIndex(of: "-c")! + 1], "16384")
        let q = LocalModel(fileURL: dir.appendingPathComponent("Qwen3-4B-Instruct-2507-Q4_K_M.gguf"), displayName: "q", sizeBytes: 2_500_000_000)
        let qargs = LlamaServerService.arguments(for: q, port: 8766, physicalMemory: 16 << 30, drafter: nil)
        XCTAssertTrue(qargs.contains { $0.contains("enable_thinking") }); XCTAssertFalse(qargs.contains("-md"))
        // Memory guard
        let big = LocalModel(fileURL: modelURL, displayName: "g", sizeBytes: 16_800_000_000)
        XCTAssertFalse(big.memoryNeeded <= (16 << 30)); XCTAssertTrue(big.memoryNeeded <= (32 << 30))
    }
}
