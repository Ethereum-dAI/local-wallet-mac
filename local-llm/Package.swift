// swift-tools-version: 6.0
import Foundation
import PackageDescription

let llamaPrefix = ProcessInfo.processInfo.environment["LOCAL_LLAMA_PREFIX"] ?? "/opt/homebrew"
let llamaIncludeDir = ProcessInfo.processInfo.environment["LOCAL_LLAMA_INCLUDE_DIR"] ?? "\(llamaPrefix)/include"
let llamaLibDir = ProcessInfo.processInfo.environment["LOCAL_LLAMA_LIB_DIR"] ?? "\(llamaPrefix)/lib"

let package = Package(
    name: "LocalLLM",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalLLM", targets: ["LocalLLM"]),
        .executable(name: "llm-bench", targets: ["llm-bench"]),
    ],
    targets: [
        .target(
            name: "CLlamaBridge",
            path: "Sources/CLlamaBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-I\(llamaIncludeDir)", "-std=c++17"]),
                // Headers vendored from llama.cpp common/ are consumed by
                // CLlamaBridge.cpp (it `#include "chat.h"` and implements
                // chat_render / parse_assistant_turn / count_tokens / generate_v2);
                // this search path makes them resolvable.
                .headerSearchPath("third_party/llama_cpp_common"),
                .define("LLAMA_USE_CURL", to: "0"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(llamaLibDir)"]),
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
        .executableTarget(
            name: "llm-bench",
            dependencies: ["LocalLLM"],
            path: "Sources/llm-bench",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LocalLLMTests",
            dependencies: ["LocalLLM"],
            path: "Tests/LocalLLMTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
