// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OfflineVaultCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OfflineVaultCore", targets: ["OfflineVaultCore"]),
        .executable(name: "licencetool", targets: ["licencetool"]),
        .executable(name: "catalogtool", targets: ["catalogtool"]),
        .executable(name: "retrievaltool", targets: ["retrievaltool"]),
    ],
    targets: [
        .target(
            name: "OfflineVaultCore",
            path: "Sources/OfflineVaultCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "licencetool",
            dependencies: ["OfflineVaultCore"],
            path: "Sources/licencetool"
        ),
        .executableTarget(
            name: "catalogtool",
            dependencies: ["OfflineVaultCore"],
            path: "Sources/catalogtool"
        ),
        .executableTarget(
            name: "retrievaltool",
            dependencies: ["OfflineVaultCore"],
            path: "Sources/retrievaltool"
        ),
        .testTarget(
            name: "OfflineVaultCoreTests",
            dependencies: ["OfflineVaultCore"],
            path: "Tests/OfflineVaultCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
