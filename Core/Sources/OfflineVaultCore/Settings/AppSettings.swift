import Foundation

/// User preferences stored in UserDefaults (library location, quality, thresholds, model choice).
public final class AppSettings: ObservableObject, @unchecked Sendable {
    public static let shared = AppSettings()
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        libraryPath = defaults.string(forKey: Keys.libraryPath)
        defaultQuality = VideoQuality(rawValue: defaults.string(forKey: Keys.defaultQuality) ?? "") ?? .p480
        batchConfirmBytes = defaults.object(forKey: Keys.batchConfirmBytes) as? Int64 ?? 2 * 1024 * 1024 * 1024
        selectedModelFile = defaults.string(forKey: Keys.selectedModelFile)
        updatesBaseURLOverride = defaults.string(forKey: "updatesBaseURL") ?? ""
        useFixtureServer = defaults.bool(forKey: "useFixtureServer")
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        setupCompleted = defaults.bool(forKey: Keys.setupCompleted)
        playbackSpeed = defaults.object(forKey: Keys.playbackSpeed) as? Double ?? 1.0
        chatSearchesLibrary = defaults.object(forKey: Keys.chatSearchesLibrary) as? Bool ?? true
        // Default on for 8 GB Macs: the model loads when Chat is first opened instead of at launch.
        loadModelOnDemand = defaults.object(forKey: Keys.loadModelOnDemand) as? Bool ?? (ProcessInfo.processInfo.physicalMemory <= 8 * 1024 * 1024 * 1024)
        pendingActivationKey = defaults.string(forKey: Keys.pendingActivationKey)
        if let id = defaults.string(forKey: Keys.deviceId), !id.isEmpty { deviceId = id }
        else { deviceId = UUID().uuidString; defaults.set(deviceId, forKey: Keys.deviceId) }
    }

    enum Keys {
        static let libraryPath = "libraryPath"
        static let defaultQuality = "defaultQuality"
        static let batchConfirmBytes = "batchConfirmBytes"
        static let selectedModelFile = "selectedModelFile"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let setupCompleted = "setupCompleted"
        static let playbackSpeed = "playbackSpeed"
        static let chatSearchesLibrary = "chatSearchesLibrary"
        static let loadModelOnDemand = "loadModelOnDemand"
        static let pendingActivationKey = "pendingActivationKey"
        static let deviceId = "deviceId"
        static let lastVerifiedPublishedAt = "lastVerifiedPublishedAt"
    }

    @Published public var libraryPath: String? { didSet { defaults.set(libraryPath, forKey: Keys.libraryPath) } }
    @Published public var defaultQuality: VideoQuality { didSet { defaults.set(defaultQuality.rawValue, forKey: Keys.defaultQuality) } }
    /// Batches larger than this ask for confirmation before downloading.
    @Published public var batchConfirmBytes: Int64 { didSet { defaults.set(batchConfirmBytes, forKey: Keys.batchConfirmBytes) } }
    @Published public var selectedModelFile: String? { didSet { defaults.set(selectedModelFile, forKey: Keys.selectedModelFile) } }
    @Published public var updatesBaseURLOverride: String { didSet { defaults.set(updatesBaseURLOverride.isEmpty ? nil : updatesBaseURLOverride, forKey: "updatesBaseURL") } }
    @Published public var useFixtureServer: Bool { didSet { defaults.set(useFixtureServer, forKey: "useFixtureServer") } }
    @Published public var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) } }
    @Published public var setupCompleted: Bool { didSet { defaults.set(setupCompleted, forKey: Keys.setupCompleted) } }
    @Published public var playbackSpeed: Double { didSet { defaults.set(playbackSpeed, forKey: Keys.playbackSpeed) } }
    /// On by default: answers are grounded in the library and cited. Off = plain conversation with the model.
    @Published public var chatSearchesLibrary: Bool { didSet { defaults.set(chatSearchesLibrary, forKey: Keys.chatSearchesLibrary) } }
    @Published public var loadModelOnDemand: Bool { didSet { defaults.set(loadModelOnDemand, forKey: Keys.loadModelOnDemand) } }
    /// A key received from `offlinevault://activate` before any library existed; Setup prefills and clears it.
    @Published public var pendingActivationKey: String? { didSet { defaults.set(pendingActivationKey, forKey: Keys.pendingActivationKey) } }
    /// Stable per-Mac id for seat counting: a random UUID minted once, never a hardware serial.
    public let deviceId: String
    /// `publishedAt` of the newest verified catalogue this Mac has accepted; the replay guard rejects anything older.
    /// Not published: `UpdateService` writes it off the main thread and no view observes it.
    public var lastVerifiedPublishedAt: Date? {
        get { defaults.object(forKey: Keys.lastVerifiedPublishedAt) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastVerifiedPublishedAt) }
    }

    public var libraryLayout: LibraryLayout? { libraryPath.map { LibraryLayout(root: URL(fileURLWithPath: $0, isDirectory: true)) } }

    /// Default location offered at first run.
    public static var defaultLibraryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OfflineVault Library", isDirectory: true)
    }
}
