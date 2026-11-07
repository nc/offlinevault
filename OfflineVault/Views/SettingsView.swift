import SwiftUI
import UniformTypeIdentifiers
import OfflineVaultCore

/// Preferences proper: General, Models, License, Updates, About. Tools (Backup, Share, Maintenance) are sidebar screens.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    @State private var keyInput = ""

    var body: some View {
        TabView(selection: $model.settingsTab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(AppModel.SettingsTab.general)
            modelsTab.tabItem { Label("AI Model", systemImage: "cpu") }.tag(AppModel.SettingsTab.models)
            license.tabItem { Label("License", systemImage: "key") }.tag(AppModel.SettingsTab.licence)
            updates.tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }.tag(AppModel.SettingsTab.updates)
            about.tabItem { Label("About", systemImage: "info.circle") }.tag(AppModel.SettingsTab.about)
        }
        .padding(20).frame(minWidth: 620, minHeight: 440)
        .navigationTitle("Settings")
        .onAppear { model.refreshLibraryState() }
    }

    var general: some View {
        Form {
            Section("Library") {
                LabeledContent("Location") { Text(model.layout?.root.path ?? "—").lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                if let s = model.storage { LabeledContent("Size") { Text("\(ByteFormat.string(s.totalLibraryBytes)) · \(ByteFormat.string(s.volumeFreeBytes)) free on the drive") } }
                HStack {
                    Button("Show in Finder") { if let u = model.layout?.root { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                    Button("Choose a Different Library…") {
                        if let u = Panels.chooseFolder(prompt: "Use", message: "Choose an existing OfflineVault Library folder, or a folder to create one in.") {
                            let root = AppModel.libraryRoot(forChosenFolder: u)
                            model.resetLibrary(); try? model.openLibrary(at: root); settings.setupCompleted = LibraryLayout.looksLikeLibrary(root); Task { await model.startHelpers() }
                        }
                    }
                }
            }
            Section("World map") {
                LabeledContent("Installed") { Text(model.fullWorldMapInstalled ? "Full street-level detail for the whole world" : (model.mapsService?.maps().contains { ($0.header?.minZoom ?? 1) == 0 } ?? false ? "World overview (countries, cities, main roads)" : "None")) }
                Button(model.fullWorldMapDownloading ? "Downloading… (see Downloads)" : "Download the Full-Detail World Map…") { model.downloadFullWorldMap() }.disabled(model.fullWorldMapDownloading || model.fullWorldMapInstalled || model.layout == nil)
                Text("Street-level maps for the entire planet in one file, about 130 GB. For people who want everything before the internet goes away. Needs an external SSD or a large internal drive; the download is resumable and shows in Downloads. Smaller option: Maps › Download Detail Here for just your area.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Video downloads") {
                Picker("Default quality", selection: $settings.defaultQuality) { ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Ask before downloading more than", selection: $settings.batchConfirmBytes) { ForEach([Int64(500) << 20, 1 << 30, 2 << 30, 5 << 30, 20 << 30], id: \.self) { Text(ByteFormat.string($0)).tag($0) } }
            }
            Section("Storage by kind") {
                if let s = model.storage {
                    ForEach(LibraryLayout.Category.allCases) { c in
                        LabeledContent(c.title) { HStack { ProgressView(value: Double(s.bytesByCategory[c] ?? 0), total: Double(max(s.totalLibraryBytes, 1))).frame(width: 140); Text(ByteFormat.string(s.bytesByCategory[c] ?? 0)).monospacedDigit().frame(width: 80, alignment: .trailing) } }
                    }
                } else { ProgressView().controlSize(.small) }
            }
            Section("Installed content") {
                ForEach(model.installed) { a in
                    HStack {
                        VStack(alignment: .leading) { Text(installedTitle(a)).font(.callout); Meta([a.kind.title, ByteFormat.string(a.sizeBytes), "installed \(a.installedAt.formatted(date: .abbreviated, time: .omitted))"]) }
                        Spacer()
                        Button("Remove…") { removeInstalled(a) }.controlSize(.small)
                    }
                }
                if model.installed.isEmpty { Text("Nothing installed yet.").foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped)
    }

    func installedTitle(_ a: InstalledArtefact) -> String {
        if let b = model.books.first(where: { $0.artefactId == a.id }) { return b.displayTitle }
        if let c = Catalogue.load(from: model.layout?.catalogueURL ?? URL(fileURLWithPath: "/")) , let e = c.entry(forArtefact: a.id) { return e.title }
        return a.fileName.split(separator: "\n").first.map(String.init) ?? a.id
    }
    func removeInstalled(_ a: InstalledArtefact) {
        guard Panels.confirm("Remove “\(installedTitle(a))”?", message: "\(ByteFormat.string(a.sizeBytes)) is deleted from the library. It can be downloaded again from Library updates while your license is current.", button: "Remove") else { return }
        do { try model.updateService?.uninstall(id: a.id); model.refreshLibraryState(); Task { await model.startKiwix() } } catch { model.banner = error.userFacing }
    }

    var modelsTab: some View {
        Form {
            Section("Assistant model") {
                if model.models.isEmpty {
                    Text("No model installed yet. The default (Qwen3 4B, about 2.5 GB) comes with the Core tier of Library updates.").foregroundStyle(.secondary)
                } else {
                    Picker("Active model", selection: Binding(get: { model.selectedModel?.id ?? "" }, set: { id in if let m = model.models.first(where: { $0.id == id }) { model.selectModel(m) } })) {
                        ForEach(model.models) { m in Text("\(ModelNames.friendly(m.displayName)) · \(ByteFormat.string(m.sizeBytes))" + (m.fitsInMemory ? "" : " · needs more memory")).tag(m.id) }
                    }
                    if let m = model.selectedModel { Text(profileSummary(m)).font(.caption).foregroundStyle(.secondary) }
                }
                LabeledContent("Status") { HStack { StatusDot(state: model.llamaState); Text(model.llamaState.label) } }
                HStack { Button("Reload Model") { model.restartHelper(.llamaServer) }; Button("Unload") { model.llama.stop(); model.chat.setClient(nil, modelName: nil) } }
                Toggle("Load the model only when Chat is opened", isOn: $settings.loadModelOnDemand)
                Text("Recommended on 8 GB Macs: the rest of the app starts instantly and the model (about 2.5 GB in memory) loads on first use. It is unloaded automatically under critical memory pressure.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Larger models") {
                let ram = ProcessInfo.processInfo.physicalMemory
                Text("This Mac has \(ByteFormat.string(ram)) of memory. Larger models answer more thoroughly but load slower and reply slower; Qwen3 4B stays the recommended default for quick, cited answers.").foregroundStyle(.secondary)
                modelOffer(id: Config.largeModelArtefactId, name: "Qwen3 8B", need: Config.largeModelMinimumRAMBytes, ram: ram, note: "About 5 GB. Roughly twice the knowledge of the 4B model.")
                modelOffer(id: Config.glimmerModelArtefactId, name: "Muse Glimmer 30B (Meta)", need: Config.glimmerMinimumRAMBytes, ram: ram, note: "About 17 GB, Apache-2.0. Strong reasoning on hard questions; expect 3–5× slower replies than the 4B model. Its speculative-decoding drafter (1.6 GB) is downloaded with it to speed generation.")
            }
        }.formStyle(.grouped)
    }

    func profileSummary(_ m: LocalModel) -> String {
        String(format: "%@ profile · temperature %.1f · context %d tokens", m.profile.displayName, m.profile.temperature, m.profile.contextSize(physicalMemory: ProcessInfo.processInfo.physicalMemory)) + (m.profile.drafter(in: m.fileURL.deletingLastPathComponent()) != nil ? " · speculative decoding on" : "")
    }

    @ViewBuilder func modelOffer(id: String, name: String, need: UInt64, ram: UInt64, note: String) -> some View {
        let installed = model.installed.contains { $0.id == id }
        let change = model.updateCheck?.diff.changes.first { $0.artefact.id == id }
        let drafter = id == Config.glimmerModelArtefactId ? model.updateCheck?.diff.changes.first { $0.artefact.id == Config.glimmerDrafterArtefactId } : nil
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                if ram < need { Text("Needs \(ByteFormat.string(need))").font(.caption).foregroundStyle(.secondary) }
                else if installed { Label("Installed", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
                else if let c = change, let d = model.entitlements.denial(for: c.artefact) { Text(d.title).font(.caption).foregroundStyle(.orange); Button("See Plans") { model.buyLicence() }.controlSize(.small) }
                else if let c = change { Button("Download \(ByteFormat.string(c.artefact.sizeBytes + (drafter?.artefact.sizeBytes ?? 0)))") { model.applyUpdates([c] + (drafter.map { [$0] } ?? [])) }.controlSize(.small) }
                else { Text("Appears in Library updates when published").font(.caption).foregroundStyle(.secondary) }
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    var license: some View {
        Form {
            Section(model.entitlements.label) {
                LabeledContent("Status") { Text(model.licenceStatus.summary) }
                if let l = model.licenceStatus.licence {
                    LabeledContent("Licensed to") { Text(l.subscriber) }
                    LabeledContent("Plan") { Text("\(l.plan.title) · up to \(l.seats) Macs") }
                    LabeledContent("Refreshes until") { Text(l.expiresAt.map { $0.formatted(date: .long, time: .omitted) } ?? "Never") }
                    if l.plan == .founder, let h = l.householdUntil { LabeledContent("Household level until") { Text(h.formatted(date: .long, time: .omitted)) } }
                }
                if let key = model.entitlement?.activationKey { LabeledContent("Key") { Text(key.masked).monospaced() } }
                if let w = ClockSanity.looksWrong(licence: model.licenceStatus.licence) { Label(w, systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.orange) }
            }
            Section("Activate") {
                HStack {
                    TextField("Key", text: $keyInput, prompt: Text("OV-XXXX-XXXX-XXXX-XXXX")).textFieldStyle(.roundedBorder).monospaced().frame(maxWidth: 320)
                    Button("Activate") { Task { await model.activateLicence(key: keyInput); if model.entitlements.plan != nil { keyInput = "" } } }.disabled(keyInput.isEmpty || model.activating || model.layout == nil)
                    if model.activating { ProgressView().controlSize(.small) }
                }
                HStack {
                    Button("Import Licence File…") { if let u = Panels.chooseFile(types: ["json"], prompt: "Import") { model.importLicence(from: u) } }.disabled(model.layout == nil)
                    Button("Buy a Plan…") { model.buyLicence() }
                    if model.licenceStatus != .none { Button("Remove Licence") { if Panels.confirm("Remove the licence from this Mac?", message: "Downloads from OfflineVault stop until a key is activated or a file imported again. Everything already installed keeps working. This Mac stays on the key's roster; use Deactivate This Mac to free its seat.", button: "Remove") { model.removeLicence() } } }
                }
                Text("Paste the key from your receipt page; activation needs internet once and the licence is then checked on this Mac. A licence file works with no internet at all. If your plan lapses, downloads from OfflineVault pause. Nothing you installed ever locks.").font(.caption).foregroundStyle(.secondary)
            }
            if let licence = model.licenceStatus.licence, model.entitlement?.activationKey != nil {
                Section("Macs in use") {
                    if let seats = model.seats {
                        LabeledContent("In use") { Text("\(seats.count) of \(licence.seats)") }
                        ForEach(seats, id: \.deviceId) { seat in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(seat.deviceId == model.settings.deviceId ? "\(seat.deviceName ?? "This Mac") (this Mac)" : (seat.deviceName ?? "Mac")).font(.callout)
                                    Meta(["activated \(seat.activatedAt.formatted(date: .abbreviated, time: .omitted))", "last seen \(seat.lastSeenAt.formatted(.relative(presentation: .named)))"])
                                }
                                Spacer()
                                if seat.deviceId != model.settings.deviceId {
                                    Button("Remove…") { if Panels.confirm("Remove \(seat.deviceName ?? "this Mac") from the licence?", message: "Its seat is freed here for another Mac. That Mac keeps working until its licence expires, and takes a seat again only if someone activates there.", button: "Remove") { Task { await model.deactivate(deviceId: seat.deviceId) } } }.controlSize(.small).disabled(model.activating)
                                }
                            }
                        }
                    } else if model.activating { ProgressView().controlSize(.small) }
                    else { Text("Could not reach OfflineVault to list the Macs on this key. The roster needs internet.").foregroundStyle(.secondary) }
                    HStack {
                        Button("Refresh") { Task { await model.refreshSeats() } }.disabled(model.activating)
                        Button("Deactivate This Mac…") { if Panels.confirm("Deactivate this Mac?", message: "The seat is freed for another Mac and the licence is removed here. Everything already installed keeps working.", button: "Deactivate") { Task { await model.deactivate(deviceId: model.settings.deviceId) } } }.disabled(model.activating)
                    }
                }
            }
        }.formStyle(.grouped)
        .task(id: model.licenceStatus) { if model.seats == nil { await model.refreshSeats() } }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers { p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { Task { @MainActor in model.importLicence(from: u) } } } }
            return true
        }
    }

    var updates: some View {
        Form {
            Section("Library content") {
                Toggle("Check for library updates when OfflineVault opens", isOn: $settings.autoCheckUpdates)
                Button("Check for Library Updates Now") { Task { await model.checkForUpdates(interactive: true) } }
                if let c = model.updateCheck { LabeledContent("Last check") { Text(c.checkedAt.formatted(date: .abbreviated, time: .shortened)) } }
            }
            Section("App") {
                Button("Check for App Updates…") { model.updater.check() }.disabled(!model.updater.canCheck)
                if !model.updater.canCheck { Text("Automatic app updates are not configured in this build.").font(.caption).foregroundStyle(.secondary) }
            }
            // Self-hosting is a developer path for now: release builds talk to OfflineVault's service only.
            #if DEBUG
            Section("Content source") {
                TextField("Server URL", text: $settings.updatesBaseURLOverride, prompt: Text(Config.UPDATES_BASE_URL.absoluteString)).disabled(settings.useFixtureServer)
                    .onChange(of: settings.updatesBaseURLOverride) { _, _ in model.refreshLibraryState() }
                Text("Empty means OfflineVault's own service, which needs a plan. Point this at your own server or a Kiwix mirror that publishes a manifest.json and downloads from there need no plan.").font(.caption).foregroundStyle(.secondary)
                Toggle("Use local fixture server", isOn: $settings.useFixtureServer).onChange(of: settings.useFixtureServer) { _, _ in model.refreshLibraryState() }
                LabeledContent("Effective URL") { Text(Config.updatesBaseURL.absoluteString).font(.caption).textSelection(.enabled) }
            }
            #endif
        }.formStyle(.grouped)
    }

    var about: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("OfflineVault \(Config.appVersion)").font(.title2.bold())
                Text("An offline knowledge hub: reference library, manuals, maps, videos and saved pages, with an assistant that cites your library. Everything works in airplane mode after setup.")
                Group {
                    Text("Content attribution").font(.headline)
                    Text("Wikipedia and other Wikimedia content: CC BY-SA 4.0, by the Wikipedia contributors. Other reference books carry the license shown in the Reference tab. ZIM files are produced by the Kiwix / openZIM projects. Map data © OpenStreetMap contributors (ODbL), builds by Protomaps. US government publications are public domain.")
                    Text("Software").font(.headline)
                    Text("kiwix-serve, libkiwix, libzim — GPL-3.0 (Kiwix). llama.cpp — MIT. yt-dlp — Unlicense. FFmpeg — GPL. MapLibre GL, pmtiles, Protomaps basemaps — BSD. Sparkle — MIT. Qwen3 models — Apache-2.0 (Alibaba Cloud). SQLite — public domain. Noto Sans — SIL OFL.")
                    Text("Videos and web pages").font(.headline)
                    Text("OfflineVault never distributes video or web content. Your Mac fetches what you choose from sources you add, for your own offline use. Respect the terms of the sites you save.")
                    Text("AI answers").font(.headline)
                    Text("Answers come from a local model and the sources in your library. For medical, electrical, structural and other safety-critical topics, follow the cited source text. Anything marked “Unverified” did not come from your library.")
                }.font(.callout)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
