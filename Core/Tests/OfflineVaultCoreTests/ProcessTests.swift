import XCTest
@testable import OfflineVaultCore

final class ProcessTests: XCTestCase {

    func testManagedProcessRestartsAfterCrash() async throws {
        let spec = ManagedProcess.Spec(name: "sleeper", executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], healthCheck: { true }, startupTimeout: 5, autoRestart: true)
        let p = ManagedProcess(spec: spec)
        try await p.start()
        let first = try XCTUnwrap(p.pid)
        let seen = Seen()
        p.observeState { s in Task { await seen.add(s) } }
        kill(first, SIGKILL)
        for _ in 0..<50 where p.pid == first || p.state != .running { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(p.state, .running, "a crashed helper is started again within a few seconds")
        XCTAssertNotEqual(p.pid, first)
        let states = await seen.states
        XCTAssertTrue(states.contains(.crashed(exitCode: SIGKILL)), "the crash was observed first: \(states)")
        p.stop()
        XCTAssertEqual(p.state, .stopped)
    }
}

private actor Seen {
    var states: [ManagedProcess.State] = []
    func add(_ s: ManagedProcess.State) { states.append(s) }
}
