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
    ],
    dependencies: [
        .package(path: "../swift-bridge"),
    ],
    targets: [
        .executableTarget(
            name: "WalletMacOSApp",
            dependencies: [
                .product(name: "WalletSignature", package: "swift-bridge"),
            ],
            path: "Sources/WalletMacOSApp",
            resources: [
                .copy("Resources"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", bridgeLibraryPath]),
            ]
        ),
    ]
)
