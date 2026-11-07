import XCTest
@testable import OfflineVaultCore

/// Structural checks on the plan gate: where it may be consulted, and that the plan table agrees with the website.
final class GateTests: XCTestCase {
    static let repoRoot = FixtureIntegrationTests.repoRoot

    /// Never locks: nothing that serves installed content may read the licence or the entitlements.
    func testNoLicenceReadsInContentServingCode() throws {
        let zones = ["Core/Sources/OfflineVaultCore/Reference", "Core/Sources/OfflineVaultCore/Database", "Core/Sources/OfflineVaultCore/Share", "Core/Sources/OfflineVaultCore/Documents", "OfflineVault/ChatController.swift"]
        let forbidden = ["LicenceStatus", "LicenceVerifier", "EntitlementService", "Entitlements", "licenceStatus", "entitlements", "Grant.forLevel", "denial(for", "allowsLibraryUse"]
        var files: [URL] = []
        for zone in zones {
            let url = Self.repoRoot.appendingPathComponent(zone)
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), "zone missing: \(zone)")
            if isDir.boolValue {
                files += (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            } else { files.append(url) }
        }
        XCTAssertGreaterThan(files.count, 5)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for token in forbidden where text.contains(token) {
                XCTFail("\(f.lastPathComponent) mentions \(token): content-serving code must never consult the plan")
            }
        }
    }

    /// `website/plans.json` is the worker's plan table. Its ids and seats must match `Plan`.
    func testPlanTableMatchesWebsite() throws {
        let path = ProcessInfo.processInfo.environment["OV_PLANS_JSON"] ?? Self.repoRoot.appendingPathComponent("website/plans.json").path
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("website/plans.json is absent (the worker owner commits it); set OV_PLANS_JSON to check another checkout") }
        struct Table: Decodable { struct Row: Decodable { let id: String; let seats: Int }; let plans: [Row] }
        let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(table.plans.map(\.id), Plan.allCases.map(\.rawValue))
        for row in table.plans { XCTAssertEqual(row.seats, Plan(rawValue: row.id)?.defaultSeats, "seats for \(row.id)") }
    }

    func testReadinessPlanLine() {
        let now = Date()
        let mirror = URL(string: "http://kiwix.local:8080/")!
        func item(_ status: LicenceStatus, _ source: UpdateSource = .offlineVault) -> ReadinessReport.Item { ReadinessCheck.licenceItem(.resolve(status: status, source: source, now: now)) }
        let free = item(.none)
        XCTAssertEqual(free.status, .warn); XCTAssertEqual(free.fix, "licence"); XCTAssertTrue(free.detail.hasPrefix("No plan."))
        let selfHosted = item(.none, .selfHosted(mirror))
        XCTAssertEqual(selfHosted.status, .pass); XCTAssertNil(selfHosted.fix); XCTAssertTrue(selfHosted.detail.contains("kiwix.local"))
        let licence = Licence(licenceId: "L", subscriber: "s", plan: .household, issuedAt: now, expiresAt: now.addingTimeInterval(86400))
        let valid = item(.valid(licence))
        XCTAssertEqual(valid.status, .pass); XCTAssertTrue(valid.detail.hasPrefix("Household, refreshes until"))
        var lapsedLicence = licence; lapsedLicence.expiresAt = now.addingTimeInterval(-86400)
        let lapsed = item(.expired(lapsedLicence))
        XCTAssertEqual(lapsed.status, .warn); XCTAssertEqual(lapsed.fix, "licence")
        XCTAssertTrue(lapsed.detail.contains("refreshes ended") && lapsed.detail.contains("keeps working") && lapsed.detail.contains("free tier"), lapsed.detail)
        let lapsedSelfHosted = item(.expired(lapsedLicence), .selfHosted(mirror))
        XCTAssertEqual(lapsedSelfHosted.status, .pass, "a self-hosted source is never gated, lapsed plan or not")
        XCTAssertNil(lapsedSelfHosted.fix)
        XCTAssertTrue(lapsedSelfHosted.detail.contains("kiwix.local"), lapsedSelfHosted.detail)
    }
}
