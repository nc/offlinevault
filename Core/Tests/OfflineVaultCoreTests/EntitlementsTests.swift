import XCTest
@testable import OfflineVaultCore

final class EntitlementsTests: XCTestCase {
    // Local midnight, so the day labels below read the same whatever time zone the Mac running the tests is in.
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1))!
    let far = Calendar.current.date(from: DateComponents(year: 2099, month: 1, day: 1))!
    let selfHosted = UpdateSource.selfHosted(URL(string: "https://mirror.example/")!)

    func artefact(_ id: String, _ kind: ArtefactKind = .zim, tier: ContentTier = .core) -> Artefact {
        Artefact(id: id, kind: kind, path: "\(kind.rawValue)/\(id)", sizeBytes: 1, sha256: String(repeating: "a", count: 64), tier: tier.rawValue)
    }
    var freeZim: Artefact { artefact("zim-fieldguide", tier: .free) }
    var coreZim: Artefact { artefact("zim-core") }
    var fullZim: Artefact { artefact("zim-full", tier: .full) }
    var completeMap: Artefact { artefact("map-world", .map, tier: .complete) }
    var defaultModel: Artefact { artefact(Config.defaultModelArtefactId, .model) }
    var largeModel: Artefact { artefact(Config.largeModelArtefactId, .model) }
    var glimmer: Artefact { artefact(Config.glimmerModelArtefactId, .model) }

    func licence(_ plan: Plan, expires: Date? = nil, householdUntil: Date? = nil) -> Licence {
        Licence(licenceId: "L", subscriber: "s", plan: plan, issuedAt: now.addingTimeInterval(-86400), expiresAt: expires ?? (plan == .founder ? nil : far), householdUntil: householdUntil)
    }
    func resolve(_ status: LicenceStatus, source: UpdateSource = .offlineVault, at date: Date? = nil) -> Entitlements {
        Entitlements.resolve(status: status, source: source, now: date ?? now)
    }

    func testTable() {
        struct Row { let name: String; let e: Entitlements; let coreZim: Denial?; let fullZim: Denial?; let complete: Denial?; let largeModel: Denial?; let sharing: Bool; let label: String }
        let householdUntil = Calendar.current.date(byAdding: .day, value: 30, to: now)!
        let lapsed = now.addingTimeInterval(-86400)
        let rows: [Row] = [
            Row(name: "free on official", e: resolve(.none), coreZim: .needsPlan, fullZim: .needsPlan, complete: .needsPlan, largeModel: .needsPlan, sharing: false, label: "No plan"),
            Row(name: "free on self-hosted", e: resolve(.none, source: selfHosted), coreZim: nil, fullZim: nil, complete: nil, largeModel: nil, sharing: false, label: "No plan"),
            Row(name: "invalid file", e: resolve(.invalid(reason: "x")), coreZim: .needsPlan, fullZim: .needsPlan, complete: .needsPlan, largeModel: .needsPlan, sharing: false, label: "No plan"),
            Row(name: "core", e: resolve(.valid(licence(.core))), coreZim: nil, fullZim: .tierNotInPlan(.full, .core), complete: .tierNotInPlan(.complete, .core), largeModel: .modelNotInPlan(.core), sharing: false, label: "Core, refreshes until 1 Jan 2099"),
            Row(name: "household", e: resolve(.valid(licence(.household))), coreZim: nil, fullZim: nil, complete: nil, largeModel: nil, sharing: true, label: "Household, refreshes until 1 Jan 2099"),
            Row(name: "drive", e: resolve(.valid(licence(.drive))), coreZim: nil, fullZim: nil, complete: nil, largeModel: nil, sharing: true, label: "Vault Drive, refreshes until 1 Jan 2099"),
            Row(name: "founder before step-down", e: resolve(.valid(licence(.founder, householdUntil: householdUntil))), coreZim: nil, fullZim: nil, complete: nil, largeModel: nil, sharing: true, label: "Founder (Household until 1 Dec 2026)"),
            Row(name: "founder after step-down", e: resolve(.valid(licence(.founder, householdUntil: householdUntil)), at: householdUntil), coreZim: nil, fullZim: .tierNotInPlan(.full, .core), complete: .tierNotInPlan(.complete, .core), largeModel: .modelNotInPlan(.core), sharing: true, label: "Founder (Core for life)"),
            Row(name: "lapsed household", e: resolve(.expired(licence(.household, expires: lapsed))), coreZim: .expired(lapsed), fullZim: .expired(lapsed), complete: .expired(lapsed), largeModel: .expired(lapsed), sharing: true, label: "Household, refreshes ended 31 Oct 2026"),
            Row(name: "lapsed core on self-hosted", e: resolve(.expired(licence(.core, expires: lapsed)), source: selfHosted), coreZim: nil, fullZim: nil, complete: nil, largeModel: nil, sharing: false, label: "Core, refreshes ended 31 Oct 2026"),
        ]
        for r in rows {
            XCTAssertNil(r.e.denial(for: freeZim), "\(r.name): the free tier downloads with no plan, after a lapse, and on every plan")
            XCTAssertEqual(r.e.denial(for: coreZim), r.coreZim, "\(r.name): core zim")
            XCTAssertEqual(r.e.denial(for: fullZim), r.fullZim, "\(r.name): full zim")
            XCTAssertEqual(r.e.denial(for: completeMap), r.complete, "\(r.name): complete map")
            XCTAssertEqual(r.e.denial(for: largeModel), r.largeModel, "\(r.name): 8B model")
            XCTAssertEqual(r.e.denial(for: glimmer), r.largeModel, "\(r.name): 30B model")
            XCTAssertEqual(r.e.sharing, r.sharing, "\(r.name): sharing")
            XCTAssertEqual(r.e.sharingDenial == nil, r.sharing, "\(r.name): sharing denial follows the flag")
            XCTAssertEqual(r.e.label, r.label, "\(r.name): label")
        }
    }

    func testDefaultModelFollowsTheTierRuleNotTheModelRule() {
        let core = resolve(.valid(licence(.core)))
        XCTAssertNil(core.denial(for: defaultModel))
        XCTAssertEqual(core.denial(for: artefact(Config.defaultModelArtefactId, .model, tier: .full)), .tierNotInPlan(.full, .core))
    }

    func testPartitionKeepsOrderAndPairsReasons() {
        let core = resolve(.valid(licence(.core)))
        let changes = [fullZim, coreZim, largeModel, completeMap, defaultModel, freeZim].map { ManifestDiff.Change(artefact: $0, reason: .new, removesInstalledId: nil) }
        let (allowed, denied) = core.partition(changes)
        XCTAssertEqual(allowed.map(\.id), ["zim-core", Config.defaultModelArtefactId, "zim-fieldguide"])
        XCTAssertEqual(denied.map(\.0.id), ["zim-full", Config.largeModelArtefactId, "map-world"])
        XCTAssertEqual(denied.map(\.1), [.tierNotInPlan(.full, .core), .modelNotInPlan(.core), .tierNotInPlan(.complete, .core)])
        let household = resolve(.valid(licence(.household)))
        XCTAssertEqual(household.partition(changes).allowed.count, 6)
        XCTAssertTrue(household.partition(changes).denied.isEmpty)
        let none = resolve(.none)
        XCTAssertEqual(none.partition(changes).allowed.map(\.id), ["zim-fieldguide"], "no plan: only the free tier")
        XCTAssertEqual(none.partition(changes).denied.map(\.1), Array(repeating: Denial.needsPlan, count: 5))
        let lapsed = resolve(.expired(licence(.household, expires: now.addingTimeInterval(-86400))))
        XCTAssertEqual(lapsed.partition(changes).allowed.map(\.id), ["zim-fieldguide"], "lapsed: the free tier still downloads")
    }

    func testDenialCopyAndFixes() {
        XCTAssertEqual(Denial.needsPlan.fix, .buy)
        XCTAssertEqual(Denial.expired(now).fix, .activate)
        XCTAssertEqual(Denial.tierNotInPlan(.full, .core).fix, .upgrade)
        XCTAssertEqual(Denial.modelNotInPlan(.core).fix, .upgrade)
        XCTAssertEqual(Denial.sharingNotInPlan(.free).fix, .upgrade)
        for d in [Denial.needsPlan, .expired(now), .tierNotInPlan(.complete, .core), .modelNotInPlan(.core)] {
            XCTAssertTrue(d.message.lowercased().contains("keeps working"), "never-locks sentence in: \(d.message)")
            XCTAssertFalse(d.message.contains("lock"), d.message)
        }
        XCTAssertTrue(Denial.expired(now).message.contains("1 Nov 2026"))
    }

    /// Plan copy carries dates in one fixed form so Settings, banners and Readiness read the same in every locale,
    /// and so the label assertions above hold on any machine.
    func testPlanDatesAreLocaleIndependent() {
        XCTAssertEqual(DayFormat.string(now), "1 Nov 2026")
        XCTAssertEqual(DayFormat.string(far), "1 Jan 2099")
        XCTAssertEqual(now.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "en_US"))), "Nov 1, 2026", "the locale changes the form, so the pin matters")
        XCTAssertTrue(LicenceStatus.expired(licence(.core, expires: now)).summary.hasSuffix("refreshes ended on 1 Nov 2026"))
        XCTAssertTrue(LicenceStatus.valid(licence(.core)).summary.hasSuffix("until 1 Jan 2099"))
        XCTAssertTrue(ActivationError.ended(now).userFacing.message.contains("1 Nov 2026"))
    }

    func testUpdateSource() {
        XCTAssertEqual(UpdateSource(baseURL: Config.UPDATES_BASE_URL), .offlineVault)
        XCTAssertEqual(UpdateSource(baseURL: Config.UPDATES_BASE_URL.appendingPathComponent("prefix/")), .offlineVault)
        XCTAssertEqual(UpdateSource(baseURL: Config.fixtureServerURL), .offlineVault, "the fixture server stands in for the official service")
        let mirror = URL(string: "http://kiwix.local:8080/")!
        XCTAssertEqual(UpdateSource(baseURL: mirror), .selfHosted(mirror))
        XCTAssertEqual(UpdateSource(baseURL: URL(string: "http://127.0.0.1:9999/")!), .selfHosted(URL(string: "http://127.0.0.1:9999/")!), "another local port is somebody else's server")
    }
}
