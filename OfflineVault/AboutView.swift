import SwiftUI
import OfflineVaultCore

struct AboutView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text("OfflineVault").font(.title.bold())
                Text("Version \(Config.appVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))").foregroundStyle(.secondary)
                Text(model.licenceStatus.summary).font(.callout)
                Text("Your library never locks. If refreshes lapse, new editions stop and everything already downloaded keeps working.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Check for App Updates…") { model.updater.check() }.disabled(!model.updater.canCheck)
                    Button("Licenses & Credits") { model.section = .settings; model.settingsTab = .about; NSApp.keyWindow?.close() }
                }.padding(.top, 4)
                Text("© 2026 OfflineVault. Wikipedia content CC BY-SA 4.0. Map data © OpenStreetMap contributors.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(24).frame(width: 520)
    }
}
