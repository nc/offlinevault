import Foundation
import XCTest
@testable import OfflineVaultCore

enum Fixtures {
    static func url(_ name: String) -> URL {
        guard let u = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else { fatalError("missing fixture \(name)") }
        return u
    }
    static func data(_ name: String) -> Data { try! Data(contentsOf: url(name)) }
    static func string(_ name: String) -> String { String(data: data(name), encoding: .utf8)! }
}

func makeTempLibrary(_ test: XCTestCase) throws -> LibraryLayout {
    // OV_LIBRARY_DIR keeps the library after the test (handy to inspect, or to seed the app for a manual run).
    if let keep = ProcessInfo.processInfo.environment["OV_LIBRARY_DIR"], !keep.isEmpty {
        let layout = LibraryLayout(root: URL(fileURLWithPath: keep, isDirectory: true))
        try layout.ensureDirectories()
        return layout
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ov-tests-" + UUID().uuidString, isDirectory: true)
    let layout = LibraryLayout(root: root)
    try layout.ensureDirectories()
    test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return layout
}
