// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let bridgeLibraryPath = packageRoot.appendingPathComponent("lib").path

let package = Package(
    name: "WalletBridge",
    // String form, not `.v15`: the `.v15` case requires swift-tools-version 6.0, and bumping
    // this manifest to 6.0 would also switch the package into Swift 6 language mode as a side
    // effect. Keep the deployment-target change to just the deployment target.
    platforms: [.macOS("15.0")],
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
