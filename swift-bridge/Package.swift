// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let bridgeLibraryPath = packageRoot.appendingPathComponent("lib").path

let package = Package(
    name: "WalletBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WalletSignature", targets: ["WalletSignature"]),
    ],
    targets: [
        .systemLibrary(
            name: "WalletFFI",
            path: "Sources/WalletFFI"
        ),
        .target(
            name: "WalletSignature",
            dependencies: ["WalletFFI"],
            path: "Sources/WalletSignature",
            linkerSettings: [
                .unsafeFlags(["-L", bridgeLibraryPath]),
            ]
        ),
        .testTarget(
            name: "WalletSignatureTests",
            dependencies: ["WalletSignature"],
            linkerSettings: [
                .unsafeFlags(["-L", bridgeLibraryPath]),
            ]
        ),
    ]
)
