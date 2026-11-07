import SwiftUI
import WebKit
import UniformTypeIdentifiers
import OfflineVaultCore

struct MapsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { MapsBody(st: model.mapsScreen) }
}

struct MapsBody: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var st: MapsScreen
    @StateObject private var bridge = MapBridge()
    @State private var maps: [OfflineMap] = []
    @State private var showExtract = false
    @State private var extractPreset: RegionExtractSheet.Preset?
    @State private var gotoText = ""

    var mapsKey: String { maps.map { $0.name + ":" + String($0.sizeBytes) }.joined(separator: "|") }
    var hasWorld: Bool { maps.contains { isWorld($0) } }
    func isWorld(_ m: OfflineMap) -> Bool { (m.header?.minZoom ?? 1) == 0 && ((m.header?.maxLon ?? 0) - (m.header?.minLon ?? 0)) > 300 }
    var regions: [OfflineMap] { maps.filter { !isWorld($0) } }

    var body: some View {
        detail
        .navigationTitle("Maps")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { locateMe() } label: { Label("Locate Me", systemImage: model.location.locating ? "location.circle" : "location.fill") }.disabled(model.location.locating).help("Center the map on this Mac's location")
                Menu {
                    Button("Go Home") { if let h = model.location.home { bridge.goTo(lat: h.lat, lon: h.lon, zoom: 12) } }.disabled(model.location.home == nil)
                    Button("Set Home to Marker") { if let p = bridge.pin { model.location.setHome(lat: p.lat, lon: p.lon) } }.disabled(bridge.pin == nil)
                    Button("Set Home to My Location") { if let c = model.location.current { model.location.setHome(lat: c.lat, lon: c.lon) } }.disabled(model.location.current == nil)
                } label: { Label("Home", systemImage: "house") }.help("A saved point for when location is unavailable offline")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                TextField("Go to lat, lon", text: $gotoText).textFieldStyle(.roundedBorder).frame(width: 190).onSubmit { goTo() }.help("Decimal (39.74, -104.99) or degrees-minutes-seconds")
                Button { goTo() } label: { Label("Go", systemImage: "arrow.right.circle") }.disabled(gotoText.isEmpty)
                Button { if let p = bridge.pin { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(format: "%.5f, %.5f", p.lat, p.lon), forType: .string) } } label: { Label("Copy Marker", systemImage: "doc.on.doc") }.disabled(bridge.pin == nil).help("Copy the marker's coordinates")
                Button { downloadThisView() } label: { Label("Download Detail Here", systemImage: "square.and.arrow.down.on.square") }.help("Fetch street-level detail for the area currently on screen (needs internet once)")
                Menu {
                    Section("Installed map data") {
                        if maps.isEmpty { Text("None yet") }
                        ForEach(maps) { m in
                            Menu(m.title + (isWorld(m) ? " (world)" : "")) {
                                Text(ByteFormat.string(m.sizeBytes) + (m.header.map { " · zoom \($0.minZoom)–\($0.maxZoom)" } ?? ""))
                                if !isWorld(m) { Button("Show on Map") { if let h = m.header { bridge.fit(h) } } }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.fileURL]) }
                                Button("Move to Trash…", role: .destructive) { delete(m) }
                            }
                        }
                    }
                    Divider()
                    Button("Download a Region…") { showExtract = true }
                    Button(model.fullWorldMapInstalled ? "Full World Map Installed" : "Download the Full-Detail World Map (≈130 GB)…") { model.downloadFullWorldMap() }.disabled(model.fullWorldMapInstalled || model.fullWorldMapDownloading)
                    Button("Import Map File…") { importMaps() }
                    if !hasWorld { Button("Get the World Overview (Library Updates)") { Task { await model.checkForUpdates(interactive: true) } } }
                } label: { Label("Map Data", systemImage: "square.stack.3d.up") }.help("Installed regions, downloads and imports")
            }
        }
        .sheet(isPresented: $showExtract) { RegionExtractSheet(preset: extractPreset, bridge: bridge).environmentObject(model) }
        .task { reload() }
        .onReceive(model.$libraryGeneration) { _ in reload() }
        .task { if model.location.current == nil, !model.location.locating { try? await Task.sleep(nanoseconds: 1_500_000_000); if let f = try? await model.location.locate() { bridge.setLocation(lat: f.lat, lon: f.lon, accuracy: f.accuracy) } } }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers { p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { Task { @MainActor in model.importDropped(u) } } } }
            return true
        }
    }

    var subtitle: String {
        if let p = bridge.pin { return String(format: "Marker %.5f, %.5f", p.lat, p.lon) }
        if st.importing { return "Importing map…" }
        let detail = regions.isEmpty ? "" : " · street detail: " + regions.map(\.title).joined(separator: ", ")
        return (hasWorld ? "World map, offline" : (maps.isEmpty ? "No map data yet — Map Data › Download a Region" : "No world overview yet")) + detail
    }

    @ViewBuilder var detail: some View {
        if let web = Bundle.main.resourceURL?.appendingPathComponent("web"), FileManager.default.fileExists(atPath: web.appendingPathComponent("maplibre-gl.js").path) {
            MapWebView(mapsKey: mapsKey, webRoot: web, mapsService: model.mapsService, bridge: bridge, initialFix: model.location.best)
        } else {
            EmptyState(icon: "exclamationmark.triangle", title: "Map viewer is missing from this copy", message: "Please reinstall OfflineVault.")
        }
    }

    func downloadThisView() {
        Task {
            guard let b = await bridge.bounds() else { extractPreset = nil; showExtract = true; return }
            let w = b.2 - b.0, h = b.3 - b.1
            if w * h > 25 { model.banner = UserFacingError("Zoom in first", message: "The current view is about \(Int(w * 111)) km across; street-level detail for an area that large would be many gigabytes.", recovery: "Zoom in to a city or county, then choose Download Detail Here again."); return }
            let name = String(format: "area-%.2f-%.2f", (b.1 + b.3) / 2, (b.0 + b.2) / 2).replacingOccurrences(of: ".", with: "_")
            extractPreset = .init(name: name, west: b.0, south: b.1, east: b.2, north: b.3, zoom: 14)
            showExtract = true
        }
    }

    func locateMe() {
        Task {
            do { let f = try await model.location.locate(); bridge.setLocation(lat: f.lat, lon: f.lon, accuracy: f.accuracy) }
            catch {
                if let last = model.location.best { bridge.setLocation(lat: last.lat, lon: last.lon, accuracy: last.accuracy) }
                model.banner = error.userFacing
            }
        }
    }

    func goTo() {
        guard let (lat, lon) = Coordinates.parse(gotoText) else { model.banner = UserFacingError("Could not read those coordinates", message: "Try “39.74, -104.99” or “39°44'32\"N 104°59'02\"W”."); return }
        bridge.goTo(lat: lat, lon: lon)
    }

    func delete(_ m: OfflineMap) {
        guard Panels.confirm("Move the “\(m.title)” map to the Trash?", message: "\(ByteFormat.string(m.sizeBytes)). Regions from Library updates can be downloaded again.", button: "Move to Trash") else { return }
        model.mapsService?.delete(m); reload()
    }
    func reload() { let list = model.mapsService?.maps() ?? []; if list != maps { maps = list } }
    func importMaps() {
        let urls = Panels.chooseFiles(types: ["pmtiles"], prompt: "Import", multiple: true, message: "Choose .pmtiles map files.")
        for u in urls { model.importDropped(u) }
    }
}

