import SwiftUI
import OfflineVaultCore

@main
struct OfflineVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("OfflineVault") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.chat)
                .environmentObject(model.downloads)
                .frame(minWidth: 1040, minHeight: 680)
                .task {
                    await model.bootstrap()
                    #if DEBUG
                    ScreenshotMode.runIfRequested(model: model)
                    #endif
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About OfflineVault") { AboutWindow.show(model: model) }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for App Updates…") { model.updater.check() }.disabled(!model.updater.canCheck)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { model.chat.newConversation(); model.section = .chat }.keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("Import Files…") { model.section = .documents; NotificationCenter.default.post(name: .importFiles, object: nil) }.keyboardShortcut("o", modifiers: .command)
                Button("Import a Folder…") { model.showImportSheet = true }.keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Open Library Folder in Finder") { if let u = model.layout?.root { NSWorkspace.shared.activateFileViewerSelecting([u]) } }.disabled(model.layout == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Find") { NotificationCenter.default.post(name: .focusSearch, object: nil) }.keyboardShortcut("f", modifiers: .command)
                Button("Search Everything…") { model.globalSearch.isPresented = true }.keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(Array(AppModel.Section.knowledge.enumerated()), id: \.element) { i, s in
                    Button(s.title) { model.section = s }.keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
                Button("Downloads") { model.section = .downloads }.keyboardShortcut("8", modifiers: .command)
                Button("Readiness") { model.section = .readiness }.keyboardShortcut("9", modifiers: .command)
                Button("Settings") { model.section = .settings }.keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("Library") {
                Button("Check for Library Updates…") { Task { await model.checkForUpdates(interactive: true) } }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Run Offline Drill") { model.section = .readiness; model.runReadiness() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Back Up Library…") { model.section = .backup }
                Button("Verify Library Files") { model.section = .maintenance }
                Button(model.isSharing ? "Stop Sharing on Wi-Fi" : "Share on Wi-Fi…") { model.section = .share }
            }
            CommandGroup(replacing: .help) {
                Button("OfflineVault Help") { model.section = .readiness }
                Button("Keyboard Shortcuts") { NotificationCenter.default.post(name: .showShortcuts, object: nil) }
                Divider()
                Button("Export Diagnostics…") {
                    if let dir = Panels.chooseFolder(prompt: "Save here") { do { let u = try model.exportDiagnostics(to: dir); NSWorkspace.shared.activateFileViewerSelecting([u]) } catch { model.banner = error.userFacing } }
                }
                Button("Licenses & Credits") { model.section = .settings; model.settingsTab = .about }
            }
        }
        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.downloads)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessSupervisor.shared.reapOrphans()
        ProcessSupervisor.shared.installSignalHandlers()
    }
    func applicationWillTerminate(_ notification: Notification) {
        ProcessSupervisor.shared.terminateAll()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension Notification.Name {
    static let focusSearch = Notification.Name("OfflineVault.focusSearch")
    static let importFiles = Notification.Name("OfflineVault.importFiles")
    static let showShortcuts = Notification.Name("OfflineVault.showShortcuts")
    static let importFolderChosen = Notification.Name("OfflineVault.importFolderChosen")
}

enum AboutWindow {
    private static var window: NSWindow?
    @MainActor static func show(model: AppModel) {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: AboutView().environmentObject(model))
        let w = NSWindow(contentViewController: host)
        w.title = "About OfflineVault"; w.styleMask = [.titled, .closable]; w.isReleasedWhenClosed = false; w.center()
        window = w; w.makeKeyAndOrderFront(nil)
    }
}
