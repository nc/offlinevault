import Foundation
import CoreLocation
import OfflineVaultCore

/// Device location for the map. macOS locates by Wi-Fi (no GPS), which needs Apple's positioning service, so the
/// last successful fix is remembered and a user-set "home" point is kept for the day there is no internet.
@MainActor final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Fix: Codable, Equatable { var lat: Double; var lon: Double; var accuracy: Double; var at: Date }
    @Published var current: Fix?
    @Published var home: Fix?
    @Published var status: String?
    @Published var locating = false
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Fix, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        if let d = UserDefaults.standard.data(forKey: "location.last"), let f = try? JSONDecoder().decode(Fix.self, from: d) { current = f }
        if let d = UserDefaults.standard.data(forKey: "location.home"), let f = try? JSONDecoder().decode(Fix.self, from: d) { home = f }
    }

    var best: Fix? { current ?? home }

    func setHome(lat: Double, lon: Double) {
        home = Fix(lat: lat, lon: lon, accuracy: 0, at: Date())
        if let d = try? JSONEncoder().encode(home) { UserDefaults.standard.set(d, forKey: "location.home") }
    }

    /// One fresh fix. Throws a user-facing error when location services are off or offline positioning fails.
    func locate() async throws -> Fix {
        if locating { throw UserFacingError("Already locating", message: "Hold on a moment.") }
        guard CLLocationManager.locationServicesEnabled() else {
            throw UserFacingError("Location Services are off", message: "Turn on Location Services in System Settings › Privacy & Security to center the map on this Mac.", recovery: current.map { "Using the last known position from \($0.at.formatted(.relative(presentation: .named)))." } ?? "Or type coordinates, or set a Home point from the marker.")
        }
        locating = true; status = "Locating…"
        defer { locating = false }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            manager.requestLocation()
            Task { try? await Task.sleep(nanoseconds: 20_000_000_000); self.fail(UserFacingError("Could not determine location", message: "No position came back within 20 seconds. On a Mac, location needs Wi-Fi and Apple's positioning service.", recovery: self.current.map { "Showing the last known position from \($0.at.formatted(.relative(presentation: .named)))." } ?? "Type coordinates or set a Home point from the marker instead.")) }
        }
    }

    private func fail(_ e: Error) { status = nil; continuation?.resume(throwing: e); continuation = nil }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let fix = Fix(lat: l.coordinate.latitude, lon: l.coordinate.longitude, accuracy: l.horizontalAccuracy, at: l.timestamp)
        Task { @MainActor in
            self.current = fix; self.status = nil
            if let d = try? JSONEncoder().encode(fix) { UserDefaults.standard.set(d, forKey: "location.last") }
            self.continuation?.resume(returning: fix); self.continuation = nil
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let ns = error as NSError
            let msg: String = ns.domain == kCLErrorDomain && ns.code == CLError.denied.rawValue ? "OfflineVault is not allowed to use your location. Allow it in System Settings › Privacy & Security › Location Services." : "Location is unavailable right now (\(error.localizedDescription))."
            self.fail(UserFacingError("Could not determine location", message: msg, recovery: self.current.map { "Showing the last known position from \($0.at.formatted(.relative(presentation: .named)))." } ?? "Type coordinates or set a Home point from the marker instead."))
        }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorized || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
    }
}
