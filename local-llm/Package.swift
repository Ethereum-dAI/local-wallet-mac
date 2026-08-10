// swift-tools-version: 6.0
import Foundation
import PackageDescription

// llama.cpp prefix resolution:
//
//   1. LOCAL_LLAMA_PREFIX     — explicit override (release packaging, a hand-built prefix, or a
//                               deliberate `LOCAL_LLAMA_PREFIX=/opt/homebrew` brew opt-in)
//   2. <repo>/.llama/current  — the pin from local-llm/LLAMA_CPP_PIN, assembled by
//                               scripts/provision-llama.sh (the normal case; build-ffi.sh runs it)
//
// There is deliberately NO implicit Homebrew fallback. The llama.cpp common/ headers vendored
// under Sources/CLlamaBridge/third_party/llama_cpp_common/ are on the include path
// unconditionally, so quietly linking a Homebrew libllama-common would pair those headers with a
// different build of their own implementations. Because the mangled C++ symbol names do not change
// between llama.cpp versions, that mismatch does not fail to link — it corrupts at runtime. An
// unprovisioned tree instead fails fast with 'llama.h' file not found, naming .llama/current in
// the include path.
//
// The pinned prefix is found via #filePath rather than an environment variable on purpose:
// SwiftPM evaluates this manifest in its own process and Xcode does not reliably forward
// scheme environment variables to manifest evaluation, so an env-var-only default would
// break the Xcode build. (#filePath resolves fine here; only *writes* are sandboxed.)
let environment = ProcessInfo.processInfo.environment
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // local-llm/
    .deletingLastPathComponent()  // repo root
    .path
let pinnedPrefix = "\(repoRoot)/.llama/current"

let llamaPrefix = environment["LOCAL_LLAMA_PREFIX"] ?? pinnedPrefix
let llamaIncludeDir = environment["LOCAL_LLAMA_INCLUDE_DIR"] ?? "\(llamaPrefix)/include"
let llamaLibDir = environment["LOCAL_LLAMA_LIB_DIR"] ?? "\(llamaPrefix)/lib"

// llama.cpp's common/ headers (chat.h, the jinja renderer, bundled nlohmann).
// They used to be committed under Sources/CLlamaBridge/third_party/ and reached
// via .headerSearchPath; provision-llama.sh now fetches them at the pinned
// commit, which means they live outside the target and need a -I instead.
//
// An explicit LOCAL_LLAMA_PREFIX must therefore supply include-common/ as well as
// include/ and lib/, or point this at the common/ directory of a llama.cpp source
// tree at the matching commit.
let llamaCommonIncludeDir = environment["LOCAL_LLAMA_COMMON_INCLUDE_DIR"]
    ?? "\(llamaPrefix)/include-common"

let package = Package(
    name: "LocalLLM",
    platforms: [.macOS(.v15)],
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
                // CLlamaBridge.cpp includes <llama.h> from the first path and
                // "chat.h" / "nlohmann/json.hpp" from the second (it implements
                // chat_render / parse_assistant_turn / count_tokens / generate_v2).
                .unsafeFlags([
                    "-I\(llamaIncludeDir)",
                    "-I\(llamaCommonIncludeDir)",
                    "-std=c++17",
                ]),
                .define("LLAMA_USE_CURL", to: "0"),
            ],
            linkerSettings: [
                // The upstream llama.cpp release dylibs use @rpath install names (unlike
                // Homebrew's, which bake absolute paths), so consumers must supply the
                // runtime search path. Harmless for an explicit Homebrew prefix, whose
                // absolute install names do not consult it.
                // Note: -Wl,-rpath,... is rejected by SwiftPM's driver; pass it as
                // separate -Xlinker arguments as below.
                .unsafeFlags(["-L\(llamaLibDir)", "-Xlinker", "-rpath", "-Xlinker", llamaLibDir]),
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
