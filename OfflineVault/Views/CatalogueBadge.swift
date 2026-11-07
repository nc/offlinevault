import SwiftUI
import OfflineVaultCore

/// The one rendering of catalogue trust, so the updates sheet and the Library footer cannot drift.
struct CatalogueBadge: View {
    let trust: CatalogueTrust
    let release: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(trust.title).font(.caption.weight(.semibold))
                Text(trust.detail(release: release)).font(.caption2).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: trust.symbolName).foregroundStyle(trust.isVerified ? Color.green : Color.orange)
        }
        .accessibilityElement(children: .combine)
        .help(trust.isVerified
              ? "The catalogue's signature was checked against OfflineVault's content key, so this list is what OfflineVault published."
              : "This catalogue is not signed by OfflineVault. Content you host yourself is never gated, and the app cannot vouch for it.")
    }
}

/// The one rendering of "this book comes from Kiwix, not from the verified catalogue". Sits next to a title in the
/// updates sheet and the Library list; the catalogue badge above them stays whatever the manifest earned.
struct ExternalTag: View {
    var source: ExternalSource? = nil

    var body: some View {
        Label(ExternalSource.tag, systemImage: "arrow.down.circle")
            .font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .help(source?.explanation ?? ExternalSource.help)
            .accessibilityLabel("\(ExternalSource.tag), not verified by OfflineVault")
    }
}