/// Builds a region with the bundled pmtiles tool (needs internet once); shows progress and installs the result.
struct RegionExtractSheet: View {
    struct Preset { var name: String; var west: Double; var south: Double; var east: Double; var north: Double; var zoom: Int }
    var preset: Preset? = nil
    var bridge: MapBridge? = nil
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = "home"
    @State private var west = ""
    @State private var south = ""
    @State private var east = ""
    @State private var north = ""
    @State private var detail = 14
    @State private var running = false
    @State private var log = ""
    @State private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download a map region").font(.title2.bold())
            Text("Street-level detail is fetched per area because the whole planet at that level is over 100 GB. A city or county is about 100–400 MB; a US state 2–6 GB. Needs internet while it runs; the map works offline afterwards.").foregroundStyle(.secondary)
            if let bridge { Button("Use the Area on Screen") { Task { if let b = await bridge.bounds() { west = String(format: "%.3f", b.0); south = String(format: "%.3f", b.1); east = String(format: "%.3f", b.2); north = String(format: "%.3f", b.3) } } }.controlSize(.small) }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Name"); TextField("home", text: $name).frame(width: 220) }
                GridRow { Text("West / South"); HStack { TextField("-105.9", text: $west); TextField("38.5", text: $south) }.frame(width: 220) }
                GridRow { Text("East / North"); HStack { TextField("-103.5", text: $east); TextField("40.9", text: $north) }.frame(width: 220) }
                GridRow { Text("Detail"); Picker("", selection: $detail) { Text("Towns and roads (zoom 10)").tag(10); Text("Streets (zoom 14)").tag(14); Text("Full street detail (zoom 15)").tag(15) }.labelsHidden().frame(width: 260) }
            }
            if running || !log.isEmpty { ScrollView { Text(log).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 120).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6)) }
            HStack { Button(running ? "Cancel" : "Close") { if running { task?.cancel() } else { dismiss() } }; Spacer(); Button(running ? "Downloading…" : "Download") { run() }.buttonStyle(.borderedProminent).disabled(running || !valid) }
        }.padding(20).frame(width: 560)
        .onAppear { if let p = preset { name = p.name; west = String(format: "%.3f", p.west); south = String(format: "%.3f", p.south); east = String(format: "%.3f", p.east); north = String(format: "%.3f", p.north); detail = p.zoom } }
    }
    var valid: Bool { [west, south, east, north].allSatisfy { Double($0) != nil } && !name.trimmingCharacters(in: .whitespaces).isEmpty }
    func run() {
        guard let tool = Bundle.main.resourceURL?.appendingPathComponent("bin/pmtiles"), FileManager.default.isExecutableFile(atPath: tool.path), let layout = model.layout else { model.banner = UserFacingError("Map tool missing", message: "This copy of OfflineVault has no map builder.", recovery: "Reinstall OfflineVault."); return }
        running = true; log = "Starting…\n"
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.timeZone = TimeZone(identifier: "UTC")
        let build = f.string(from: Date().addingTimeInterval(-86400))
        let out = layout.staging.appendingPathComponent(name.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression) + ".pmtiles")
        let args = ["extract", "https://build.protomaps.com/\(build).pmtiles", out.path, "--bbox=\(west),\(south),\(east),\(north)", "--maxzoom=\(detail)"]
        task = Task {
            do {
                let r = try await ProcessRunner.run(tool, arguments: args) { line, _ in Task { @MainActor in log += line + "\n"; if log.count > 4000 { log = String(log.suffix(3000)) } } }
                if r.exitCode == 0, let m = try? model.mapsService?.importMap(from: out) { try? FileManager.default.removeItem(at: out); model.libraryGeneration += 1; model.mapsScreen.selected = m; Notifier.post(title: "Map region ready", body: m.title); dismiss() }
                else { log += "\nFailed (exit \(r.exitCode)). " + (r.stderr.split(separator: "\n").last.map(String.init) ?? "") }
            } catch { log += "\n" + error.userFacing.message }
            running = false
        }
    }
}

