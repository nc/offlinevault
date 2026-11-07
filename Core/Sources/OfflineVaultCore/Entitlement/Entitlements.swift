import Foundation

/// Where downloads come from. The plan gate applies only to OfflineVault's own service; a self-hosted source is the
/// owner's business and is never gated. The fixture server stands in for the official service.
public enum UpdateSource: Equatable, Sendable {
    case offlineVault
    case selfHosted(URL)

    public init(baseURL: URL) {
        let official = [Config.UPDATES_BASE_URL, Config.fixtureServerURL].map { ($0.host, $0.port) }
        self = official.contains { $0 == (baseURL.host, baseURL.port) } ? .offlineVault : .selfHosted(baseURL)
    }
}

/// Why one artefact (or sharing) is not available right now. Each case owns its user-facing copy so every surface
/// says the same thing.
public enum Denial: Equatable, Sendable {
    case needsPlan
    case expired(Date)
    case tierNotInPlan(ContentTier, Level)
    case modelNotInPlan(Level)
    case sharingNotInPlan(Level)

    /// What a banner or settings link should do about it. `.buy` and `.upgrade` open the pricing page; `.activate` opens Settings › Licence.
    public enum Fix: Equatable, Sendable { case buy, activate, upgrade }

    public var title: String {
        switch self {
        case .needsPlan: return "Needs a plan"
        case .expired: return "Refreshes lapsed"
        case .tierNotInPlan, .modelNotInPlan: return "Included with Household"
        case .sharingNotInPlan: return "Wi-Fi sharing comes with Household"
        }
    }

    public var message: String {
        let keeps = "Everything already installed keeps working."
        switch self {
        case .needsPlan: return "This download needs a Core or Household plan. The free tier and content you add yourself need no plan, and \(keeps.lowercasedFirst)"
        case .expired(let d): return "Your refreshes ended on \(DayFormat.string(d)). New editions are paused until you renew them. The free tier still downloads, and \(keeps.lowercasedFirst)"
        case .tierNotInPlan(let tier, let level): return "\(tier.title) content is part of the Household plan; \(level.title) includes the Core tier. \(keeps)"
        case .modelNotInPlan: return "Larger models are part of the Household plan; Core includes the default 4B model. \(keeps)"
        case .sharingNotInPlan: return "Sharing the library over Wi-Fi is part of the Household plan."
        }
    }

    public var fix: Fix {
        switch self {
        case .needsPlan: return .buy
        case .expired: return .activate
        case .tierNotInPlan, .modelNotInPlan, .sharingNotInPlan: return .upgrade
        }
    }
}

/// Everything the app may do under the current licence, resolved once per `refreshLibraryState` and published by
/// AppModel. Pure value; nothing here touches disk or network.
public struct Entitlements: Equatable, Sendable {
    public let level: Level
    public let plan: Plan?
    /// True when the plan carries sharing (household, drive, founder). Survives expiry and step-down on purpose.
    public let sharing: Bool
    /// Set when refreshes have lapsed: new editions pause, the free tier and everything installed stay available.
    public let lapsedOn: Date?
    public let source: UpdateSource
    /// One line for the Settings header and Readiness: "Household, refreshes until 3 Jan 2029", "Core, refreshes ended 2 Oct 2026", "No plan".
    public let label: String

    public static func resolve(status: LicenceStatus, source: UpdateSource, now: Date = Date()) -> Entitlements {
        switch status {
        case .none, .invalid:
            return Entitlements(level: .free, plan: nil, sharing: false, lapsedOn: nil, source: source, label: "No plan")
        case .expired(let l):
            return Entitlements(level: .free, plan: l.plan, sharing: l.plan.grantsSharing, lapsedOn: l.expiresAt, source: source,
                                label: "\(l.plan.title), refreshes ended \(DayFormat.string(l.expiresAt!))")
        case .valid(let l):
            let level = l.level(at: now)
            var label = l.plan.title
            if l.plan == .founder { label += level == .household ? " (Household until \(DayFormat.string(l.householdUntil!)))" : " (Core for life)" }
            if let e = l.expiresAt { label += ", refreshes until \(DayFormat.string(e))" }
            return Entitlements(level: level, plan: l.plan, sharing: l.plan.grantsSharing, lapsedOn: nil, source: source, label: label)
        }
    }

    /// The single download gate. nil means "may download". The grant for the current level is checked first, so
    /// the free tier downloads with no plan and after a lapse; the reason given for anything else is the most
    /// specific one: lapsed, then no plan, then the tier or model the plan lacks.
    public func denial(for artefact: Artefact) -> Denial? {
        if case .selfHosted = source { return nil }
        let grant = Grant.forLevel(level)
        let modelGranted = artefact.kind != .model || grant.modelArtefactIds.contains(artefact.id)
        let tierGranted = grant.tiers.contains(artefact.contentTier)
        if modelGranted && tierGranted { return nil }
        if let lapsed = lapsedOn { return .expired(lapsed) }
        guard plan != nil else { return .needsPlan }
        return modelGranted ? .tierNotInPlan(artefact.contentTier, level) : .modelNotInPlan(level)
    }

    /// Splits a selection into what can be enqueued and what cannot, keeping order and pairing each rejection with its reason.
    public func partition(_ changes: [ManifestDiff.Change]) -> (allowed: [ManifestDiff.Change], denied: [(ManifestDiff.Change, Denial)]) {
        var allowed: [ManifestDiff.Change] = []
        var denied: [(ManifestDiff.Change, Denial)] = []
        for c in changes {
            if let d = denial(for: c.artefact) { denied.append((c, d)) } else { allowed.append(c) }
        }
        return (allowed, denied)
    }

    /// Denial for turning sharing on; nil when allowed. A lapsed Household stays allowed.
    public var sharingDenial: Denial? { sharing ? nil : .sharingNotInPlan(level) }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
