import SwiftUI
import OfflineVaultCore

struct UpdatesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library updates").font(.title2.bold())
            if let check = model.updateCheck {
                CatalogueBadge(trust: check.trust, release: check.manifest.version)
                if check.diff.isEmpty {
                    Label("Your library is up to date.", systemImage: "checkmark.seal").padding(.vertical)
                } else {
                    if let (_, d) = model.entitlements.partition(check.diff.changes).denied.first {
                        HStack(alignment: .top) {
                            Label(explanation(d), systemImage: "key").font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("See Plans") { model.buyLicence() }.controlSize(.small)
                        }
                    }
                    List {
                        ForEach(ContentTier.allCases, id: \.self) { tier in
                            let changes = check.diff.changes.filter { $0.artefact.contentTier == tier }
                            if !changes.isEmpty {
                                Section {
                                    ForEach(changes) { c in
                                        let denial = model.entitlements.denial(for: c.artefact)
                                        Toggle(isOn: Binding(get: { selected.contains(c.id) }, set: { on in if on { selected.insert(c.id) } else { selected.remove(c.id) } })) {
                                            HStack(alignment: .top) {
                                                Image(systemName: icon(c.artefact.kind)).frame(width: 20).accessibilityHidden(true)
                                                VStack(alignment: .leading) {
                                                    HStack(spacing: 6) {
                                                        Text(c.artefact.displayTitle).font(.headline)
                                                        if let e = c.artefact.external { ExternalTag(source: e) }
                                                    }
                                                    Text(reason(c)).font(.caption).foregroundStyle(.secondary)
                                                    if let s = c.artefact.summary { Text(s).font(.caption) }
                                                    if let e = c.artefact.external { Text(e.explanation).font(.caption).foregroundStyle(.secondary) }
                                                    if let d = denial { Text(d.title).font(.caption).foregroundStyle(.orange) }
                                                }
                                                Spacer()
                                                Text(ByteFormat.string(c.artefact.sizeBytes)).monospacedDigit()
                                            }
                                        }.toggleStyle(.checkbox).disabled(denial != nil)
                                    }
                                } header: {
                                    let (allowed, denied) = model.entitlements.partition(changes)
                                    HStack {
                                        Text("\(tier.title) · \(ByteFormat.string(changes.reduce(0) { $0 + $1.artefact.sizeBytes }))")
                                        Spacer()
                                        if allowed.isEmpty, let (_, d) = denied.first { Text(d.title).font(.caption).foregroundStyle(.orange) }
                                        else {
                                            Button(allowed.allSatisfy { selected.contains($0.id) } ? "Deselect All" : "Select All") {
                                                if allowed.allSatisfy({ selected.contains($0.id) }) { allowed.forEach { selected.remove($0.id) } } else { allowed.forEach { selected.insert($0.id) } }
                                            }.controlSize(.mini)
                                        }
                                    }
                                } footer: { Text(tier.summary).font(.caption2) }
                            }
                        }
                    }.frame(minHeight: 260)
                    let total = check.diff.changes.filter { selected.contains($0.id) }.reduce(Int64(0)) { $0 + $1.artefact.sizeBytes }
                    HStack {
                        Text("Selected: \(ByteFormat.string(total)) of \(ByteFormat.string(check.diff.totalDownloadBytes))")
                        Spacer()
                        if let s = model.storage { Text("Free: \(ByteFormat.string(s.volumeFreeBytes))").foregroundStyle(model.layout?.hasSpace(forAdditionalBytes: total) == true ? Color.secondary : Color.orange) }
                    }.font(.callout)
                }
                if !check.diff.incompatible.isEmpty {
                    Label("\(check.diff.incompatible.count) item(s) need a newer version of OfflineVault — update the app to get them.", systemImage: "info.circle").font(.caption)
                }
            }
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if let check = model.updateCheck, !check.diff.isEmpty {
                    Button("Download selected") { model.applyUpdates(check.diff.changes.filter { selected.contains($0.id) }); dismiss() }
                        .buttonStyle(.borderedProminent).disabled(selected.isEmpty)
                }
            }
        }
        .padding(20).frame(width: 560)
        .onAppear {
            // The Free and Core tiers are preselected; the larger tiers are opt-in because they need an external SSD.
            selected = Set(model.updateCheck?.diff.changes.filter { $0.artefact.contentTier <= .core && model.entitlements.denial(for: $0.artefact) == nil }.map(\.id) ?? [])
        }
    }

    func explanation(_ d: Denial) -> String {
        switch d {
        case .tierNotInPlan, .modelNotInPlan: return "\(model.entitlements.label). The Free tier needs no plan. Core adds the Core tier and the default model; Household adds Full text, Complete, the larger models and Wi-Fi sharing."
        default: return "\(d.title). \(d.message)"
        }
    }

    func icon(_ k: ArtefactKind) -> String {
        switch k { case .zim: return "books.vertical"; case .model: return "cpu"; case .videoPack: return "play.rectangle"; case .pagePack: return "doc.text"; case .documentPack: return "doc.richtext"; case .map: return "map"; case .catalogue: return "list.bullet.rectangle" }
    }
    func reason(_ c: ManifestDiff.Change) -> String {
        switch c.reason {
        case .new: return "New \(c.artefact.kind.title.lowercased())"
        case .changed: return "Updated"
        case .replaces: return "Newer edition — the old one is removed after it installs"
        }
    }
}