/// Drives the map page from SwiftUI (go to coordinates, fit a region) and receives pin/copy events.
@MainActor final class MapBridge: ObservableObject {
    weak var web: WKWebView?
    @Published var pin: (lat: Double, lon: Double)?
    func goTo(lat: Double, lon: Double, zoom: Double? = nil) { web?.evaluateJavaScript("window.ovGoTo && ovGoTo(\(lat), \(lon)\(zoom.map { ", \($0)" } ?? ""))") }
    func setLocation(lat: Double, lon: Double, accuracy: Double) { web?.evaluateJavaScript("window.ovSetLocation && ovSetLocation(\(lat), \(lon), \(accuracy), true)") }
    /// Current viewport as west,south,east,north.
    func bounds() async -> (Double, Double, Double, Double)? {
        guard let web else { return nil }
        let r = try? await web.evaluateJavaScript("JSON.stringify(window.ovMap ? ovMap.getBounds().toArray().flat() : null)")
        guard let s = r as? String, let d = s.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: d) as? [Double], a.count == 4 else { return nil }
        return (a[0], a[1], a[2], a[3])
    }
    func fit(_ h: PMTilesHeader) { web?.evaluateJavaScript("window.ovFit && ovFit(\(h.minLon), \(h.minLat), \(h.maxLon), \(h.maxLat))") }
}

struct MapWebView: NSViewRepresentable {
    let mapsKey: String
    let webRoot: URL
    let mapsService: MapsService?
    let bridge: MapBridge
    var initialFix: LocationService.Fix? = nil
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
        cfg.setURLSchemeHandler(AssetSchemeHandler(root: webRoot), forURLScheme: "ovweb")
        cfg.setURLSchemeHandler(TilesSchemeHandler(service: mapsService), forURLScheme: "ovtiles")
        cfg.userContentController.add(context.coordinator, name: "ov")
        let web = WKWebView(frame: .zero, configuration: cfg); web.navigationDelegate = context.coordinator
        web.setAccessibilityLabel("Map")
        bridge.web = web
        RuleListCache.shared.rules { list in if let list { web.configuration.userContentController.add(list) }; self.load(web, context: context) }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) { bridge.web = web; context.coordinator.bridge = bridge; if context.coordinator.loaded != mapsKey { load(web, context: context) } }
    private func load(_ web: WKWebView, context: Context) {
        context.coordinator.loaded = mapsKey
        var c = URLComponents(string: "ovweb://assets/map.html")!
        if let f = initialFix { c.queryItems = [URLQueryItem(name: "lat", value: String(f.lat)), URLQueryItem(name: "lon", value: String(f.lon)), URLQueryItem(name: "acc", value: String(f.accuracy)), URLQueryItem(name: "z", value: f.accuracy > 2000 ? "9" : "11")] }
        web.load(URLRequest(url: c.url!))
    }
    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loaded: String?
        var bridge: MapBridge
        init(bridge: MapBridge) { self.bridge = bridge }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(["ovweb", "ovtiles", "about", "blob", "data"].contains(navigationAction.request.url?.scheme ?? "") ? .allow : .cancel)
        }
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "pin", let lat = body["lat"] as? Double, let lon = body["lon"] as? Double { bridge.pin = (lat, lon) }
            if type == "copy", let t = body["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }
        }
    }
}

