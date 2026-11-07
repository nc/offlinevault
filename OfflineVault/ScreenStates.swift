import SwiftUI
import AVFoundation
import UserNotifications
import CoreImage
import OfflineVaultCore

// Per-screen state lives here, owned by AppModel, so switching sidebar sections never loses an open article,
// a playing video, ticked checklist items or a search.

@MainActor final class LibraryScreen: ObservableObject {
    @Published var query = ""
    @Published var hits: [ReferenceHit] = []
    @Published var searching = false
    @Published var selectedBook: ZimBook?
    @Published var articleURL: URL?
    @Published var articleTitle = ""
    @Published var findText = ""
    @Published var zoom: Double = 1.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    var webCommand: ((ReaderCommand) -> Void)?
    enum ReaderCommand { case back, forward, find(String), zoom(Double), print }
}

@MainActor final class DocumentsScreen: ObservableObject {
    @Published var query = ""
    @Published var hits: [DocumentService.SearchHit] = []
    @Published var selected: LibraryDocument?
    @Published var targetUnit: Int?
    @Published var subjectFilter: Subject?
    @Published var importing = false
    @Published var importStatus: String?
    @Published var importProgress: Double?
}

@MainActor final class PagesScreen: ObservableObject {
    @Published var query = ""
    @Published var hits: [PageService.SearchHit] = []
    @Published var selected: SavedPage?
    @Published var newURL = ""
    @Published var capturing = false
}

@MainActor final class VideosScreen: ObservableObject {
    @Published var query = ""
    @Published var sourceFilter: Int64?
    @Published var selected: Video?
    @Published var startAt: Double?
    let player = PlayerController()
}

@MainActor final class MapsScreen: ObservableObject {
    @Published var selected: OfflineMap?
    @Published var importing = false
    @Published var extracting = false
    @Published var extractStatus: String?
}

@MainActor final class ScenariosScreen: ObservableObject {
    @Published var selected: Scenario?
    @Published var checked: Set<String> = []
    @Published var verifying: String?
    @Published var sources: [String: [RetrievedPassage]] = [:]
    private var db: IndexDatabase?
    static let key = "scenarios.checked"
    func attach(_ database: IndexDatabase?) { db = database; checked = database?.stringSet(forKey: Self.key) ?? [] }
    func toggle(_ key: String, _ on: Bool) { if on { checked.insert(key) } else { checked.remove(key) }; db?.setStringSet(checked, forKey: Self.key) }
    func reset(scenario id: String) { checked = checked.filter { !$0.hasPrefix(id + ":") }; db?.setStringSet(checked, forKey: Self.key) }
}

@MainActor final class SourcesScreen: ObservableObject {
    @Published var selected: VideoSource?
    @Published var query = ""
    @Published var checked: Set<String> = []
    @Published var indexing: Set<Int64> = []
}

@MainActor final class GlobalSearchState: ObservableObject {
    @Published var isPresented = false
    @Published var query = ""
    @Published var results: [RetrievedPassage] = []
    @Published var searching = false
    private var task: Task<Void, Never>?
    func run(_ retrieve: @escaping (String) async -> [RetrievedPassage]) {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; return }
        searching = true
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let r = await retrieve(q)
            guard !Task.isCancelled, let self else { return }
            self.results = r; self.searching = false
        }
    }
}

/// Owns the AVPlayer so SwiftUI view updates never recreate it; survives leaving the Videos section (paused).
@MainActor final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published var cues: [SubtitleCue] = []
    @Published var transcript: [SubtitleCue] = []
    @Published var currentCue = ""
    @Published var currentTime: Double = 0
    @Published private(set) var videoId: String?
    private var observer: Any?
    private var library: VideoLibraryService?
    private var lastSave = Date.distantPast

    func load(video: Video, library: VideoLibraryService?, startAt: Double?, rate: Float) {
        if videoId == video.id, startAt == nil { if player.rate == 0 { player.play(); player.rate = rate }; return }
        unload()
        guard let library, let file = library.fileURL(for: video) else { return }
        self.library = library; videoId = video.id
        player.replaceCurrentItem(with: AVPlayerItem(url: file))
        if let sub = library.subtitleURL(for: video), let content = try? String(contentsOf: sub, encoding: .utf8) { cues = SubtitleParser.parse(content) }
        transcript = (try? library.transcript(for: video.id)) ?? []
        let resume = startAt ?? (try? library.playbackPosition(for: video.id)) ?? 0
        if resume > 1, resume < (video.durationSeconds ?? .infinity) - 3 { player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            let s = t.seconds
            self.currentTime = s
            self.currentCue = self.cues.first { s >= $0.start && s <= $0.end }?.text ?? ""
            if Date().timeIntervalSince(self.lastSave) > 5 { self.savePosition(); self.lastSave = Date() }
        }
        player.play(); player.rate = rate
    }
    func pause() { savePosition(); player.pause() }
    func setRate(_ r: Float) { if player.rate != 0 { player.rate = r } }
    func seek(_ s: Double) { player.seek(to: CMTime(seconds: s, preferredTimescale: 600)); if player.rate == 0 { player.play() } }
    private func savePosition() { guard let id = videoId, let library else { return }; try? library.savePlaybackPosition(player.currentTime().seconds, for: id) }
    func unload() {
        savePosition()
        if let o = observer { player.removeTimeObserver(o); observer = nil }
        player.pause(); player.replaceCurrentItem(with: nil)
        cues = []; transcript = []; currentCue = ""; videoId = nil
    }
}

/// User notifications for long operations finishing while the user is elsewhere, plus the Dock badge.
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    static func post(title: String, body: String, id: String = UUID().uuidString) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
    static func setBadge(_ n: Int) { NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil }
}

enum QRCode {
    static func image(_ string: String, scale: CGFloat = 6) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(string.utf8), forKey: "inputMessage"); f.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = f.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let rep = NSCIImageRep(ciImage: ci); let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
    }
}

/// Friendly model names: "Qwen3-4B-Instruct-2507-Q4_K_M" → "Qwen3 4B".
enum ModelNames {
    static func friendly(_ file: String) -> String {
        var s = file.replacingOccurrences(of: ".gguf", with: "")
        for suffix in ["-KQuant-17GB-Q4_K_M", "-KQuant-Dynamic-Q4_K_XL", "-UD-Q4_K_XL", "-Q4_K_M", "-Q5_K_M", "-Q6_K", "-Q8_0", "-Instruct-2507", "-Instruct", "-instruct", "-q4_k_m", "-q8_0"] { s = s.replacingOccurrences(of: suffix, with: "") }
        return s.replacingOccurrences(of: "-", with: " ")
    }
}
