import SwiftUI
import OfflineVaultCore

/// Settings-style screens that are really tools, so they live in the sidebar's Manage group.

struct BackupView: View {
    @EnvironmentObject var model: AppModel
    @State private var report = BackupService.Report()
    @State private var running = false
    @State private var verifyResult: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Text("Two is one, one is none. Clone the whole library to another drive — an external SSD, a second Mac, a drive in a Faraday bag. Files already identical on the destination are skipped; everything copied is checksum-verified. Power up and re-verify flash drives every few months.").foregroundStyle(.secondary)
                LabeledContent("Last verified backup") { Text(model.backupService?.lastBackupDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never") }
                if let p = model.backupService?.lastBackupPath { LabeledContent("Location") { Text(p).lineLimit(1).truncationMode(.middle) } }
                HStack {
                    Button(running ? "Backing Up…" : "Back Up Library To…") { run() }.disabled(running || model.backupService == nil).buttonStyle(.borderedProminent)
                    Button("Verify an Existing Backup…") { verify() }.disabled(running || model.backupService == nil)
                    if running { Button("Cancel") { task?.cancel() } }
                }
                if running || report.finished {
                    VStack(alignment: .leading, spacing: 4) {
                        if !report.current.isEmpty { Text(report.current).font(.caption).lineLimit(1).truncationMode(.middle) }
                        Text("\(report.filesCopied) copied (\(ByteFormat.string(report.bytesCopied))) · \(report.filesSkipped) already up to date · \(report.filesVerified) verified").font(.caption).monospacedDigit()
                        if !report.mismatches.isEmpty { Label("\(report.mismatches.count) file(s) failed verification: \(report.mismatches.prefix(3).joined(separator: ", "))", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                        if let e = report.error { Label(e, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.orange) }
                        if report.finished && report.error == nil && report.mismatches.isEmpty { Label("Backup complete and verified.", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green) }
                    }
                }
                if let v = verifyResult { Text(v).font(.caption) }
            } header: { Text("Second copy of the library") }
            Section("Paper") {
                Text("Articles, saved pages, documents, scenario cards and chat answers all print (⌘P) or save as PDF. Keep a binder of the pages that matter most; batteries fail.").foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .navigationTitle("Backup")
    }

    func run() {
        guard let svc = model.backupService, let dest = Panels.chooseFolder(prompt: "Back Up Here", message: "Choose a folder on another drive. A folder named “OfflineVault Library” is created inside it.") else { return }
        running = true; report = BackupService.Report(); verifyResult = nil
        task = Task.detached(priority: .utility) {
            let r = await svc.clone(to: dest.appendingPathComponent("OfflineVault Library", isDirectory: true)) { p in Task { @MainActor in report = p } }
            await MainActor.run { report = r; running = false; model.libraryGeneration += 1; if r.error == nil && !NSApp.isActive { Notifier.post(title: "Backup finished", body: r.mismatches.isEmpty ? "Verified \(r.filesVerified) files." : "\(r.mismatches.count) files failed verification.") } }
        }
    }
    func verify() {
        guard let svc = model.backupService else { return }
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Verify"; p.message = "Choose the backup's “OfflineVault Library” folder."
        p.directoryURL = svc.lastBackupPath.map { URL(fileURLWithPath: $0) }
        guard p.runModal() == .OK, let dest = p.url else { return }
        running = true; verifyResult = "Verifying…"
        Task.detached(priority: .utility) {
            let (checked, bad) = svc.verify(dest, sampleLimit: 500)
            await MainActor.run { running = false; verifyResult = bad.isEmpty ? "Verified \(checked) files — all match the library." : "\(bad.count) of \(checked) files differ or are missing: \(bad.prefix(5).joined(separator: ", "))" }
        }
    }
}

struct ShareView: View {
    @EnvironmentObject var model: AppModel
    var addresses: [String] { LocalShareServer.localAddresses() }
    var bonjour: String { (Host.current().localizedName ?? "this-mac").lowercased().replacingOccurrences(of: " ", with: "-") + ".local" }
    var body: some View {
        Form {
            Section {
                Toggle("Share the library on the local network", isOn: Binding(get: { model.isSharing }, set: { model.setSharing($0) }))
                if !model.isSharing, let d = model.entitlements.sharingDenial {
                    HStack { Label(d.title, systemImage: "key").font(.caption).foregroundStyle(.orange); Button("See Plans") { model.buyLicence() }.controlSize(.mini) }
                }
                Text("Read-only. Phones, tablets and laptops on the same Wi-Fi open a simple page listing books, manuals, saved pages and videos, with search. Nothing is sent to the internet. Turn it off when you leave the network.").foregroundStyle(.secondary)
                if model.isSharing {
                    let port = model.shareServer?.port ?? 8780
                    let url = "http://\(bonjour):\(port)/"
                    HStack(alignment: .top, spacing: 18) {
                        if let qr = QRCode.image(addresses.first.map { "http://\($0):\(port)/" } ?? url, scale: 5) { Image(nsImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150).accessibilityLabel("QR code for the library address") }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scan with a phone camera, or open:").font(.callout)
                            Text(url).font(.body.monospaced()).textSelection(.enabled)
                            ForEach(addresses, id: \.self) { ip in Text("http://\(ip):\(port)/").font(.callout.monospaced()).textSelection(.enabled) }
                            Text("Reference books open on port \(Config.kiwixPort) of the same address.").font(.caption).foregroundStyle(.secondary)
                            if addresses.isEmpty { Label("No Wi-Fi or Ethernet address found. Join a network, or create one from this Mac via System Settings › General › Sharing › Internet Sharing.", systemImage: "wifi.slash").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
            } header: { Text("Share on Wi-Fi") }
            Section("Off-grid tip") {
                Text("With no router, turn on Internet Sharing on this Mac to create a local network; devices join it and open the address above. A Mac mini on a small battery can serve a whole household for days.").foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .navigationTitle("Share on Wi-Fi")
    }
}

struct MaintenanceView: View {
    @EnvironmentObject var model: AppModel
    @State private var verifyReport = LibraryMaintenance.VerifyReport()
    @State private var verifying = false
    @State private var rebuildStatus: String?
    @State private var rebuilding = false
    @State private var integrity: [String]?

    var body: some View {
        Form {
            Section("Verify library files") {
                Text("Re-reads every installed book, model and map and compares it with the checksum recorded when it was downloaded. Catches damaged or truncated files on drives that sat in storage. Large libraries take minutes.").foregroundStyle(.secondary)
                HStack { Button(verifying ? "Verifying…" : "Verify All Files") { runVerify() }.disabled(verifying || model.maintenance == nil); if verifying { ProgressView(value: verifyReport.fraction).frame(width: 220); Text(verifyReport.current).font(.caption).lineLimit(1).truncationMode(.middle) } }
                if verifyReport.finished {
                    if verifyReport.failures.isEmpty { Label("All \(verifyReport.items.count) items match.", systemImage: "checkmark.seal").foregroundStyle(.green) }
                    else { ForEach(verifyReport.failures) { f in Label("\(f.title): \(f.detail)", systemImage: "xmark.octagon").foregroundStyle(.orange).font(.callout) }; Text("Download damaged items again from Library updates, or restore them from your backup.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Search index") {
                Text("Rebuilds what search and the assistant read from the files on disk. Use it after a power loss, when search returns nothing, or when the drill flags the index. Conversations, settings and playback positions are kept.").foregroundStyle(.secondary)
                HStack { Button(rebuilding ? "Rebuilding…" : "Rebuild Index") { runRebuild() }.disabled(rebuilding || model.maintenance == nil); if let r = rebuildStatus { Text(r).font(.caption).foregroundStyle(.secondary) } }
                LabeledContent("Index health") { if let i = integrity { i.isEmpty ? Text("Healthy").foregroundStyle(.green) : Text(i.first ?? "").foregroundStyle(.orange) } else { ProgressView().controlSize(.small) } }
            }
            Section("Rosetta 2") {
                if RosettaStatus.neededByHelpers {
                    LabeledContent("Status") { model.rosettaMissing ? Text("Not installed — reference books cannot open").foregroundStyle(.red) : Text("Installed").foregroundStyle(.green) }
                    Text("The reference-book engine is an Intel program; Apple Silicon Macs run it through Rosetta 2, which macOS can only download from the internet. Install it now so it is there in an outage.").foregroundStyle(.secondary)
                    if model.rosettaMissing { Button(model.installingRosetta ? "Installing…" : "Install Rosetta 2…") { model.installRosetta() }.disabled(model.installingRosetta) }
                } else { Text("Not needed on this Mac.").foregroundStyle(.secondary) }
            }
            Section("Helpers") {
                helperRow("Reference books", state: model.kiwixState, binary: .kiwixServe, output: model.kiwix.recentOutput)
                helperRow("AI model", state: model.llamaState, binary: .llamaServer, output: model.llama.recentOutput)
                LabeledContent("Memory") { Text(ByteFormat.string(MemoryPressureMonitor.physicalMemoryBytes) + " · pressure \(model.memoryLevel.rawValue)") }
                if !model.helperWarnings.isEmpty { ForEach(model.helperWarnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) } }
            }
            Section("Support") {
                Button("Export Diagnostics…") { if let dir = Panels.chooseFolder(prompt: "Save Here") { do { let u = try model.exportDiagnostics(to: dir); NSWorkspace.shared.activateFileViewerSelecting([u]) } catch { model.banner = error.userFacing } } }
                Text("A plain-text file with versions, helper logs, the last drill and index state. No personal content.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .navigationTitle("Maintenance")
        .task { let m = model.maintenance; integrity = await Task.detached { m?.quickCheck() ?? [] }.value }
    }

    @ViewBuilder func helperRow(_ name: String, state: ManagedProcess.State, binary: HelperBinary, output: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { StatusDot(state: state); Text(name).font(.headline); Text(state.label).foregroundStyle(.secondary); Spacer(); Button("Restart") { model.restartHelper(binary) }.controlSize(.small) }
            if !output.isEmpty { DisclosureGroup("Recent log") { ScrollView { Text(output).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 120) }.font(.caption) }
        }
    }
    func runVerify() {
        guard let m = model.maintenance else { return }
        verifying = true; verifyReport = LibraryMaintenance.VerifyReport()
        Task.detached(priority: .utility) { let r = m.verifyInstalledArtefacts { p in Task { @MainActor in verifyReport = p } }; await MainActor.run { verifyReport = r; verifying = false } }
    }
    func runRebuild() {
        guard let m = model.maintenance else { return }
        rebuilding = true; rebuildStatus = "Starting…"
        Task.detached(priority: .utility) {
            let r = m.rebuildIndex { s in Task { @MainActor in if !s.isEmpty { rebuildStatus = s } } }
            await MainActor.run { rebuilding = false; rebuildStatus = r.problems.isEmpty ? "Rebuilt: \(r.books) books, \(r.documents) documents, \(r.pages) pages, \(r.videos) videos." : "Problems: " + r.problems.joined(separator: "; "); integrity = m.quickCheck(); model.refreshLibraryState(); Task { await model.startKiwix() } }
        }
    }
}
