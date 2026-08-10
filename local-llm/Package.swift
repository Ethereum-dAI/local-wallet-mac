// swift-tools-version: 6.0
import Foundation
import PackageDescription

// llama.cpp prefix resolution:
//
//   1. LOCAL_LLAMA_PREFIX     — explicit override (a hand-built llama.cpp). It must supply lib/,
//                               include/ AND include-common/; see below.
//   2. <repo>/.llama/current  — the pin from local-llm/LLAMA_CPP_PIN, assembled by
//                               scripts/provision-llama.sh (the normal case; build-ffi.sh runs it)
//
// There is deliberately NO implicit Homebrew fallback, and Homebrew is not a usable override
// either: it ships llama.cpp's public headers but none of the common/ layer (chat.h, the jinja
// renderer, bundled nlohmann) that CLlamaBridge.cpp includes, so pointing at /opt/homebrew fails
// on 'chat.h' file not found. Those headers come from the pinned commit — provision-llama.sh
// stages them into include-common/ — and pairing them with a different build of libllama-common
// would not fail to link, because the mangled C++ symbol names do not change between llama.cpp
// versions. It would corrupt at runtime. So resolution stops at the pinned prefix, and an
// unprovisioned tree fails fast with 'llama.h' file not found, naming .llama/current in the
// include path.
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
// include/ and lib/. Note that upstream's own common/ directory will NOT do
// unmodified: chat.h includes "nlohmann/json_fwd.hpp" relative to itself, while
// upstream keeps nlohmann at vendor/nlohmann/ and resolves it with a separate -I.
// provision-llama.sh nests it under include-common/nlohmann/ for that reason, so
// an override has to reproduce that layout.
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
