// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let bridgeLibraryPath = packageRoot.deletingLastPathComponent().appendingPathComponent("swift-bridge/lib").path

let package = Package(
    name: "WalletMacOS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WalletMacOSApp", targets: ["WalletMacOSApp"]),
        .library(name: "SpawnHelper", targets: ["SpawnHelper"]),
    ],
    dependencies: [
        .package(path: "../swift-bridge"),
        .package(path: "../local-llm"),
    ],
    targets: [
        .executableTarget(
            name: "WalletMacOSApp",
            dependencies: [
                .product(name: "WalletSignature", package: "swift-bridge"),
                .product(name: "LocalLLM", package: "local-llm"),
                "SpawnHelper",
            ],
            path: "Sources/WalletMacOSApp",
            resources: [
                .copy("Resources"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-L", bridgeLibraryPath]),
            ]
        ),
        .target(
            name: "CSpawn",
            path: "Sources/Spawn",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SpawnHelper",
            dependencies: ["CSpawn"],
            path: "Sources/SpawnHelper"
        ),
        .testTarget(
            name: "SpawnHelperTests",
            dependencies: ["SpawnHelper"],
            path: "Tests/SpawnHelperTests"
        ),
    ]
)
