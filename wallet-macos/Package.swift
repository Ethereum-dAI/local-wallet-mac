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
        .library(name: "WalletToolLayer", targets: ["WalletToolLayer"]),
        .executable(name: "wallet-eval", targets: ["wallet-eval"]),
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
                "WalletToolLayer",
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
        .target(
            name: "WalletToolLayer",
            dependencies: [
                .product(name: "LocalLLM", package: "local-llm"),
            ],
            path: "Sources/WalletToolLayer",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "wallet-eval",
            dependencies: [
                "WalletToolLayer",
                .product(name: "LocalLLM", package: "local-llm"),
            ],
            path: "Sources/wallet-eval"
        ),
        .testTarget(
            name: "WalletToolLayerTests",
            dependencies: ["WalletToolLayer"],
            path: "Tests/WalletToolLayerTests"
        ),
    ]
)
