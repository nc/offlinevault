import XCTest
@testable import OfflineVaultCore

/// Drives the real HTTP client against `scripts/fixture_server.py`'s issuer stand-in.
///
///     OV_INTEGRATION=1 swift test --filter LicenceServerIntegrationTests
final class LicenceServerIntegrationTests: XCTestCase {
    static let repoRoot = FixtureIntegrationTests.repoRoot
    let port = 8798
    var server: Process?
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }
    var client: LicenceActivationClient { LicenceActivationClient(baseURL: baseURL) }
    let verifier = try! LicenceVerifier(keys: Config.licencePublicKeys)

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OV_INTEGRATION"] == "1", "set OV_INTEGRATION=1 to run the fixture-server licence tests")
        FixtureIntegrationTests.killListeners(onPort: port)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", Self.repoRoot.appendingPathComponent("scripts/fixture_server.py").path, "--root", Self.repoRoot.appendingPathComponent("fixture").path, "--port", String(port)]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        server = p
        for _ in 0..<50 { if FixtureIntegrationTests.isPortOpen(port) { return }; try await Task.sleep(nanoseconds: 100_000_000) }
        XCTFail("fixture server did not start")
    }

    override func tearDown() {
        if let p = server, p.isRunning { p.terminate() }
        server = nil
        FixtureIntegrationTests.killListeners(onPort: port)
    }

    func request(_ key: String, device: String = "mac-under-test") -> ActivationRequest {
        ActivationRequest(key: LicenceKey(userInput: key)!, deviceId: device, deviceName: "Test Mac", appVersion: Config.appVersion)
    }

    func testActivateCoreAndHouseholdKeys() async throws {
        let core = try await client.activate(request("OV-DEVC-2345-6789-ABCD"))
        guard case .valid(let l) = verifier.verify(core.licence) else { return XCTFail("core file must verify with the dev key") }
        XCTAssertEqual(l.plan, .core); XCTAssertEqual(core.seatLimit, 2)
        XCTAssertEqual(core.seats.map(\.deviceId), ["mac-under-test"])
        XCTAssertEqual(core.seats.first?.deviceName, "Test Mac")

        let household = try await client.activate(request("ov devh 2345 6789 abcd"))
        guard case .valid(let h) = verifier.verify(household.licence) else { return XCTFail("household file must verify") }
        XCTAssertEqual(h.plan, .household); XCTAssertEqual(household.seatLimit, 6)

        let again = try await client.activate(request("OV-DEVC-2345-6789-ABCD"))
        XCTAssertEqual(again.seats.count, 1, "a known device uses no seat")
        let second = try await client.activate(request("OV-DEVC-2345-6789-ABCD", device: "second-mac"))
        XCTAssertEqual(second.seats.count, 2)
        do { _ = try await client.activate(request("OV-DEVC-2345-6789-ABCD", device: "third-mac")); XCTFail("third Mac must be refused") }
        catch let e as ActivationError { if case .seatsExhausted(let seats) = e { XCTAssertEqual(seats.count, 2) } else { XCTFail("\(e)") } }
        let after = try await client.deactivate(key: LicenceKey(userInput: "OV-DEVC-2345-6789-ABCD")!, deviceId: "second-mac")
        XCTAssertEqual(after.map(\.deviceId), ["mac-under-test"])
    }

    func testSeatFamilyIs409AndUnknownIs404AndExpiredIsExpired() async throws {
        do { _ = try await client.activate(request("OV-DEVS-2345-6789-ABCD")); XCTFail("must be 409") }
        catch let e as ActivationError {
            guard case .seatsExhausted(let seats) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(seats.map(\.deviceName), ["Kitchen Mac mini", "Study MacBook"])
            XCTAssertTrue(e.userFacing.message.contains("2 Macs"))
        }
        do { _ = try await client.activate(request("OV-ZZZZ-2345-6789-ABCD")); XCTFail("must be 404") }
        catch let e as ActivationError { XCTAssertEqual(e, .unknownKey) }
        let expired = try await client.activate(request("OV-DEVX-2345-6789-ABCD"))
        if case .expired(let l) = verifier.verify(expired.licence) { XCTAssertEqual(l.plan, .core) } else { XCTFail("DEVX must be an expired core file") }
        let founder = try await client.activate(request("OV-DEVF-2345-6789-ABCD"))
        XCTAssertEqual(verifier.verify(founder.licence).licence?.plan, .founder)
        let drive = try await client.activate(request("OV-DEVD-2345-6789-ABCD"))
        XCTAssertEqual(verifier.verify(drive.licence).licence?.level(at: Date()), .household)
    }

    func testOfflineMapsToOfflineError() async throws {
        let dead = LicenceActivationClient(baseURL: URL(string: "http://127.0.0.1:1/")!)
        do { _ = try await dead.activate(request("OV-DEVC-2345-6789-ABCD")); XCTFail("must throw") }
        catch let e as ActivationError { XCTAssertEqual(e, .offline) }
    }

    func testEntitlementServiceEndToEndAgainstTheFixtureServer() async throws {
        let layout = try makeTempLibrary(self)
        let suite = "ov-tests-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let svc = EntitlementService(verifier: verifier, layout: layout, issuer: client, settings: AppSettings(defaults: UserDefaults(suiteName: suite)!))
        let status = try await svc.activate(key: LicenceKey(userInput: "OV-DEVH-2345-6789-ABCD")!)
        XCTAssertEqual(status.licence?.plan, .household)
        XCTAssertEqual(svc.entitlements(source: .offlineVault).level, .household)
        let seats = try await svc.seats()
        XCTAssertEqual(seats.count, 1)
        _ = try await svc.deactivate(deviceId: svc.settings.deviceId)
        XCTAssertEqual(svc.currentStatus(), .none)
    }
}
