import SwiftUI
import OfflineVaultCore

/// The offline drill: one button, a clear pass/warn/fail report, and a fix for every red or amber line.
struct ReadinessView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let r = model.readinessReport {
                    summary(r)
                    VStack(spacing: 0) {
                        ForEach(r.items) { item in
                            row(item)
                            if item.id != r.items.last?.id { Divider() }
                        }
                    }
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                } else if !model.readinessRunning {
                    intro
                }
                if model.readinessRunning { HStack { ProgressView().controlSize(.small); Text("Running checks… the AI step can take a few seconds.").foregroundStyle(.secondary) } }
                footer
            }.padding(20).frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("Readiness")
        .navigationSubtitle(model.readinessReport.map { r in "Last drill \(r.finishedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")" } ?? "Not run yet")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.runReadiness() } label: { Label(model.readinessReport == nil ? "Run Drill" : "Run Again", systemImage: "play.fill") }.disabled(model.readinessRunning || model.layout == nil).help("Run the offline drill (⇧⌘R)")
                Button { if let r = model.readinessReport { exportReport(r) } } label: { Label("Save Report", systemImage: "square.and.arrow.up") }.disabled(model.readinessReport == nil)
            }
        }
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Offline drill").font(.title.bold())
                Text("Proves the library works with no internet: every helper, every book, the AI model, your files, maps and backup. Run it with Wi-Fi off before you need it.").foregroundStyle(.secondary)
            }
            Spacer()
            if model.readinessReport == nil { Button { model.runReadiness() } label: { Label("Run Drill", systemImage: "play.fill") }.buttonStyle(.borderedProminent).disabled(model.readinessRunning || model.layout == nil) }
        }
    }

    var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Turn Wi-Fi off first for a real test.", systemImage: "wifi.slash")
            Label("Takes 10–30 seconds. Nothing is changed; the drill only reads.", systemImage: "clock")
            Label("Every amber or red line comes with a fix button.", systemImage: "wrench.and.screwdriver")
            if model.rosettaMissing { Label("Rosetta 2 is not installed — kiwix-serve cannot run until it is. Install it while you still have internet.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
        }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    func summary(_ r: ReadinessReport) -> some View {
        let c = r.counts
        return HStack(spacing: 14) {
            Image(systemName: r.overall == .pass ? "checkmark.seal.fill" : r.overall == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .font(.system(size: 34)).foregroundStyle(r.overall == .pass ? .green : r.overall == .warn ? .orange : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.overall == .pass ? "Ready for an outage" : r.overall == .warn ? "Works offline, with gaps" : "Would fail offline").font(.title2.weight(.semibold))
                Text("\(c.pass) passed · \(c.warn) warnings · \(c.fail) failed" + (r.finishedAt.map { " · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "") + (r.networkWasReachable == true ? " · internet was ON during this run" : " · run offline")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    func row(_ item: ReadinessReport.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.status == .pass ? "checkmark.circle.fill" : item.status == .warn ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                .foregroundStyle(item.status == .pass ? .green : item.status == .warn ? .orange : .red).font(.title3).frame(width: 24).accessibilityLabel(item.status.rawValue)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                Text(item.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if let fix = item.fix, item.status != .pass { Button(fixTitle(fix)) { model.performFix(fix) }.controlSize(.small) }
            if item.duration > 0.5 { Text(String(format: "%.1fs", item.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
        }.padding(12)
    }

    func fixTitle(_ fix: String) -> String {
        switch fix {
        case "install-rosetta": return "Install Rosetta…"
        case "backup": return "Back Up Now"
        case "licence": return "Import License"
        case "maps": return "Get Maps"
        case "updates": return "Check for Updates"
        case "rebuild-index": return "Rebuild Index"
        case "restart-kiwix": return "Restart Books"
        case "restart-llm": return "Load Model"
        case "verify": return "Verify Files"
        case "reinstall": return "What to Do"
        default: return "Fix"
        }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suggested cadence").font(.headline)
            Text("Run the drill after every library update, after plugging in a drive that has been in storage, and once a season. Keep a paper copy of the Scenario cards and the pages you would need in the first day; batteries fail.").font(.callout).foregroundStyle(.secondary)
        }
    }

    func exportReport(_ r: ReadinessReport) {
        let p = NSSavePanel(); p.nameFieldStringValue = "OfflineVault readiness \(Date().formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-")).txt"
        guard p.runModal() == .OK, let url = p.url else { return }
        var t = "OfflineVault readiness report — \(r.finishedAt?.formatted(date: .long, time: .shortened) ?? "")\nOverall: \(r.overall.rawValue.uppercased())\n\n"
        for i in r.items { t += "[\(i.status.rawValue.uppercased())] \(i.title)\n    \(i.detail)\n" }
        try? t.write(to: url, atomically: true, encoding: .utf8)
    }
}
