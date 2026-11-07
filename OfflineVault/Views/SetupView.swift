import SwiftUI
import UniformTypeIdentifiers
import OfflineVaultCore

/// First-run: choose the library folder, activate or skip a plan, download the starter library.
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var downloads: DownloadManager
    @State private var checking = false
    @State private var error: UserFacingError?
    @State private var chosenTiers: Set<ContentTier> = [.free, .core]
    @State private var keyInput = AppSettings.shared.pendingActivationKey ?? ""

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "shippingbox.and.arrow.backward.fill").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Welcome to OfflineVault").font(.largeTitle.bold())
            Text("A library of reference books, manuals, maps and videos on your Mac, and an assistant that answers from it with citations. Everything works with the internet down.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 520)
            if let e = error { ErrorBanner(error: e) { error = nil }.frame(maxWidth: 560) }
            ForEach(model.banners, id: \.self) { b in ErrorBanner(error: b) { model.dismiss(b) }.frame(maxWidth: 560) }
            if !model.helperWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.helperWarnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption) }
                }.frame(maxWidth: 560)
            }
            if model.rosettaMissing {
                HStack { Label("Rosetta 2 is needed for the reference books and can only be installed with internet.", systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange); Button(model.installingRosetta ? "Installing…" : "Install Rosetta 2…") { model.installRosetta() }.disabled(model.installingRosetta) }.frame(maxWidth: 560)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    stepRow(1, "Where to keep the library", done: model.layout != nil) {
                        HStack {
                            Text(model.layout?.root.path ?? "A folder on this Mac or an external SSD. Start small; the full library can grow to 100+ GB.").font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                            Spacer()
                            if model.layout == nil { Button("Use \(AppSettings.defaultLibraryURL.lastPathComponent)") { useDefault() }.buttonStyle(.borderedProminent) }
                            Button(model.layout == nil ? "Choose…" : "Change…") { chooseFolder() }
                        }
                    }
                    Divider()
                    stepRow(2, "Your plan", done: model.entitlements.plan != nil) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.entitlements.plan != nil ? model.licenceStatus.summary : "Paste the key from your receipt page, or import a licence file. Both can wait; this step is optional.").font(.callout).foregroundStyle(.secondary)
                            HStack {
                                TextField("Key", text: $keyInput, prompt: Text("OV-XXXX-XXXX-XXXX-XXXX")).labelsHidden().textFieldStyle(.roundedBorder).monospaced().frame(maxWidth: 250)
                                Button("Activate") { Task { await model.activateLicence(key: keyInput); if model.entitlements.plan != nil { keyInput = "" } } }.buttonStyle(.borderedProminent).disabled(model.layout == nil || keyInput.isEmpty || model.activating)
                                if model.activating { ProgressView().controlSize(.small) }
                                Button("Import File…") { if let u = Panels.chooseFile(types: ["json"], prompt: "Import") { model.importLicence(from: u) } }.disabled(model.layout == nil)
                                Button("Buy a Plan…") { model.buyLicence() }
                            }
                            Text("Continue without a plan: the free tier (the Field Guide, the CDC and FEMA packs, the overview map) downloads, and everything you add yourself (PDFs, videos, saved pages, maps) works. Core and Household add the rest. Pointing the app at your own content server is a developer feature for now.").font(.caption).foregroundStyle(.secondary)
                        }
                        .onReceive(model.settings.$pendingActivationKey) { if let k = $0, !k.isEmpty { keyInput = k } }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            for p in providers { p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { Task { @MainActor in model.importLicence(from: u) } } } }
                            return true
                        }
                    }
                    Divider()
                    stepRow(3, "Download the starter library", done: baseInstalled) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let check = model.updateCheck {
                                if check.diff.isEmpty {
                                    Text("Everything in the base pack is already installed.").font(.callout)
                                } else {
                                    ForEach(ContentTier.allCases, id: \.self) { tier in
                                        let items = check.diff.changes.filter { $0.artefact.contentTier == tier }
                                        let allowed = items.filter { model.entitlements.denial(for: $0.artefact) == nil }
                                        if !items.isEmpty {
                                            Toggle(isOn: Binding(get: { chosenTiers.contains(tier) }, set: { on in if on { chosenTiers.insert(tier) } else { chosenTiers.remove(tier) } })) {
                                                VStack(alignment: .leading, spacing: 1) {
                                                    HStack { Text(tier.title).font(.callout.weight(.semibold)); Text("· \(items.count) items · \(ByteFormat.string(items.reduce(0) { $0 + $1.artefact.sizeBytes }))").font(.callout).foregroundStyle(.secondary) }
                                                    Text(tier.summary).font(.caption).foregroundStyle(.secondary)
                                                    Text(items.map(\.artefact.displayTitle).joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                                                    if let d = items.compactMap({ model.entitlements.denial(for: $0.artefact) }).first {
                                                        Text(allowed.isEmpty ? d.title : "\(items.count - allowed.count) of \(items.count) items: \(d.title.lowercased())").font(.caption).foregroundStyle(.orange)
                                                    }
                                                }
                                            }.toggleStyle(.checkbox).disabled(allowed.isEmpty || (tier <= .core && items.allSatisfy { Set(model.installed.map(\.id)).contains($0.artefact.id) }))
                                        }
                                    }
                                    if !spaceOK(selectedBytes) { Label("Not enough free space for this selection (\(ByteFormat.string(model.storage?.volumeFreeBytes ?? 0)) free). Choose fewer tiers or a library folder on a larger drive.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                                }
                            } else {
                                Text("Checks what is available. The Free tier needs no plan. The Core tier (medical and survival references, manuals, a map) fits an internal drive; bigger tiers are optional.").font(.callout).foregroundStyle(.secondary)
                            }
                            if !downloads.items.isEmpty {
                                ForEach(downloads.items) { item in
                                    HStack { ProgressView(value: item.fraction).frame(width: 160); Text(item.title).lineLimit(1); Spacer(); Text(item.statusText).font(.caption).foregroundStyle(.secondary) }.font(.caption)
                                }
                            }
                            HStack {
                                Button(model.updateCheck == nil ? "See What's Available" : "Check Again") { Task { await check() } }.disabled(model.layout == nil || checking)
                                if let check = model.updateCheck, !check.diff.isEmpty {
                                    Button("Download \(ByteFormat.string(selectedBytes))") { model.applyUpdates(selectedChanges) }
                                        .buttonStyle(.borderedProminent).disabled(selectedChanges.isEmpty || !spaceOK(selectedBytes) || downloads.activeCount > 0)
                                }
                                if checking { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                }.padding(8)
            }.frame(maxWidth: 620)
            HStack {
                if model.layout != nil && !baseInstalled { Text(downloads.activeCount > 0 ? "Downloads continue in the background — you can start using the app." : "You can also finish now and download later from Library updates.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(baseInstalled ? "Finish" : "Start Using OfflineVault") { finish() }.buttonStyle(.borderedProminent).disabled(model.layout == nil)
            }.frame(maxWidth: 620)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var selectedChanges: [ManifestDiff.Change] { model.updateCheck?.diff.changes.filter { chosenTiers.contains($0.artefact.contentTier) && model.entitlements.denial(for: $0.artefact) == nil } ?? [] }
    var selectedBytes: Int64 { selectedChanges.reduce(0) { $0 + $1.artefact.sizeBytes } }

    /// The base pack (the Free and Core tiers, as far as the plan allows) is installed.
    var baseInstalled: Bool {
        guard let check = model.updateCheck else { return false }
        let installedIds = Set(model.installed.map(\.id))
        let base = check.diff.changes.filter { $0.artefact.contentTier <= .core && model.entitlements.denial(for: $0.artefact) == nil }
        return !base.isEmpty && base.allSatisfy { installedIds.contains($0.artefact.id) }
    }

    func spaceOK(_ bytes: Int64) -> Bool { model.layout?.hasSpace(forAdditionalBytes: bytes) ?? false }

    @ViewBuilder func stepRow<Content: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle").font(.title2).foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); content() }
        }
    }

    func useDefault() {
        do {
            try model.openLibrary(at: AppSettings.defaultLibraryURL)
            model.refreshLibraryState()
            Task { await model.startHelpers(); await check() }
        } catch { self.error = error.userFacing }
    }

    func chooseFolder() {
        guard let picked = Panels.chooseFolder(prompt: "Use", message: "Choose where to keep the library. A folder named “OfflineVault Library” is created inside it unless you pick an existing library.") else { return }
        let url = AppModel.libraryRoot(forChosenFolder: picked)
        do {
            try model.openLibrary(at: url)
            model.refreshLibraryState()
            Task { await model.startHelpers(); await check() }
        } catch { self.error = error.userFacing }
    }

    func check() async {
        checking = true; defer { checking = false }
        await model.checkForUpdates(interactive: false)
        model.showUpdateSheet = false
        if model.updateCheck == nil {
            #if DEBUG
            let hint = Config.usesFixtureServer ? "Start the fixture server: scripts/make_fixture_server.sh --serve" : "Check your connection, or continue and download later."
            #else
            let hint = "Check your internet connection, or start using the app and download later from Library › Check for Library Updates."
            #endif
            error = UserFacingError("Could not reach the update service", message: "The content catalogue could not be fetched right now.", recovery: hint)
        }
        model.refreshLibraryState()
    }

    func finish() {
        model.settings.setupCompleted = true
        model.refreshLibraryState()
        Task { await model.startHelpers() }
        model.objectWillChange.send()
    }
}