final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let path = url.path.removingPercentEncoding, !path.contains("..") else { return task.didFailWithError(URLError(.badURL)) }
        let file = root.appendingPathComponent(String(path.dropFirst()))
        guard let data = FileManager.default.contents(atPath: file.path) else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
        let mime = ["html": "text/html", "js": "application/javascript", "css": "text/css", "json": "application/json", "png": "image/png", "pbf": "application/x-protobuf"][file.pathExtension.lowercased()] ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"])!)
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class TilesSchemeHandler: NSObject, WKURLSchemeHandler {
    let service: MapsService?
    init(service: MapsService?) { self.service = service }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let service else { return task.didFailWithError(URLError(.badURL)) }
        if url.host == "list" {
            let maps = service.maps().map { m -> [String: Any] in
                let h = m.header
                return ["file": m.name, "name": m.title, "minZoom": h?.minZoom ?? 0, "maxZoom": h?.maxZoom ?? 15, "version": h?.version ?? "", "bounds": [h?.minLon ?? -180, h?.minLat ?? -85, h?.maxLon ?? 180, h?.maxLat ?? 85], "center": [h?.centerLon ?? 0, h?.centerLat ?? 0]]
            }
            let data = (try? JSONSerialization.data(withJSONObject: maps)) ?? Data("[]".utf8)
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"])!)
            task.didReceive(data); task.didFinish(); return
        }
        guard let name = url.path.removingPercentEncoding?.dropFirst(), let file = service.fileURL(named: String(name)) else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var range: Range<Int64> = 0..<size; var status = 200
        if let rh = task.request.value(forHTTPHeaderField: "Range"), let r = LocalShareServer.parseRange(rh, size: size) { range = r; status = 206 }
        do {
            let data = try service.read(file, range: range)
            var headers = ["Content-Type": "application/octet-stream", "Content-Length": String(data.count), "Accept-Ranges": "bytes", "Access-Control-Allow-Origin": "*"]
            if status == 206 { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.lowerBound + Int64(data.count) - 1)/\(size)" }
            task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}


/// Parses "39.74, -104.99", "39.74 -104.99", "39°44'32\"N 104°59'02\"W", "N39.74 W104.99".
enum Coordinates {
    static func parse(_ raw: String) -> (Double, Double)? {
        let s = raw.replacingOccurrences(of: "[°º'′\"″]", with: " ", options: .regularExpression).replacingOccurrences(of: ",", with: " ")
        let pattern = "^\\s*([NnSs])?\\s*(-?\\d+(?:\\.\\d+)?)(?:\\s+(\\d+(?:\\.\\d+)?))?(?:\\s+(\\d+(?:\\.\\d+)?))?\\s*([NnSs])?\\s+([EeWw])?\\s*(-?\\d+(?:\\.\\d+)?)(?:\\s+(\\d+(?:\\.\\d+)?))?(?:\\s+(\\d+(?:\\.\\d+)?))?\\s*([EeWw])?\\s*$"
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func g(_ i: Int) -> String? { guard let r = Range(m.range(at: i), in: s) else { return nil }; return String(s[r]) }
        func dec(_ d: String?, _ mi: String?, _ se: String?, _ hemi: String?) -> Double? {
            guard let d, let dv = Double(d) else { return nil }
            var v = abs(dv) + (mi.flatMap(Double.init) ?? 0) / 60 + (se.flatMap(Double.init) ?? 0) / 3600
            if dv < 0 { v = -v }
            if let h = hemi, "SsWw".contains(h) { v = -abs(v) }
            return v
        }
        guard let lat = dec(g(2), g(3), g(4), g(1) ?? g(5)), let lon = dec(g(7), g(8), g(9), g(6) ?? g(10)), abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (lat, lon)
    }
}
