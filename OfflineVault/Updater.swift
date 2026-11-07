import Foundation
import Sparkle

/// Sparkle-based app updates for direct distribution. Inactive until Info.plist carries SUFeedURL and SUPublicEDKey.
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    let canCheck: Bool
    init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        canCheck = !feed.isEmpty && !key.isEmpty
        controller = SPUStandardUpdaterController(startingUpdater: canCheck, updaterDelegate: nil, userDriverDelegate: nil)
    }
    func check() { guard canCheck else { return }; controller.checkForUpdates(nil) }
}
