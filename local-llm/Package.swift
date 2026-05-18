// swift-tools-version: 6.0
import PackageDescription

let homebrewPrefix = "/opt/homebrew"

let package = Package(
    name: "LocalLLM",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalLLM", targets: ["LocalLLM"]),
    ],
    targets: [
        .target(
            name: "CLlamaBridge",
            path: "Sources/CLlamaBridge",
            exclude: [],
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-I\(homebrewPrefix)/include", "-std=c++17"]),
                .headerSearchPath("third_party/llama_cpp_common"),
                .define("LLAMA_USE_CURL", to: "0"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(homebrewPrefix)/lib"]),
                .linkedLibrary("llama"),
                .linkedLibrary("llama-common"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
            ]
        ),
        .target(
            name: "LocalLLM",
            dependencies: ["CLlamaBridge"],
            path: "Sources/LocalLLM"
        ),
        .testTarget(
            name: "LocalLLMTests",
            dependencies: ["LocalLLM"],
            path: "Tests/LocalLLMTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
