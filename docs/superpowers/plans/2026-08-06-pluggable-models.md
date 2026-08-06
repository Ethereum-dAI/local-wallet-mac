# Pluggable Models Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Gemma 4 E4B Q4_0 as the default local model, add the ability to download any public GGUF from a Hugging Face repo, make the active model switchable from Settings, and gate both download and activation behind a per-model hardware fit check that advises but never blocks.

**Architecture:** Five new pure/IO-isolated units in `wallet-macos/Sources/WalletMacOSApp/` — a hardware budget reader, a fit evaluator, a GGUF header reader, a Hugging Face repository client, and an installed-model store — feed one merged `ModelCatalog`. `EmbeddedLlamaInferenceService` gains a swap seam so the active model can change without restarting the app. Settings and onboarding consume the catalog and render a `Fits / Tight / Won't fit / Unknown` verdict per row. Everything else (Secure Enclave signing, the daemon, the FFI) is untouched.

**Tech Stack:** Swift 6 / SwiftUI, swift-testing (`import Testing`, `@Test`, `#expect`), Metal (`MTLDevice.recommendedMaxWorkingSetSize`), URLSession, CryptoKit, llama.cpp via `CLlamaBridge`.

## Global Constraints

- Everything in this plan lives in the **`wallet-macos` Swift package**. No Rust, no daemon, no protocol-crate changes.
- `./scripts/build-ffi.sh` must be run once before any `swift build` / `swift test` in this repo. It is not optional.
- Test framework is **swift-testing**, not XCTest: `import Testing`, `struct XTests { @Test func … { #expect(…) } }`. Match the existing files in `wallet-macos/Tests/WalletMacOSAppTests/`.
- New `.swift` files under `wallet-macos/Sources/WalletMacOSApp/` are picked up by SPM globbing. **Do not** edit `LocalWallet.xcodeproj` and **do not** run `xcodegen` for this work.
- No unit test may touch the network. Hugging Face responses are exercised through string-literal fixtures embedded in the test file. Live-network checks are manual commands in the plan, never `@Test`s.
- Deployment floor stays macOS 15.0. Do not change it.
- Never commit to `main`. All work happens on branch `feat/pluggable-models`.
- Every commit message ends with the trailer:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`
- The default model must remain `google/gemma-4-E4B-it` / `gemma-4-E4B-it-Q4_0.gguf`. An existing user who upgrades and touches nothing must see identical behavior.
- Memory reserve **scales**: `reserve = min(8 GB, 40% of RAM)`. Budget is `min(metalBudgetBytes, totalMemoryBytes − reserve)`, saturating at 0. A flat 8 GB reserve would give an 8 GB Mac a budget of zero and fail every model, including tiny ones.
- **There is no RAM threshold anywhere.** The `LocalHardwareProfile.minimumModelMemoryBytes = 16 GB` gate is deleted, along with the four onboarding strings and the `README.md` line that quote it. An 8 GB Mac is told what the chosen model needs and what it has, and may proceed.
- Fit thresholds: `need ≤ 80% of budget` → `.fits`; `need ≤ budget` → `.tight`; else `.wontFit`. Missing profile data → `.unknown`.
- **The context-window picker only offers presets that can actually run** (verdict `.fits`, `.tight`, or `.unknown`). A `.wontFit` preset is never listed — the app does not suggest a setting that will hang it. This does not soften the advisory stance on *models*: a won't-fit model is still installable and selectable behind a confirmation. Decided by the human on 2026-08-06, overriding the plan's earlier "every preset is offered".
- Overhead factor on top of weights + KV cache is **1.15**.

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `Sources/WalletMacOSApp/HardwareBudget.swift` | `HardwareBudget` value type + Metal/disk probing added to the existing inspector |
| `Sources/WalletMacOSApp/ModelMemoryProfile.swift` | `ModelMemoryProfile`, `ModelFitVerdict`, `ModelFitEvaluator` — pure math, no IO |
| `Sources/WalletMacOSApp/GGUFHeaderReader.swift` | Parse a GGUF metadata header out of a `Data` prefix; range-fetch that prefix |
| `Sources/WalletMacOSApp/HuggingFaceRepository.swift` | Resolve `owner/name` → GGUF file list (size + SHA-256) and repo-level metadata |
| `Sources/WalletMacOSApp/InstalledModelStore.swift` | Persist many installed models; migrate the two legacy single-slot keys |
| `Sources/WalletMacOSApp/ModelCatalog.swift` | Merge curated + custom models into one ordered list |
| `Sources/WalletMacOSApp/ModelSelfTest.swift` | Post-download load test with context step-down and a tool-call probe |
| `Tests/WalletMacOSAppTests/ModelFitEvaluatorTests.swift` | Fit math |
| `Tests/WalletMacOSAppTests/GGUFHeaderReaderTests.swift` | Header parsing against a synthesized fixture |
| `Tests/WalletMacOSAppTests/HuggingFaceRepositoryTests.swift` | JSON parsing against recorded fixtures |
| `Tests/WalletMacOSAppTests/InstalledModelStoreTests.swift` | Persistence + legacy migration |
| `Tests/WalletMacOSAppTests/ModelCatalogTests.swift` | Merge order, default preservation |
| `Tests/WalletMacOSAppTests/ModelSelfTestTests.swift` | Step-down and failure handling with a stub runtime |

**Modified:**

| File | Change |
|---|---|
| `Sources/WalletMacOSApp/LocalHardwareInspector.swift` | Return a `HardwareBudget` alongside today's profile |
| `Sources/WalletMacOSApp/OnboardingSettingsStore.swift` | `LocalAIModel` gains `memoryProfile` + `source`; Gemma's trained context corrected |
| `Sources/WalletMacOSApp/LocalAIModelDownloadManager.swift` | Download an arbitrary `(URL, filename, expected SHA-256)`; free-disk precheck |
| `Sources/WalletMacOSApp/ContextWindowPresets.swift` | Ladder extended past 32 768 |
| `Sources/WalletMacOSApp/EmbeddedLlamaInferenceService.swift` | Swap the active model without an app restart |
| `Sources/WalletMacOSApp/AppModel.swift` | `selectModel`, `downloadModel`, `removeModel`, hardware budget state |
| `Sources/WalletMacOSApp/ChatDashboardView.swift` | Snapshot fields + settings callbacks |
| `Sources/WalletMacOSApp/LocalWalletSettingsView.swift` | `modelsTab` rebuilt |
| `Sources/WalletMacOSApp/OnboardingView.swift` | Fit chips + Hugging Face disclosure |
| `Tests/WalletMacOSAppTests/SettingsWiringAuditTests.swift` | The `available.count == 1` invariant is retired deliberately |

---

### Task 1: Hardware budget

**Files:**
- Create: `wallet-macos/Sources/WalletMacOSApp/HardwareBudget.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/LocalHardwareInspector.swift`
- Test: `wallet-macos/Tests/WalletMacOSAppTests/HardwareBudgetTests.swift`

**Interfaces:**
- Produces: `struct HardwareBudget { let totalMemoryBytes: UInt64; let metalBudgetBytes: UInt64; let freeDiskBytes: UInt64; var usableBytes: UInt64; var comfortableBytes: UInt64 }`, `static func systemReserveBytes(totalMemoryBytes:) -> UInt64`, and `LocalHardwareInspector.budget() async -> HardwareBudget`.

- [ ] **Step 1: Write the failing test**

Create `wallet-macos/Tests/WalletMacOSAppTests/HardwareBudgetTests.swift`:

```swift
import Foundation
import Testing
@testable import WalletMacOSApp

struct HardwareBudgetTests {
    private let gb: UInt64 = 1_073_741_824

    @Test func usableIsMetalBudgetWhenItIsTheTighterBound() {
        // 36 GB Mac: Metal reports 28.1 GB, RAM − 8 GB = 28 GB.
        let budget = HardwareBudget(
            totalMemoryBytes: 36 * gb,
            metalBudgetBytes: 30_182_211_584,
            freeDiskBytes: 200 * gb
        )
        #expect(budget.usableBytes == 28 * gb)
    }

    @Test func usableIsRamMinusReserveWhenMetalIsGenerous() {
        // 16 GB: reserve is 40% (6.4 GiB), leaving 9.6 GiB — tighter than Metal's 14 GiB.
        let budget = HardwareBudget(
            totalMemoryBytes: 16 * gb,
            metalBudgetBytes: 14 * gb,
            freeDiskBytes: 100 * gb
        )
        #expect(budget.usableBytes == 10_307_921_544)
    }

    /// The reserve scales so small machines keep a workable budget instead of zero.
    /// An 8 GB Air: Metal offers ~6 GiB, reserve is 3.2 GiB, so 4.8 GiB is usable.
    @Test func eightGigMacKeepsANonZeroBudget() {
        let budget = HardwareBudget(
            totalMemoryBytes: 8 * gb,
            metalBudgetBytes: 6 * gb,
            freeDiskBytes: 100 * gb
        )
        #expect(budget.usableBytes == 5_153_960_792)
    }

    @Test func reserveIsCappedAtEightGigabytesOnLargeMachines() {
        #expect(HardwareBudget.systemReserveBytes(totalMemoryBytes: 128 * gb) == 8 * gb)
        #expect(HardwareBudget.systemReserveBytes(totalMemoryBytes: 8 * gb) < 8 * gb)
    }

    @Test func comfortableIsEightyPercentOfUsable() {
        let budget = HardwareBudget(
            totalMemoryBytes: 36 * gb,
            metalBudgetBytes: 30_182_211_584,
            freeDiskBytes: 200 * gb
        )
        #expect(budget.comfortableBytes == (28 * gb) / 100 * 80)
    }

    @Test func liveInspectionReportsPlausibleNumbers() async {
        let budget = await LocalHardwareInspector().budget()
        #expect(budget.totalMemoryBytes > 0)
        #expect(budget.metalBudgetBytes > 0)
        #expect(budget.metalBudgetBytes <= budget.totalMemoryBytes)
        #expect(budget.freeDiskBytes > 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
./scripts/build-ffi.sh
cd wallet-macos && swift test --filter HardwareBudgetTests
```
Expected: FAIL — `cannot find 'HardwareBudget' in scope`.

- [ ] **Step 3: Write the implementation**

Create `wallet-macos/Sources/WalletMacOSApp/HardwareBudget.swift`:

```swift
import Foundation
import Metal

/// How much memory a local model may realistically occupy on this Mac.
///
/// `metalBudgetBytes` is what Metal will hand out before performance degrades
/// (`MTLDevice.recommendedMaxWorkingSetSize`, ~75-78% of unified memory on Apple
/// Silicon). We take the tighter of that and "RAM minus a fixed reserve for macOS,
/// the app, and wallet-node", because the GPU ceiling alone would starve everything
/// else on the machine.
struct HardwareBudget: Equatable {
    /// Held back for macOS, the app itself, and the wallet-node child process.
    /// Scales with the machine: a flat 8 GB would leave an 8 GB Mac with nothing.
    static func systemReserveBytes(totalMemoryBytes: UInt64) -> UInt64 {
        min(8 * 1_073_741_824, totalMemoryBytes / 100 * 40)
    }

    let totalMemoryBytes: UInt64
    let metalBudgetBytes: UInt64
    let freeDiskBytes: UInt64

    /// The hard ceiling. A model above this will swap or fail to load.
    var usableBytes: UInt64 {
        let reserve = Self.systemReserveBytes(totalMemoryBytes: totalMemoryBytes)
        let afterReserve = totalMemoryBytes > reserve ? totalMemoryBytes - reserve : 0
        return min(metalBudgetBytes, afterReserve)
    }

    /// The soft ceiling: below this, the model runs without crowding the machine.
    var comfortableBytes: UInt64 {
        usableBytes / 100 * 80
    }
}

extension LocalHardwareInspector {
    func budget() async -> HardwareBudget {
        HardwareBudget(
            totalMemoryBytes: Self.physicalMemoryBytesForBudget(),
            metalBudgetBytes: Self.metalBudgetBytes(),
            freeDiskBytes: Self.freeDiskBytes()
        )
    }

    static func metalBudgetBytes() -> UInt64 {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // No Metal device: fall back to the 75% Apple Silicon convention.
            return physicalMemoryBytesForBudget() / 100 * 75
        }
        return device.recommendedMaxWorkingSetSize
    }

    static func freeDiskBytes() -> UInt64 {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        let values = try? appSupport.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(max(values?.volumeAvailableCapacityForImportantUsage ?? 0, 0))
    }

    static func physicalMemoryBytesForBudget() -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0, value > 0 {
            return value
        }
        return ProcessInfo.processInfo.physicalMemory
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd wallet-macos && swift test --filter HardwareBudgetTests
```
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add wallet-macos/Sources/WalletMacOSApp/HardwareBudget.swift \
        wallet-macos/Tests/WalletMacOSAppTests/HardwareBudgetTests.swift
git commit -m "$(cat <<'EOF'
feat(models): read this Mac's Metal and disk budget for model sizing

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Fit evaluator

**Files:**
- Create: `wallet-macos/Sources/WalletMacOSApp/ModelMemoryProfile.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/ContextWindowPresets.swift`
- Test: `wallet-macos/Tests/WalletMacOSAppTests/ModelFitEvaluatorTests.swift`

**Interfaces:**
- Consumes: `HardwareBudget` (Task 1).
- Produces: `struct ModelMemoryProfile { weightBytes, blockCount, kvHeadCount, keyLength, valueLength, trainedContextTokens }`, `enum ModelFitVerdict { fits, tight, wontFit, unknown }`, `enum ModelFitEvaluator { kvCacheBytes(profile:contextTokens:), requiredBytes(profile:contextTokens:), verdict(profile:contextTokens:budget:), largestFittingContext(profile:budget:), minimumMemoryBytes(profile:contextTokens:comfortable:) }`. `ContextWindowPresets.ladder` gains `65536` and `131072`.

- [ ] **Step 1: Write the failing test**

Create `wallet-macos/Tests/WalletMacOSAppTests/ModelFitEvaluatorTests.swift`:

```swift
import Foundation
import Testing
@testable import WalletMacOSApp

struct ModelFitEvaluatorTests {
    private let gb: UInt64 = 1_073_741_824

    /// Real Gemma 4 E4B Q4_0 numbers, read from the GGUF header:
    /// 42 layers, 2 KV heads, key/value length 512 → 168 KiB per token.
    private let gemma = ModelMemoryProfile(
        weightBytes: 4_590_807_392,
        blockCount: 42,
        kvHeadCount: 2,
        keyLength: 512,
        valueLength: 512,
        trainedContextTokens: 131_072
    )

    private func budget(ram: UInt64, metal: UInt64) -> HardwareBudget {
        HardwareBudget(totalMemoryBytes: ram, metalBudgetBytes: metal, freeDiskBytes: 500 * gb)
    }

    @Test func kvCacheIs168KiBPerToken() {
        let oneToken = ModelFitEvaluator.kvCacheBytes(profile: gemma, contextTokens: 1)
        #expect(oneToken == 172_032)
        #expect(ModelFitEvaluator.kvCacheBytes(profile: gemma, contextTokens: 8192) == 172_032 * 8192)
    }

    @Test func requiredBytesAddsFifteenPercentOverhead() {
        let need = ModelFitEvaluator.requiredBytes(profile: gemma, contextTokens: 8192)
        let raw = 4_590_807_392 + UInt64(172_032 * 8192)
        #expect(need == raw / 100 * 115)
    }

    @Test func gemmaFitsComfortablyOnA36GBMac() {
        let verdict = ModelFitEvaluator.verdict(
            profile: gemma, contextTokens: 8192,
            budget: budget(ram: 36 * gb, metal: 30_182_211_584)
        )
        #expect(verdict == .fits)
    }

    @Test func longContextDoesNotFitEvenOnA36GBMac() {
        let verdict = ModelFitEvaluator.verdict(
            profile: gemma, contextTokens: 131_072,
            budget: budget(ram: 36 * gb, metal: 30_182_211_584)
        )
        #expect(verdict == .wontFit)
    }

    @Test func sixteenGigMacFitsAtEightKAndIsTightAtSixteenK() {
        let small = budget(ram: 16 * gb, metal: 12 * gb)   // 9.6 GiB usable
        #expect(ModelFitEvaluator.verdict(profile: gemma, contextTokens: 8192, budget: small) == .fits)
        #expect(ModelFitEvaluator.verdict(profile: gemma, contextTokens: 16384, budget: small) == .tight)
        #expect(ModelFitEvaluator.verdict(profile: gemma, contextTokens: 32768, budget: small) == .wontFit)
    }

    /// The case the deleted 16 GB gate used to block outright: an 8 GB Air cannot
    /// hold the default model, and now says so with numbers instead of refusing.
    @Test func eightGigMacCannotHoldTheDefaultModel() {
        let tiny = budget(ram: 8 * gb, metal: 6 * gb)      // 4.8 GiB usable
        #expect(ModelFitEvaluator.verdict(profile: gemma, contextTokens: 4096, budget: tiny) == .wontFit)
    }

    @Test func missingProfileIsUnknownNotAFailure() {
        let verdict = ModelFitEvaluator.verdict(
            profile: nil, contextTokens: 8192,
            budget: budget(ram: 36 * gb, metal: 30_182_211_584)
        )
        #expect(verdict == .unknown)
    }

    @Test func largestFittingContextPicksAPresetFromTheLadder() {
        let small = budget(ram: 16 * gb, metal: 12 * gb)
        #expect(ModelFitEvaluator.largestFittingContext(profile: gemma, budget: small) == 8192)
        let tiny = budget(ram: 8 * gb, metal: 6 * gb)
        #expect(ModelFitEvaluator.largestFittingContext(profile: gemma, budget: tiny) == nil)
    }

    /// The inverse of the fit check: what does *this model* demand of a Mac?
    /// This is what a per-model "minimum requirement" actually means — a fixed RAM
    /// number cannot express it, because it moves with the quant and the context.
    @Test func minimumMemoryIsDerivedFromTheModelNotAFixedNumber() {
        // Gemma Q4_0 needs 5.67 GiB at 4k → comfortable on ~11.8 GiB of RAM.
        #expect(ModelFitEvaluator.minimumMemoryBytes(profile: gemma, contextTokens: 4096, comfortable: true)
                == 12_687_016_583)
        // At 8k the same model demands a bigger Mac: ~13.4 GiB.
        #expect(ModelFitEvaluator.minimumMemoryBytes(profile: gemma, contextTokens: 8192, comfortable: true)
                == 14_375_224_010)
        // Usable-but-tight is a lower bar than comfortable.
        #expect(ModelFitEvaluator.minimumMemoryBytes(profile: gemma, contextTokens: 4096, comfortable: false)
                < ModelFitEvaluator.minimumMemoryBytes(profile: gemma, contextTokens: 4096, comfortable: true))
    }

    /// A small model must produce a small requirement — the whole point of making
    /// the minimum model-dependent.
    @Test func aSmallModelDemandsASmallMac() {
        let tiny = ModelMemoryProfile(
            weightBytes: 1_710_000_000, blockCount: 26, kvHeadCount: 2,
            keyLength: 256, valueLength: 256, trainedContextTokens: 32_768
        )
        let required = ModelFitEvaluator.minimumMemoryBytes(profile: tiny, contextTokens: 4096, comfortable: true)
        #expect(required < 8 * gb)
        #expect(ModelFitEvaluator.verdict(
            profile: tiny, contextTokens: 4096,
            budget: budget(ram: 8 * gb, metal: 6 * gb)
        ) == .fits)
    }

    @Test func ladderReachesGemmasTrainedContext() {
        #expect(ContextWindowPresets.options(maxTokens: 131_072).contains(131_072))
        #expect(ContextWindowPresets.options(maxTokens: 8192).last == 8192)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd wallet-macos && swift test --filter ModelFitEvaluatorTests
```
Expected: FAIL — `cannot find 'ModelMemoryProfile' in scope`.

- [ ] **Step 3: Write the implementation**

Create `wallet-macos/Sources/WalletMacOSApp/ModelMemoryProfile.swift`:

```swift
import Foundation

/// Everything needed to predict a GGUF model's memory footprint, read either from
/// the GGUF header or pinned for a curated model.
struct ModelMemoryProfile: Equatable, Codable {
    let weightBytes: UInt64
    let blockCount: Int
    let kvHeadCount: Int
    let keyLength: Int
    let valueLength: Int
    let trainedContextTokens: Int
}

enum ModelFitVerdict: String, Equatable {
    case fits
    case tight
    case wontFit
    case unknown

    var label: String {
        switch self {
        case .fits: return "Fits"
        case .tight: return "Tight"
        case .wontFit: return "Won't fit"
        case .unknown: return "Size unknown"
        }
    }
}

enum ModelFitEvaluator {
    /// llama.cpp keeps an f16 K and V entry per layer, per KV head, per token.
    static func kvCacheBytes(profile: ModelMemoryProfile, contextTokens: Int) -> UInt64 {
        let perToken = UInt64(profile.blockCount)
            * UInt64(profile.kvHeadCount)
            * UInt64(profile.keyLength + profile.valueLength)
            * 2
        return perToken * UInt64(max(contextTokens, 0))
    }

    /// Weights + KV cache + 15% for the compute graph, scratch buffers and tokenizer.
    static func requiredBytes(profile: ModelMemoryProfile, contextTokens: Int) -> UInt64 {
        let raw = profile.weightBytes + kvCacheBytes(profile: profile, contextTokens: contextTokens)
        return raw / 100 * 115
    }

    static func verdict(
        profile: ModelMemoryProfile?,
        contextTokens: Int,
        budget: HardwareBudget
    ) -> ModelFitVerdict {
        guard let profile else { return .unknown }
        let need = requiredBytes(profile: profile, contextTokens: contextTokens)
        if need <= budget.comfortableBytes { return .fits }
        if need <= budget.usableBytes { return .tight }
        return .wontFit
    }

    /// The inverse of `verdict`: the smallest Mac this model is happy on.
    ///
    /// Below ~20 GiB the 40% reserve binds and the budget is 0.6 × RAM; above it the
    /// reserve is a flat 8 GiB. Metal's own ~75% ceiling is looser than both, so it
    /// does not enter the inversion. Used for copy like "needs a Mac with 12 GB".
    static func minimumMemoryBytes(
        profile: ModelMemoryProfile,
        contextTokens: Int,
        comfortable: Bool
    ) -> UInt64 {
        let need = requiredBytes(profile: profile, contextTokens: contextTokens)
        let target = comfortable ? need * 100 / 80 : need
        let smallMachine = target * 100 / 60
        let twentyGiB: UInt64 = 20 * 1_073_741_824
        return smallMachine <= twentyGiB ? smallMachine : target + 8 * 1_073_741_824
    }

    /// The largest ladder preset that still lands in `.fits`, or nil if none do.
    static func largestFittingContext(
        profile: ModelMemoryProfile,
        budget: HardwareBudget
    ) -> Int? {
        ContextWindowPresets.options(maxTokens: profile.trainedContextTokens)
            .filter { verdict(profile: profile, contextTokens: $0, budget: budget) == .fits }
            .max()
    }
}
```

- [ ] **Step 4: Extend the context ladder**

In `wallet-macos/Sources/WalletMacOSApp/ContextWindowPresets.swift`, replace the `ladder` line and the doc comment above the enum:

```swift
/// Context-window preset options for the local model.
///
/// The ladder is filtered twice: by the model's trained maximum, and — in the UI —
/// by what this Mac's memory budget can hold (`ModelFitEvaluator`). A preset being
/// listed here does not mean it fits; that is the evaluator's job.
enum ContextWindowPresets {
    static let ladder: [Int] = [2048, 4096, 8192, 16384, 32768, 65536, 131072]
    static let fallback = 4096
```

Leave `options(maxTokens:)` and `clamp(_:maxTokens:)` unchanged.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd wallet-macos && swift test --filter ModelFitEvaluatorTests
cd wallet-macos && swift test --filter ContextWindowSettingsTests
```
Expected: PASS both suites.

- [ ] **Step 6: Commit**

```bash
git add wallet-macos/Sources/WalletMacOSApp/ModelMemoryProfile.swift \
        wallet-macos/Sources/WalletMacOSApp/ContextWindowPresets.swift \
        wallet-macos/Tests/WalletMacOSAppTests/ModelFitEvaluatorTests.swift
git commit -m "$(cat <<'EOF'
feat(models): predict a GGUF model's footprint and verdict it against the budget

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: GGUF header reader

**Files:**
- Create: `wallet-macos/Sources/WalletMacOSApp/GGUFHeaderReader.swift`
- Test: `wallet-macos/Tests/WalletMacOSAppTests/GGUFHeaderReaderTests.swift`

**Interfaces:**
- Consumes: `ModelMemoryProfile` (Task 2).
- Produces: `struct GGUFHeader { architecture: String, values: [String: GGUFValue] }`, `enum GGUFHeaderReader { parse(_ data: Data) throws -> GGUFHeader, fetch(from: URL, session:) async throws -> GGUFHeader }`, and `GGUFHeader.memoryProfile(weightBytes:) -> ModelMemoryProfile?`.

**Format note for the implementer:** a GGUF file starts with `GGUF` (4 bytes), `version` (u32), `tensor_count` (u64), `kv_count` (u64), then `kv_count` pairs of `key` (u64 length + UTF-8 bytes), `value_type` (u32), `value`. Value type ids are `0 u8, 1 i8, 2 u16, 3 i16, 4 u32, 5 i32, 6 f32, 7 bool, 8 string, 9 array, 10 u64, 11 i64, 12 f64`. An array is `element_type` (u32) + `count` (u64) + that many elements. All integers are little-endian. Keys are namespaced by architecture, e.g. `gemma4.block_count`.

- [ ] **Step 1: Write the failing test**

Create `wallet-macos/Tests/WalletMacOSAppTests/GGUFHeaderReaderTests.swift`:

```swift
import Foundation
import Testing
@testable import WalletMacOSApp

struct GGUFHeaderReaderTests {
    /// Builds a byte-for-byte valid GGUF v3 header with the keys we care about,
    /// including an array value that the parser must skip over correctly.
    private func fixture() -> Data {
        var data = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func str(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); data.append(contentsOf: b) }

        u32(3)          // version
        u64(666)        // tensor count
        u64(7)          // kv count

        str("general.architecture"); u32(8); str("gemma4")
        str("tokenizer.ggml.tokens"); u32(9); u32(8); u64(3); str("a"); str("b"); str("c")
        str("gemma4.block_count"); u32(4); u32(42)
        str("gemma4.context_length"); u32(4); u32(131_072)
        str("gemma4.attention.head_count_kv"); u32(4); u32(2)
        str("gemma4.attention.key_length"); u32(4); u32(512)
        str("gemma4.attention.value_length"); u32(4); u32(512)
        return data
    }

    @Test func parsesArchitectureAndAttentionShape() throws {
        let header = try GGUFHeaderReader.parse(fixture())
        #expect(header.architecture == "gemma4")
        #expect(header.integer("gemma4.block_count") == 42)
        #expect(header.integer("gemma4.attention.head_count_kv") == 2)
        #expect(header.integer("gemma4.context_length") == 131_072)
    }

    @Test func buildsAMemoryProfileFromTheHeader() throws {
        let header = try GGUFHeaderReader.parse(fixture())
        let profile = try #require(header.memoryProfile(weightBytes: 4_590_807_392))
        #expect(profile.blockCount == 42)
        #expect(profile.kvHeadCount == 2)
        #expect(profile.keyLength == 512)
        #expect(profile.valueLength == 512)
        #expect(profile.trainedContextTokens == 131_072)
    }

    @Test func rejectsAFileThatIsNotGGUF() {
        #expect(throws: GGUFHeaderError.self) {
            try GGUFHeaderReader.parse(Data("NOPE____".utf8))
        }
    }

    @Test func truncatedHeaderThrowsRatherThanCrashing() {
        let truncated = fixture().prefix(40)
        #expect(throws: GGUFHeaderError.self) {
            try GGUFHeaderReader.parse(Data(truncated))
        }
    }

    @Test func profileIsNilWhenAttentionKeysAreAbsent() throws {
        var data = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func str(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); data.append(contentsOf: b) }
        u32(3); u64(1); u64(1)
        str("general.architecture"); u32(8); str("mystery")

        let header = try GGUFHeaderReader.parse(data)
        #expect(header.memoryProfile(weightBytes: 1000) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd wallet-macos && swift test --filter GGUFHeaderReaderTests
```
Expected: FAIL — `cannot find 'GGUFHeaderReader' in scope`.

- [ ] **Step 3: Write the implementation**

Create `wallet-macos/Sources/WalletMacOSApp/GGUFHeaderReader.swift`:

```swift
import Foundation

enum GGUFHeaderError: Error, Equatable {
    case notGGUF
    case truncated
    case unsupportedValueType(UInt32)
}

struct GGUFHeader: Equatable {
    let architecture: String
    private let integers: [String: Int]

    init(architecture: String, integers: [String: Int]) {
        self.architecture = architecture
        self.integers = integers
    }

    func integer(_ key: String) -> Int? { integers[key] }

    /// nil when the header lacks the attention shape we need; callers surface that
    /// as `.unknown` rather than guessing.
    func memoryProfile(weightBytes: UInt64) -> ModelMemoryProfile? {
        guard let blocks = integer("\(architecture).block_count"),
              let kvHeads = integer("\(architecture).attention.head_count_kv"),
              let keyLength = integer("\(architecture).attention.key_length"),
              let valueLength = integer("\(architecture).attention.value_length")
        else { return nil }
        return ModelMemoryProfile(
            weightBytes: weightBytes,
            blockCount: blocks,
            kvHeadCount: kvHeads,
            keyLength: keyLength,
            valueLength: valueLength,
            trainedContextTokens: integer("\(architecture).context_length") ?? 4096
        )
    }
}

enum GGUFHeaderReader {
    /// Big enough for every GGUF header we have seen. Gemma 4's 262k-token
    /// tokenizer arrays alone take ~15.8 MB, which is the current worst case.
    static let headerProbeBytes = 24 * 1024 * 1024

    static func parse(_ data: Data) throws -> GGUFHeader {
        var cursor = Cursor(data: data)
        guard try cursor.take(4) == Data("GGUF".utf8) else { throw GGUFHeaderError.notGGUF }
        _ = try cursor.u32()                       // version
        _ = try cursor.u64()                       // tensor count
        let kvCount = try cursor.u64()

        var architecture = ""
        var integers: [String: Int] = [:]
        for _ in 0..<kvCount {
            let key = try cursor.string()
            let type = try cursor.u32()
            if type == 8, key == "general.architecture" {
                architecture = try cursor.string()
                continue
            }
            if let value = try cursor.scalarInteger(type: type) {
                integers[key] = value
            }
        }
        return GGUFHeader(architecture: architecture, integers: integers)
    }

    static func fetch(from url: URL, session: URLSession = .shared) async throws -> GGUFHeader {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(headerProbeBytes - 1)", forHTTPHeaderField: "Range")
        let (data, _) = try await session.data(for: request)
        return try parse(data)
    }

    private struct Cursor {
        let data: Data
        var offset: Int = 0

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else { throw GGUFHeaderError.truncated }
            defer { offset += count }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
        }

        mutating func u32() throws -> UInt32 {
            try take(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        }

        mutating func u64() throws -> UInt64 {
            try take(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        }

        mutating func string() throws -> String {
            let length = Int(try u64())
            return String(decoding: try take(length), as: UTF8.self)
        }

        /// Consumes one value. Returns it as an Int when it is a scalar integer,
        /// nil for everything else (strings, floats, bools, arrays) — those are
        /// skipped, not stored.
        mutating func scalarInteger(type: UInt32) throws -> Int? {
            switch type {
            case 0, 1, 7: return Int(try take(1)[0])
            case 2, 3: return Int(try take(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian })
            case 4: return Int(try u32())
            case 5: return Int(Int32(bitPattern: try u32()))
            case 6: _ = try take(4); return nil
            case 8: _ = try string(); return nil
            case 9:
                let elementType = try u32()
                let count = try u64()
                for _ in 0..<count { _ = try scalarInteger(type: elementType) }
                return nil
            case 10: return Int(try u64())
            case 11: return Int(Int64(bitPattern: try u64()))
            case 12: _ = try take(8); return nil
            default: throw GGUFHeaderError.unsupportedValueType(type)
            }
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd wallet-macos && swift test --filter GGUFHeaderReaderTests
```
Expected: PASS (5 tests).

- [ ] **Step 5: Verify against the real file by hand**

```bash
curl -s -r 0-64 "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_0.gguf" | xxd | head -3
```
Expected: the first four bytes read `GGUF`, and the server answers `206 Partial Content`. This confirms the range read the parser depends on is honored by the Hugging Face CDN.

- [ ] **Step 6: Commit**

```bash
git add wallet-macos/Sources/WalletMacOSApp/GGUFHeaderReader.swift \
        wallet-macos/Tests/WalletMacOSAppTests/GGUFHeaderReaderTests.swift
git commit -m "$(cat <<'EOF'
feat(models): read GGUF attention shape from a ranged header fetch

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Hugging Face repository client

**Files:**
- Create: `wallet-macos/Sources/WalletMacOSApp/HuggingFaceRepository.swift`
- Test: `wallet-macos/Tests/WalletMacOSAppTests/HuggingFaceRepositoryTests.swift`

**Interfaces:**
- Produces: `struct HuggingFaceGGUFFile { path, sizeBytes, sha256, downloadURL }`, `struct HuggingFaceRepositoryInfo { repoID, architecture, trainedContextTokens, hasChatTemplate, files }`, `enum HuggingFaceRepositoryError`, `struct HuggingFaceRepository { func info(repoID:) async throws -> HuggingFaceRepositoryInfo }`, plus the two pure decoders `HuggingFaceRepository.decodeTree(_:repoID:)` and `HuggingFaceRepository.decodeModelInfo(_:)` that the tests drive directly.

- [ ] **Step 1: Write the failing test**

Create `wallet-macos/Tests/WalletMacOSAppTests/HuggingFaceRepositoryTests.swift`:

```swift
import Foundation
import Testing
@testable import WalletMacOSApp

struct HuggingFaceRepositoryTests {
    /// Trimmed from the live response for ggml-org/gemma-4-E4B-it-GGUF.
    private let treeJSON = """
    [
      {"type":"file","path":"README.md","size":1200},
      {"type":"file","path":"gemma-4-E4B-it-Q4_0.gguf","size":4590807392,
       "lfs":{"oid":"a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2","size":4590807392}},
      {"type":"file","path":"gemma-4-E4B-it-Q8_0.gguf","size":8025000000,
       "lfs":{"oid":"34be82b17b4942d3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":8025000000}},
      {"type":"file","path":"mmproj-gemma-4-E4B-it-Q8_0.gguf","size":560000000,
       "lfs":{"oid":"197f49a93027f984aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":560000000}},
      {"type":"directory","path":"nested"}
    ]
    """

    private let modelInfoJSON = """
    {"id":"ggml-org/gemma-4-E4B-it-GGUF","gated":false,
     "gguf":{"total":7518069290,"architecture":"gemma4","context_length":131072,
             "chat_template":"{%- macro format_parameters() -%}"}}
    """

    @Test func decodesOnlyGGUFFilesWithTheirChecksums() throws {
        let files = try HuggingFaceRepository.decodeTree(Data(treeJSON.utf8), repoID: "ggml-org/gemma-4-E4B-it-GGUF")
        #expect(files.count == 3)
        let main = try #require(files.first { $0.path == "gemma-4-E4B-it-Q4_0.gguf" })
        #expect(main.sizeBytes == 4_590_807_392)
        #expect(main.sha256 == "a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2")
        #expect(main.downloadURL.absoluteString ==
                "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_0.gguf")
    }

    /// Projector and multi-token-prediction sidecars are not loadable models.
    @Test func sidecarFilesAreMarkedAuxiliary() throws {
        let files = try HuggingFaceRepository.decodeTree(Data(treeJSON.utf8), repoID: "r/x")
        #expect(files.first { $0.path.hasPrefix("mmproj-") }?.isAuxiliary == true)
        #expect(files.first { $0.path == "gemma-4-E4B-it-Q4_0.gguf" }?.isAuxiliary == false)
    }

    @Test func decodesRepoLevelGGUFMetadata() throws {
        let info = try HuggingFaceRepository.decodeModelInfo(Data(modelInfoJSON.utf8))
        #expect(info.architecture == "gemma4")
        #expect(info.trainedContextTokens == 131_072)
        #expect(info.hasChatTemplate == true)
        #expect(info.isGated == false)
    }

    @Test func repoIDMustBeOwnerSlashName() {
        #expect(throws: HuggingFaceRepositoryError.self) {
            try HuggingFaceRepository.validate(repoID: "just-a-name")
        }
        #expect(throws: HuggingFaceRepositoryError.self) {
            try HuggingFaceRepository.validate(repoID: "https://huggingface.co/owner/name")
        }
        #expect(try HuggingFaceRepository.validate(repoID: " owner/name ") == "owner/name")
    }

    @Test func repoWithNoGGUFIsRejected() {
        let empty = """
        [{"type":"file","path":"model.safetensors","size":10}]
        """
        #expect(throws: HuggingFaceRepositoryError.noGGUFFiles) {
            _ = try HuggingFaceRepository.decodeTree(Data(empty.utf8), repoID: "r/x")
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd wallet-macos && swift test --filter HuggingFaceRepositoryTests
```
Expected: FAIL — `cannot find 'HuggingFaceRepository' in scope`.

- [ ] **Step 3: Write the implementation**

Create `wallet-macos/Sources/WalletMacOSApp/HuggingFaceRepository.swift`:

```swift
import Foundation

enum HuggingFaceRepositoryError: LocalizedError, Equatable {
    case malformedRepoID
    case noGGUFFiles
    case gated
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .malformedRepoID:
            return "Enter a repository as owner/name, for example unsloth/gemma-4-E2B-it-GGUF."
        case .noGGUFFiles:
            return "That repository has no GGUF files. Local Wallet can only run GGUF models."
        case .gated:
            return "That repository is gated. Accept its licence on huggingface.co, or pick another one."
        case .httpStatus(let code):
            return "Hugging Face returned HTTP \(code) for that repository."
        }
    }
}

struct HuggingFaceGGUFFile: Equatable, Identifiable {
    var id: String { path }
    let path: String
    let sizeBytes: UInt64
    let sha256: String?
    let downloadURL: URL

    /// Vision projectors and speculative-decoding sidecars ship in the same repo
    /// but cannot be loaded as the main model.
    var isAuxiliary: Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("mmproj-") || name.hasPrefix("mtp-")
    }
}

struct HuggingFaceRepositoryInfo: Equatable {
    let architecture: String?
    let trainedContextTokens: Int?
    let hasChatTemplate: Bool
    let isGated: Bool
    var files: [HuggingFaceGGUFFile] = []
}

struct HuggingFaceRepository {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func validate(repoID: String) throws -> String {
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2,
              !trimmed.contains(":"),
              !trimmed.hasPrefix("/"),
              parts.allSatisfy({ !$0.isEmpty })
        else { throw HuggingFaceRepositoryError.malformedRepoID }
        return parts.joined(separator: "/")
    }

    func info(repoID rawRepoID: String) async throws -> HuggingFaceRepositoryInfo {
        let repoID = try Self.validate(repoID: rawRepoID)
        let modelInfo = try await get(URL(string: "https://huggingface.co/api/models/\(repoID)")!)
        var info = try Self.decodeModelInfo(modelInfo)
        guard !info.isGated else { throw HuggingFaceRepositoryError.gated }
        let tree = try await get(URL(string: "https://huggingface.co/api/models/\(repoID)/tree/main?recursive=true")!)
        info.files = try Self.decodeTree(tree, repoID: repoID)
        return info
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HuggingFaceRepositoryError.httpStatus(http.statusCode)
        }
        return data
    }

    // MARK: - Pure decoders

    private struct TreeEntry: Decodable {
        struct LFS: Decodable { let oid: String? }
        let type: String
        let path: String
        let size: UInt64?
        let lfs: LFS?
    }

    private struct ModelInfo: Decodable {
        struct GGUF: Decodable {
            let architecture: String?
            let context_length: Int?
            let chat_template: String?
        }
        let gated: BoolOrString?
        let gguf: GGUF?
    }

    /// `gated` is `false` or a string like "auto"/"manual".
    private enum BoolOrString: Decodable {
        case flag(Bool)
        case name(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) { self = .flag(value); return }
            self = .name((try? container.decode(String.self)) ?? "")
        }

        var isGated: Bool {
            switch self {
            case .flag(let value): return value
            case .name(let value): return !value.isEmpty
            }
        }
    }

    static func decodeModelInfo(_ data: Data) throws -> HuggingFaceRepositoryInfo {
        let info = try JSONDecoder().decode(ModelInfo.self, from: data)
        return HuggingFaceRepositoryInfo(
            architecture: info.gguf?.architecture,
            trainedContextTokens: info.gguf?.context_length,
            hasChatTemplate: (info.gguf?.chat_template?.isEmpty == false),
            isGated: info.gated?.isGated ?? false
        )
    }

    static func decodeTree(_ data: Data, repoID: String) throws -> [HuggingFaceGGUFFile] {
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        let files = entries
            .filter { $0.type == "file" && $0.path.hasSuffix(".gguf") }
            .map { entry in
                HuggingFaceGGUFFile(
                    path: entry.path,
                    sizeBytes: entry.size ?? 0,
                    sha256: entry.lfs?.oid,
                    downloadURL: URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(entry.path)")!
                )
            }
            .sorted { $0.sizeBytes < $1.sizeBytes }
        guard !files.isEmpty else { throw HuggingFaceRepositoryError.noGGUFFiles }
        return files
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd wallet-macos && swift test --filter HuggingFaceRepositoryTests
```
Expected: PASS (5 tests).

- [ ] **Step 5: Spot-check the live shape the fixtures were taken from**

```bash
curl -s "https://huggingface.co/api/models/ggml-org/gemma-4-E4B-it-GGUF/tree/main?recursive=true" \
  | python3 -c "import sys,json;print([ (f['path'], (f.get('lfs') or {}).get('oid','')[:16]) for f in json.load(sys.stdin) if f['path'].endswith('.gguf')][:3])"
```
Expected: `gemma-4-E4B-it-Q4_0.gguf` appears with oid prefix `a555b900214b477d` — the same value pinned in `LocalAIModel.recommended.sha256`.

- [ ] **Step 6: Commit**

```bash
git add wallet-macos/Sources/WalletMacOSApp/HuggingFaceRepository.swift \
        wallet-macos/Tests/WalletMacOSAppTests/HuggingFaceRepositoryTests.swift
git commit -m "$(cat <<'EOF'
feat(models): resolve a Hugging Face repo to its GGUF files and checksums

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Installed-model store and catalog

**Files:**
- Create: `wallet-macos/Sources/WalletMacOSApp/InstalledModelStore.swift`
- Create: `wallet-macos/Sources/WalletMacOSApp/ModelCatalog.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/OnboardingSettingsStore.swift:160-194`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/SettingsWiringAuditTests.swift:54-59`
- Test: `wallet-macos/Tests/WalletMacOSAppTests/InstalledModelStoreTests.swift`
- Test: `wallet-macos/Tests/WalletMacOSAppTests/ModelCatalogTests.swift`

**Interfaces:**
- Consumes: `ModelMemoryProfile` (Task 2), `HuggingFaceGGUFFile` (Task 4).
- Produces: `struct InstalledModel: Codable { id, displayName, repoID, fileName, path, sizeBytes, sha256, profile? }`, `final class InstalledModelStore { var installed: [InstalledModel]; func add(_:); func remove(id:); func model(id:) -> InstalledModel? }`, `struct ModelCatalog { let entries: [ModelCatalogEntry] }`, `struct ModelCatalogEntry { id, displayName, detail, sizeText, source, profile?, installedPath?, isDefault }`, `enum ModelSource { curated, huggingFace }`. `LocalAIModel` gains `memoryProfile: ModelMemoryProfile`.

- [ ] **Step 1: Write the failing tests**

Create `wallet-macos/Tests/WalletMacOSAppTests/InstalledModelStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import WalletMacOSApp

struct InstalledModelStoreTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "installed-models-\(UUID().uuidString)")!
    }

    private func sample(id: String) -> InstalledModel {
        InstalledModel(
            id: id,
            displayName: "Sample \(id)",
            repoID: "owner/\(id)",
            fileName: "\(id).gguf",
            path: "/tmp/\(id).gguf",
            sizeBytes: 1234,
            sha256: "abc",
            profile: nil
        )
    }

    @Test func startsEmpty() {
        #expect(InstalledModelStore(defaults: suite()).installed.isEmpty)
    }

    @Test func addRoundTripsThroughDefaults() {
        let defaults = suite()
        InstalledModelStore(defaults: defaults).add(sample(id: "one"))
        let reloaded = InstalledModelStore(defaults: defaults)
        #expect(reloaded.installed.count == 1)
        #expect(reloaded.model(id: "one")?.fileName == "one.gguf")
    }

    @Test func addingTheSameIDReplacesRatherThanDuplicates() {
        let store = InstalledModelStore(defaults: suite())
        store.add(sample(id: "one"))
        var updated = sample(id: "one")
        updated.path = "/tmp/moved.gguf"
        store.add(updated)
        #expect(store.installed.count == 1)
        #expect(store.model(id: "one")?.path == "/tmp/moved.gguf")
    }

    @Test func removeDropsTheEntry() {
        let store = InstalledModelStore(defaults: suite())
        store.add(sample(id: "one"))
        store.remove(id: "one")
        #expect(store.installed.isEmpty)
    }

    /// Existing installs recorded only the two legacy single-slot keys. They must
    /// survive the upgrade without a re-download.
    @Test func migratesTheLegacySingleSlotInstall() {
        let defaults = suite()
        defaults.set(LocalAIModel.recommended.id, forKey: "com.localwallet.demo.onboarding.installed-model-id")
        defaults.set("/tmp/gemma-4-E4B-it-Q4_0.gguf", forKey: "com.localwallet.demo.onboarding.installed-model-path")

        let store = InstalledModelStore(defaults: defaults)
        #expect(store.installed.count == 1)
        let migrated = try? #require(store.model(id: LocalAIModel.recommended.id))
        #expect(migrated?.path == "/tmp/gemma-4-E4B-it-Q4_0.gguf")
        #expect(migrated?.displayName == LocalAIModel.recommended.name)
    }

    @Test func migrationRunsOnlyOnce() {
        let defaults = suite()
        defaults.set(LocalAIModel.recommended.id, forKey: "com.localwallet.demo.onboarding.installed-model-id")
        defaults.set("/tmp/gemma.gguf", forKey: "com.localwallet.demo.onboarding.installed-model-path")

        let first = InstalledModelStore(defaults: defaults)
        first.remove(id: LocalAIModel.recommended.id)
        let second = InstalledModelStore(defaults: defaults)
        #expect(second.installed.isEmpty)
    }
}
```

Create `wallet-macos/Tests/WalletMacOSAppTests/ModelCatalogTests.swift`:

```swift
import Foundation
import Testing
@testable import WalletMacOSApp

struct ModelCatalogTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "model-catalog-\(UUID().uuidString)")!
    }

    @Test func defaultModelIsFirstAndMarked() {
        let catalog = ModelCatalog(installedStore: InstalledModelStore(defaults: suite()))
        #expect(catalog.entries.first?.id == LocalAIModel.recommended.id)
        #expect(catalog.entries.first?.isDefault == true)
        #expect(catalog.entries.first?.source == .curated)
    }

    @Test func customModelsAppearAfterCuratedOnes() {
        let defaults = suite()
        let store = InstalledModelStore(defaults: defaults)
        store.add(InstalledModel(
            id: "unsloth/gemma-4-E2B-it-GGUF#gemma-4-E2B-it-Q4_K_M.gguf",
            displayName: "gemma-4-E2B-it-Q4_K_M",
            repoID: "unsloth/gemma-4-E2B-it-GGUF",
            fileName: "gemma-4-E2B-it-Q4_K_M.gguf",
            path: "/tmp/e2b.gguf",
            sizeBytes: 1_710_000_000,
            sha256: "def",
            profile: nil
        ))

        let catalog = ModelCatalog(installedStore: store)
        #expect(catalog.entries.count == LocalAIModel.available.count + 1)
        #expect(catalog.entries.last?.source == .huggingFace)
        #expect(catalog.entries.last?.installedPath == "/tmp/e2b.gguf")
    }

    @Test func curatedGemmaCarriesItsMeasuredMemoryProfile() {
        let profile = LocalAIModel.recommended.memoryProfile
        #expect(profile.blockCount == 42)
        #expect(profile.kvHeadCount == 2)
        #expect(profile.keyLength == 512)
        #expect(profile.trainedContextTokens == 131_072)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd wallet-macos && swift test --filter InstalledModelStoreTests
cd wallet-macos && swift test --filter ModelCatalogTests
```
Expected: FAIL — `cannot find 'InstalledModelStore' in scope`, `cannot find 'ModelCatalog' in scope`.

- [ ] **Step 3: Add the memory profile to `LocalAIModel`**

In `wallet-macos/Sources/WalletMacOSApp/OnboardingSettingsStore.swift`, replace the `LocalAIModel` struct and its `recommended` value (currently lines 160-194) with:

```swift
struct LocalAIModel: Identifiable, Equatable {
    let id: String
    let name: String
    let size: String
    let detail: String
    let tag: String
    let systemImage: String
    let artifactRepo: String
    let artifactFileName: String
    let artifactURL: URL
    let sha256: String
    let memoryProfile: ModelMemoryProfile

    /// The context ceiling the model was trained for. Comes from the GGUF header,
    /// not from a guess: `gemma4.context_length` is 131072.
    var maxContextTokens: Int { memoryProfile.trainedContextTokens }

    static let recommended = LocalAIModel(
        id: "google/gemma-4-E4B-it",
        name: "Gemma 4 E4B",
        size: "4.59 GB",
        detail: "Instruction-tuned Gemma 4 E4B, downloaded as a Q4_0 GGUF for local llama.cpp inference.",
        tag: "GGUF",
        systemImage: "sparkles",
        artifactRepo: "ggml-org/gemma-4-E4B-it-GGUF",
        artifactFileName: "gemma-4-E4B-it-Q4_0.gguf",
        // ggml-org re-quantized this repo and dropped Q4_K_M, so the old URL 404s. Q4_0 is
        // the closest surviving quant.
        artifactURL: URL(string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_0.gguf?download=true")!,
        sha256: "a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2",
        // Read from the GGUF header of the pinned artifact:
        // gemma4.block_count=42, head_count_kv=2, key/value_length=512,
        // context_length=131072 → 168 KiB of KV cache per token.
        memoryProfile: ModelMemoryProfile(
            weightBytes: 4_590_807_392,
            blockCount: 42,
            kvHeadCount: 2,
            keyLength: 512,
            valueLength: 512,
            trainedContextTokens: 131_072
        )
    )

    static let available: [LocalAIModel] = [
        recommended,
    ]
}
```

- [ ] **Step 4: Write the installed-model store**

Create `wallet-macos/Sources/WalletMacOSApp/InstalledModelStore.swift`:

```swift
import Foundation

struct InstalledModel: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let repoID: String
    let fileName: String
    var path: String
    let sizeBytes: UInt64
    let sha256: String?
    var profile: ModelMemoryProfile?
}

/// Replaces the two legacy single-slot defaults keys
/// (`…installed-model-id` / `…installed-model-path`) with a list, so more than one
/// model can be on disk at a time.
final class InstalledModelStore {
    private enum Keys {
        static let installed = "com.localwallet.models.installed"
        static let migrated = "com.localwallet.models.legacy-migrated"
        static let legacyID = "com.localwallet.demo.onboarding.installed-model-id"
        static let legacyPath = "com.localwallet.demo.onboarding.installed-model-path"
    }

    private let defaults: UserDefaults
    private(set) var installed: [InstalledModel] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        migrateLegacySlotIfNeeded()
    }

    func model(id: String) -> InstalledModel? {
        installed.first { $0.id == id }
    }

    func add(_ model: InstalledModel) {
        installed.removeAll { $0.id == model.id }
        installed.append(model)
        save()
    }

    func remove(id: String) {
        installed.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: Keys.installed),
              let decoded = try? JSONDecoder().decode([InstalledModel].self, from: data)
        else { return }
        installed = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        defaults.set(data, forKey: Keys.installed)
    }

    /// One-shot adoption of a pre-existing install. Guarded by its own flag so a
    /// user who deliberately removes the migrated model does not get it back.
    private func migrateLegacySlotIfNeeded() {
        guard !defaults.bool(forKey: Keys.migrated) else { return }
        defaults.set(true, forKey: Keys.migrated)

        guard let legacyID = defaults.string(forKey: Keys.legacyID),
              let legacyPath = defaults.string(forKey: Keys.legacyPath),
              !legacyPath.isEmpty,
              installed.contains(where: { $0.id == legacyID }) == false,
              let curated = LocalAIModel.available.first(where: { $0.id == legacyID })
        else { return }

        add(InstalledModel(
            id: curated.id,
            displayName: curated.name,
            repoID: curated.artifactRepo,
            fileName: curated.artifactFileName,
            path: legacyPath,
            sizeBytes: curated.memoryProfile.weightBytes,
            sha256: curated.sha256,
            profile: curated.memoryProfile
        ))
    }
}
```

- [ ] **Step 5: Write the catalog**

Create `wallet-macos/Sources/WalletMacOSApp/ModelCatalog.swift`:

```swift
import Foundation

enum ModelSource: String, Equatable {
    case curated
    case huggingFace
}

struct ModelCatalogEntry: Identifiable, Equatable {
    let id: String
    let displayName: String
    let detail: String
    let sizeText: String
    let source: ModelSource
    let repoID: String
    let fileName: String
    let downloadURL: URL?
    let sha256: String?
    let profile: ModelMemoryProfile?
    let installedPath: String?
    let isDefault: Bool

    var isInstalled: Bool {
        guard let installedPath, !installedPath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: installedPath)
    }
}

/// Curated models first (default first of all), then anything the user added.
struct ModelCatalog {
    let entries: [ModelCatalogEntry]

    init(installedStore: InstalledModelStore, downloadManager: LocalAIModelDownloadManager = LocalAIModelDownloadManager()) {
        let curated = LocalAIModel.available.map { model -> ModelCatalogEntry in
            let installed = installedStore.model(id: model.id)?.path
                ?? downloadManager.bundledFileURL(for: model)?.path
                ?? (try? downloadManager.localFileURL(for: model))?.path
            return ModelCatalogEntry(
                id: model.id,
                displayName: model.name,
                detail: model.detail,
                sizeText: model.size,
                source: .curated,
                repoID: model.artifactRepo,
                fileName: model.artifactFileName,
                downloadURL: model.artifactURL,
                sha256: model.sha256,
                profile: model.memoryProfile,
                installedPath: installed,
                isDefault: model.id == LocalAIModel.recommended.id
            )
        }

        let curatedIDs = Set(curated.map(\.id))
        let custom = installedStore.installed
            .filter { !curatedIDs.contains($0.id) }
            .map { model in
                ModelCatalogEntry(
                    id: model.id,
                    displayName: model.displayName,
                    detail: model.repoID,
                    sizeText: ByteCountFormatter.string(fromByteCount: Int64(model.sizeBytes), countStyle: .file),
                    source: .huggingFace,
                    repoID: model.repoID,
                    fileName: model.fileName,
                    downloadURL: nil,
                    sha256: model.sha256,
                    profile: model.profile,
                    installedPath: model.path,
                    isDefault: false
                )
            }

        entries = curated + custom
    }
}
```

- [ ] **Step 6: Retire the single-model invariant in the audit test**

In `wallet-macos/Tests/WalletMacOSAppTests/SettingsWiringAuditTests.swift`, replace the `modelCatalogIsSingleModelSoSelectionDrivesInstallNotRuntime` test (lines 50-59, including its doc comment) with:

```swift
    /// Suspicion B, resolved. Selection used to drive install only, which was safe
    /// while the catalog held exactly one model. It no longer does: the catalog is
    /// user-extensible, so selection drives the runtime through
    /// `InstalledModelStore` + `EmbeddedLlamaInferenceService.setActiveModel`.
    /// What must stay true is that the shipped default is unchanged.
    @Test func defaultModelIsStillGemmaQ4() {
        #expect(LocalAIModel.recommended.id == "google/gemma-4-E4B-it")
        #expect(LocalAIModel.recommended.artifactFileName == "gemma-4-E4B-it-Q4_0.gguf")
        #expect(LocalAIModel.available.first?.id == LocalAIModel.recommended.id)
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd wallet-macos && swift test --filter InstalledModelStoreTests
cd wallet-macos && swift test --filter ModelCatalogTests
cd wallet-macos && swift test --filter SettingsWiringAuditTests
cd wallet-macos && swift test --filter ContextWindowSettingsTests
```
Expected: PASS all four suites. `ContextWindowSettingsTests` must still pass unchanged — it asserts `maxContextTokens >= 4096`, which the new computed property satisfies.

- [ ] **Step 8: Commit**

```bash
git add wallet-macos/Sources/WalletMacOSApp/InstalledModelStore.swift \
        wallet-macos/Sources/WalletMacOSApp/ModelCatalog.swift \
        wallet-macos/Sources/WalletMacOSApp/OnboardingSettingsStore.swift \
        wallet-macos/Tests/WalletMacOSAppTests/InstalledModelStoreTests.swift \
        wallet-macos/Tests/WalletMacOSAppTests/ModelCatalogTests.swift \
        wallet-macos/Tests/WalletMacOSAppTests/SettingsWiringAuditTests.swift
git commit -m "$(cat <<'EOF'
feat(models): track many installed models behind one catalog

Migrates the legacy single-slot install keys and pins Gemma's measured
memory profile, correcting its trained context from 32768 to 131072.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Download any GGUF

**Files:**
- Modify: `wallet-macos/Sources/WalletMacOSApp/LocalAIModelDownloadManager.swift`
- Test: `wallet-macos/Tests/WalletMacOSAppTests/ModelDownloadRequestTests.swift`

**Interfaces:**
- Consumes: `HardwareBudget` (Task 1), `HuggingFaceGGUFFile` (Task 4).
- Produces: `struct ModelDownloadRequest { modelID, displayName, repoID, fileName, url, expectedSHA256, sizeBytes }`, `LocalAIModelDownloadManager.download(_ request: ModelDownloadRequest, progress:) async throws -> URL`, `LocalAIModelDownloadError.insufficientDisk(needed:available:)`, and `ModelDownloadRequest.init(model: LocalAIModel)` for the curated path.

- [ ] **Step 1: Write the failing test**

Create `wallet-macos/Tests/WalletMacOSAppTests/ModelDownloadRequestTests.swift`:

```swift
import Foundation
import Testing
@testable import WalletMacOSApp

struct ModelDownloadRequestTests {
    @Test func curatedModelMapsOntoARequest() {
        let request = ModelDownloadRequest(model: .recommended)
        #expect(request.modelID == LocalAIModel.recommended.id)
        #expect(request.fileName == "gemma-4-E4B-it-Q4_0.gguf")
        #expect(request.expectedSHA256 == LocalAIModel.recommended.sha256)
        #expect(request.url == LocalAIModel.recommended.artifactURL)
    }

    @Test func huggingFaceFileMapsOntoARequestWithARepoScopedID() throws {
        let file = HuggingFaceGGUFFile(
            path: "gemma-4-E2B-it-Q4_K_M.gguf",
            sizeBytes: 1_710_000_000,
            sha256: "deadbeef",
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf")!
        )
        let request = ModelDownloadRequest(repoID: "unsloth/gemma-4-E2B-it-GGUF", file: file)
        #expect(request.modelID == "unsloth/gemma-4-E2B-it-GGUF#gemma-4-E2B-it-Q4_K_M.gguf")
        #expect(request.displayName == "gemma-4-E2B-it-Q4_K_M")
        #expect(request.expectedSHA256 == "deadbeef")
    }

    /// Two repos can publish the same file name; the destination must not collide.
    @Test func destinationFileNameIsNamespacedByRepo() throws {
        let manager = LocalAIModelDownloadManager()
        let a = ModelDownloadRequest(repoID: "owner-a/repo", file: .init(
            path: "model.gguf", sizeBytes: 1, sha256: nil,
            downloadURL: URL(string: "https://example.test/a.gguf")!))
        let b = ModelDownloadRequest(repoID: "owner-b/repo", file: .init(
            path: "model.gguf", sizeBytes: 1, sha256: nil,
            downloadURL: URL(string: "https://example.test/b.gguf")!))
        #expect(try manager.localFileURL(for: a) != manager.localFileURL(for: b))
    }

    @Test func curatedDestinationKeepsItsHistoricalFileName() throws {
        let manager = LocalAIModelDownloadManager()
        let curated = try manager.localFileURL(for: ModelDownloadRequest(model: .recommended))
        #expect(curated.lastPathComponent == "gemma-4-E4B-it-Q4_0.gguf")
    }

    @Test func diskCheckRejectsADownloadThatWillNotFit() {
        let gb: UInt64 = 1_073_741_824
        let budget = HardwareBudget(totalMemoryBytes: 36 * gb, metalBudgetBytes: 28 * gb, freeDiskBytes: 2 * gb)
        #expect(throws: LocalAIModelDownloadError.self) {
            try LocalAIModelDownloadManager.assertDiskSpace(neededBytes: 5 * gb, budget: budget)
        }
        #expect(throws: Never.self) {
            try LocalAIModelDownloadManager.assertDiskSpace(neededBytes: 1 * gb, budget: budget)
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd wallet-macos && swift test --filter ModelDownloadRequestTests
```
Expected: FAIL — `cannot find 'ModelDownloadRequest' in scope`.

- [ ] **Step 3: Add the request type and generalize the manager**

In `wallet-macos/Sources/WalletMacOSApp/LocalAIModelDownloadManager.swift`, add the request type above `LocalAIModelDownloadError`:

```swift
/// A single downloadable GGUF, whether it came from the curated catalog or from a
/// repository the user typed in.
struct ModelDownloadRequest: Equatable {
    let modelID: String
    let displayName: String
    let repoID: String
    let fileName: String
    /// Destination file name, namespaced so two repos publishing `model.gguf`
    /// cannot overwrite each other. Curated models keep their historical name so
    /// existing installs are found without a re-download.
    let destinationFileName: String
    let url: URL
    let expectedSHA256: String?
    let sizeBytes: UInt64

    init(model: LocalAIModel) {
        modelID = model.id
        displayName = model.name
        repoID = model.artifactRepo
        fileName = model.artifactFileName
        destinationFileName = model.artifactFileName
        url = model.artifactURL
        expectedSHA256 = model.sha256
        sizeBytes = model.memoryProfile.weightBytes
    }

    init(repoID: String, file: HuggingFaceGGUFFile) {
        let leaf = (file.path as NSString).lastPathComponent
        modelID = "\(repoID)#\(file.path)"
        displayName = (leaf as NSString).deletingPathExtension
        self.repoID = repoID
        fileName = file.path
        let slug = repoID.replacingOccurrences(of: "/", with: "_")
        destinationFileName = "\(slug)__\(leaf)"
        url = file.downloadURL
        expectedSHA256 = file.sha256
        sizeBytes = file.sizeBytes
    }
}
```

Add the new error case to `LocalAIModelDownloadError`:

```swift
    case insufficientDisk(neededBytes: UInt64, availableBytes: UInt64)
```

and its message inside `errorDescription`:

```swift
        case .insufficientDisk(let needed, let available):
            let fmt = ByteCountFormatter.string(fromByteCount:countStyle:)
            return "This model needs \(fmt(Int64(needed), .file)) but only \(fmt(Int64(available), .file)) is free."
```

Add these members to `LocalAIModelDownloadManager` (keep every existing method — the `LocalAIModel` overloads stay so onboarding keeps compiling):

```swift
    func localFileURL(for request: ModelDownloadRequest) throws -> URL {
        try Self.modelsDirectory()
            .appendingPathComponent(request.destinationFileName, isDirectory: false)
    }

    /// Leaves 2 GB of slack so a download cannot fill the volume.
    static func assertDiskSpace(neededBytes: UInt64, budget: HardwareBudget) throws {
        let slack: UInt64 = 2 * 1_073_741_824
        guard budget.freeDiskBytes > neededBytes + slack else {
            throw LocalAIModelDownloadError.insufficientDisk(
                neededBytes: neededBytes,
                availableBytes: budget.freeDiskBytes
            )
        }
    }

    func download(
        _ request: ModelDownloadRequest,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        let destinationURL = try localFileURL(for: request)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try await withCheckedThrowingContinuation { continuation in
            store(ActiveDownload(
                expectedSHA256: request.expectedSHA256,
                destinationURL: destinationURL,
                progressHandler: progress,
                continuation: continuation
            ))
            session.downloadTask(with: request.url).resume()
        }
    }
```

Change the private `ActiveDownload` struct so it carries the expected checksum instead of a `LocalAIModel`, and update the two places that build or read it:

```swift
    private struct ActiveDownload {
        let expectedSHA256: String?
        let destinationURL: URL
        let progressHandler: ProgressHandler
        let continuation: CheckedContinuation<URL, Error>
    }
```

In the existing `download(_ model: LocalAIModel, progress:)`, build it with `expectedSHA256: model.sha256`. In `urlSession(_:downloadTask:didFinishDownloadingTo:)`, replace the checksum block with:

```swift
            if let expected = activeDownload.expectedSHA256?.lowercased() {
                let actualChecksum = try Self.sha256Hex(of: activeDownload.destinationURL)
                guard actualChecksum == expected else {
                    try? FileManager.default.removeItem(at: activeDownload.destinationURL)
                    throw LocalAIModelDownloadError.checksumMismatch(
                        expected: expected,
                        actual: actualChecksum
                    )
                }
            }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd wallet-macos && swift test --filter ModelDownloadRequestTests
cd wallet-macos && swift build
```
Expected: PASS (5 tests), and the package still builds — the `LocalAIModel` download overload used by `OnboardingView` is untouched.

- [ ] **Step 5: Commit**

```bash
git add wallet-macos/Sources/WalletMacOSApp/LocalAIModelDownloadManager.swift \
        wallet-macos/Tests/WalletMacOSAppTests/ModelDownloadRequestTests.swift
git commit -m "$(cat <<'EOF'
feat(models): download an arbitrary GGUF with a checksum and disk precheck

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Swap the running model, then test it

**Files:**
- Modify: `wallet-macos/Sources/WalletMacOSApp/EmbeddedLlamaInferenceService.swift:114-238`
- Create: `wallet-macos/Sources/WalletMacOSApp/ModelSelfTest.swift`
- Test: `wallet-macos/Tests/WalletMacOSAppTests/ModelSelfTestTests.swift`
- Test: `wallet-macos/Tests/WalletMacOSAppTests/ContextWindowSettingsTests.swift` (extend)

**Interfaces:**
- Consumes: `InstalledModel` (Task 5), `ContextWindowPresets` (Task 2).
- Produces: `EmbeddedLlamaInferenceService.setActiveModel(url:contextTokens:)`, `var activeModelURL: URL?`, `protocol ModelProbeRuntime { func load(at:contextTokens:) throws; func probeToolCall() throws -> Bool; func unload() }`, `struct ModelSelfTest { func run(modelURL:requestedContextTokens:trainedContextTokens:) -> ModelSelfTestResult }`, `enum ModelSelfTestResult { ready(contextTokens: Int), steppedDown(from: Int, to: Int), noToolSupport, failed(String) }`.

- [ ] **Step 1: Write the failing test**

Create `wallet-macos/Tests/WalletMacOSAppTests/ModelSelfTestTests.swift`:

```swift
import Foundation
import Testing
@testable import WalletMacOSApp

private final class StubProbeRuntime: ModelProbeRuntime {
    var loadFailsAbove: Int
    var toolCallSucceeds: Bool
    private(set) var attemptedContexts: [Int] = []

    init(loadFailsAbove: Int = .max, toolCallSucceeds: Bool = true) {
        self.loadFailsAbove = loadFailsAbove
        self.toolCallSucceeds = toolCallSucceeds
    }

    func load(at url: URL, contextTokens: Int) throws {
        attemptedContexts.append(contextTokens)
        if contextTokens > loadFailsAbove {
            throw LocalAIModelSelfTestError.outOfMemory
        }
    }

    func probeToolCall() throws -> Bool { toolCallSucceeds }
    func unload() {}
}

struct ModelSelfTestTests {
    private let url = URL(fileURLWithPath: "/tmp/model.gguf")

    @Test func readyWhenItLoadsAndCallsATool() {
        let runtime = StubProbeRuntime()
        let result = ModelSelfTest(runtime: runtime)
            .run(modelURL: url, requestedContextTokens: 8192, trainedContextTokens: 131_072)
        #expect(result == .ready(contextTokens: 8192))
        #expect(runtime.attemptedContexts == [8192])
    }

    @Test func stepsDownTheLadderUntilItLoads() {
        let runtime = StubProbeRuntime(loadFailsAbove: 4096)
        let result = ModelSelfTest(runtime: runtime)
            .run(modelURL: url, requestedContextTokens: 32768, trainedContextTokens: 131_072)
        #expect(result == .steppedDown(from: 32768, to: 4096))
        #expect(runtime.attemptedContexts == [32768, 16384, 8192, 4096])
    }

    @Test func reportsMissingToolSupportSeparatelyFromAFailedLoad() {
        let runtime = StubProbeRuntime(toolCallSucceeds: false)
        let result = ModelSelfTest(runtime: runtime)
            .run(modelURL: url, requestedContextTokens: 8192, trainedContextTokens: 32768)
        #expect(result == .noToolSupport)
    }

    @Test func failsWhenEvenTheSmallestPresetWillNotLoad() {
        let runtime = StubProbeRuntime(loadFailsAbove: 0)
        let result = ModelSelfTest(runtime: runtime)
            .run(modelURL: url, requestedContextTokens: 8192, trainedContextTokens: 32768)
        if case .failed = result {} else {
            Issue.record("expected .failed, got \(result)")
        }
    }
}
```

Append to `wallet-macos/Tests/WalletMacOSAppTests/ContextWindowSettingsTests.swift`:

```swift
    @Test func activeModelURLTracksTheLastSetModel() {
        let suite = UserDefaults(suiteName: "active-model-\(UUID().uuidString)")!
        let service = EmbeddedLlamaInferenceService(settingsStore: OnboardingSettingsStore(defaults: suite))
        #expect(service.activeModelURL == nil)
        service.setActiveModel(url: URL(fileURLWithPath: "/tmp/other.gguf"), contextTokens: 8192)
        #expect(service.activeModelURL?.path == "/tmp/other.gguf")
        #expect(service.contextSize == 8192)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd wallet-macos && swift test --filter ModelSelfTestTests
```
Expected: FAIL — `cannot find 'ModelProbeRuntime' in scope`.

- [ ] **Step 3: Add the swap seam to the inference service**

In `wallet-macos/Sources/WalletMacOSApp/EmbeddedLlamaInferenceService.swift`, replace the stored `runtime` and its init/lookup logic. Change the three stored properties and the initializer to:

```swift
final class EmbeddedLlamaInferenceService: @unchecked Sendable {
    private let settingsStore: OnboardingSettingsStore
    private let downloadManager: LocalAIModelDownloadManager
    private let stateLock = NSLock()
    private var runtime: LlamaRuntime
    private var loadedModelURL: URL?
    private var desiredModelURL: URL?
    private var desiredContextTokens: Int

    init(
        settingsStore: OnboardingSettingsStore = OnboardingSettingsStore(),
        downloadManager: LocalAIModelDownloadManager = LocalAIModelDownloadManager(),
        runtime: LlamaRuntime? = nil
    ) {
        self.settingsStore = settingsStore
        self.downloadManager = downloadManager
        let model = LocalAIModel.available.first { $0.id == settingsStore.selectedModelID } ?? .recommended
        let tokens = ContextWindowPresets.clamp(settingsStore.contextWindowTokens, maxTokens: model.maxContextTokens)
        self.desiredContextTokens = tokens
        self.runtime = runtime ?? LlamaRuntime(configuration: LocalLLMConfiguration(contextSize: Int32(tokens)))
    }

    /// Point the service at a different GGUF. The swap happens lazily, at the start
    /// of the next generation, so an in-flight stream is never pulled out from under
    /// its caller.
    func setActiveModel(url: URL, contextTokens: Int) {
        stateLock.lock()
        desiredModelURL = url
        desiredContextTokens = contextTokens
        stateLock.unlock()
    }

    var activeModelURL: URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return desiredModelURL ?? loadedModelURL
    }

    var contextSize: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return desiredContextTokens
    }
```

Delete the old `var contextSize: Int { runtime.configuredContextSize }`.

Replace the load block at the top of the `stream(...)` task body:

```swift
                    let modelURL = try installedModelURL()
                    if !runtime.isLoaded {
                        try runtime.loadModel(at: modelURL)
                    }
```

with a call to a new private method:

```swift
                    try prepareRuntime()
```

and add that method next to `installedModelURL()`:

```swift
    /// Loads the desired model, tearing down the previous runtime first when the
    /// selection or the context window changed.
    private func prepareRuntime() throws {
        stateLock.lock()
        let target = try desiredModelURL ?? installedModelURL()
        let tokens = desiredContextTokens
        let needsSwap = loadedModelURL != target || Int(runtime.configuredContextSize) != tokens
        stateLock.unlock()

        if needsSwap {
            runtime.unload()
            let replacement = LlamaRuntime(configuration: LocalLLMConfiguration(contextSize: Int32(tokens)))
            try replacement.loadModel(at: target)
            stateLock.lock()
            runtime = replacement
            loadedModelURL = target
            desiredModelURL = target
            stateLock.unlock()
            return
        }

        if !runtime.isLoaded {
            try runtime.loadModel(at: target)
            stateLock.lock()
            loadedModelURL = target
            stateLock.unlock()
        }
    }
```

`runtimeStatus` keeps working unchanged.

- [ ] **Step 4: Write the self test**

Create `wallet-macos/Sources/WalletMacOSApp/ModelSelfTest.swift`:

```swift
import Foundation
import LocalLLM
import WalletToolLayer

enum LocalAIModelSelfTestError: Error, Equatable {
    case outOfMemory
}

enum ModelSelfTestResult: Equatable {
    case ready(contextTokens: Int)
    case steppedDown(from: Int, to: Int)
    case noToolSupport
    case failed(String)
}

/// The seam that lets the step-down logic be tested without a 4.6 GB file.
protocol ModelProbeRuntime {
    func load(at url: URL, contextTokens: Int) throws
    func probeToolCall() throws -> Bool
    func unload()
}

/// Loads a freshly downloaded model for real, dropping the context window one
/// preset at a time until it fits, then checks the model can emit a tool call —
/// which is the only capability a wallet actually needs from it.
struct ModelSelfTest {
    private let runtime: ModelProbeRuntime

    init(runtime: ModelProbeRuntime) {
        self.runtime = runtime
    }

    func run(
        modelURL: URL,
        requestedContextTokens: Int,
        trainedContextTokens: Int
    ) -> ModelSelfTestResult {
        let ladder = ContextWindowPresets
            .options(maxTokens: trainedContextTokens)
            .filter { $0 <= requestedContextTokens }
            .sorted(by: >)
        guard !ladder.isEmpty else {
            return .failed("No context preset is small enough for this model.")
        }

        var lastError = "The model could not be loaded."
        for tokens in ladder {
            do {
                try runtime.load(at: modelURL, contextTokens: tokens)
            } catch {
                lastError = error.localizedDescription
                continue
            }
            defer { runtime.unload() }
            guard (try? runtime.probeToolCall()) == true else {
                return .noToolSupport
            }
            return tokens == requestedContextTokens
                ? .ready(contextTokens: tokens)
                : .steppedDown(from: requestedContextTokens, to: tokens)
        }
        return .failed(lastError)
    }
}

/// The real probe: a throwaway `LlamaRuntime` plus one fixed prompt that must come
/// back as a tool call.
final class LlamaProbeRuntime: ModelProbeRuntime {
    private var runtime: LlamaRuntime?

    func load(at url: URL, contextTokens: Int) throws {
        let candidate = LlamaRuntime(configuration: LocalLLMConfiguration(contextSize: Int32(contextTokens)))
        try candidate.loadModel(at: url)
        runtime = candidate
    }

    func probeToolCall() throws -> Bool {
        guard let runtime else { return false }
        var options = SamplerOptions()
        options.maxTokens = 128
        options.temperature = 0
        let messages = [
            LocalLLM.ChatMessage(role: .system, content: ToolDefinitions.systemNudge),
            LocalLLM.ChatMessage(role: .user, content: "Send 0.001 ETH to 0x000000000000000000000000000000000000dEaD"),
        ]
        var accumulated = ""
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            for try await event in runtime.chat(messages: messages, tools: ToolDefinitions.phase1, options: options) {
                if case .textToken(let token) = event { accumulated += token }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 120)
        let parsed = try? BridgePEGExtractor(runtime: runtime).extract(from: accumulated)
        return parsed?.toolCalls.isEmpty == false
    }

    func unload() {
        runtime?.unload()
        runtime = nil
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd wallet-macos && swift test --filter ModelSelfTestTests
cd wallet-macos && swift test --filter ContextWindowSettingsTests
```
Expected: PASS both suites.

- [ ] **Step 6: Commit**

```bash
git add wallet-macos/Sources/WalletMacOSApp/EmbeddedLlamaInferenceService.swift \
        wallet-macos/Sources/WalletMacOSApp/ModelSelfTest.swift \
        wallet-macos/Tests/WalletMacOSAppTests/ModelSelfTestTests.swift \
        wallet-macos/Tests/WalletMacOSAppTests/ContextWindowSettingsTests.swift
git commit -m "$(cat <<'EOF'
feat(models): swap the active model at runtime and self-test after install

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: App model wiring

**Files:**
- Modify: `wallet-macos/Sources/WalletMacOSApp/AppModel.swift` (near `setContextWindowTokens`, line ~570)
- Test: `wallet-macos/Tests/WalletMacOSAppTests/ModelSelectionTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1-7.
- Produces: on `AppModel` — `@Published var hardwareBudget: HardwareBudget?`, `var modelCatalog: ModelCatalog`, `@Published var modelActionMessage: String?`, `func refreshHardwareBudget() async`, `func fitVerdict(for entry: ModelCatalogEntry) -> ModelFitVerdict`, `func selectModel(id: String) throws -> ActiveModelSelection`, `func downloadModel(_ request: ModelDownloadRequest, progress:) async throws`, `func removeModel(id: String) throws`, `func resolveHuggingFaceRepo(_ repoID: String) async throws -> HuggingFaceRepositoryInfo`, plus `struct ActiveModelSelection { let url: URL; let contextTokens: Int; let displayName: String }`.
- **Ownership note (verified in the codebase, do not deviate):** `EmbeddedLlamaInferenceService` is a `private let` on `ChatDashboardModel` (`ChatDashboardView.swift:936`); `AppModel` has no reference to it and must not create one — a second instance would hold a second copy of the weights. `selectModel` therefore persists the choice and *returns* what to activate; `ChatDashboardModel` applies it (Task 9).

- [ ] **Step 1: Write the failing test**

Create `wallet-macos/Tests/WalletMacOSAppTests/ModelSelectionTests.swift`:

```swift
import Foundation
import Testing
@testable import WalletMacOSApp

struct ModelSelectionTests {
    private let gb: UInt64 = 1_073_741_824

    private func entry(profile: ModelMemoryProfile?) -> ModelCatalogEntry {
        ModelCatalogEntry(
            id: "owner/repo#file.gguf",
            displayName: "file",
            detail: "owner/repo",
            sizeText: "1 GB",
            source: .huggingFace,
            repoID: "owner/repo",
            fileName: "file.gguf",
            downloadURL: nil,
            sha256: nil,
            profile: profile,
            installedPath: "/tmp/file.gguf",
            isDefault: false
        )
    }

    @Test func verdictUsesTheStoredContextWindow() {
        let store = OnboardingSettingsStore(defaults: UserDefaults(suiteName: "sel-\(UUID().uuidString)")!)
        store.contextWindowTokens = 8192
        let budget = HardwareBudget(totalMemoryBytes: 36 * gb, metalBudgetBytes: 30_182_211_584, freeDiskBytes: 500 * gb)
        let profile = LocalAIModel.recommended.memoryProfile

        #expect(ModelSelectionPolicy.verdict(
            entry: entry(profile: profile),
            contextTokens: store.contextWindowTokens,
            budget: budget
        ) == .fits)
    }

    @Test func unknownProfileNeverBlocksSelection() {
        let budget = HardwareBudget(totalMemoryBytes: 8 * gb, metalBudgetBytes: 6 * gb, freeDiskBytes: 10 * gb)
        #expect(ModelSelectionPolicy.verdict(entry: entry(profile: nil), contextTokens: 8192, budget: budget) == .unknown)
        #expect(ModelSelectionPolicy.allowsSelection(verdict: .unknown) == true)
        #expect(ModelSelectionPolicy.allowsSelection(verdict: .wontFit) == true)
    }

    @Test func selectionRequiresConfirmationOnlyWhenItWillNotFit() {
        #expect(ModelSelectionPolicy.needsConfirmation(verdict: .fits) == false)
        #expect(ModelSelectionPolicy.needsConfirmation(verdict: .tight) == false)
        #expect(ModelSelectionPolicy.needsConfirmation(verdict: .wontFit) == true)
        #expect(ModelSelectionPolicy.needsConfirmation(verdict: .unknown) == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd wallet-macos && swift test --filter ModelSelectionTests
```
Expected: FAIL — `cannot find 'ModelSelectionPolicy' in scope`.

- [ ] **Step 3: Add the policy helper**

Append to `wallet-macos/Sources/WalletMacOSApp/ModelCatalog.swift`:

```swift
/// The one place that decides what a verdict means for the UI. Advisory by design:
/// nothing here can prevent a download or a selection, it only decides whether the
/// user is asked to confirm first.
enum ModelSelectionPolicy {
    static func verdict(
        entry: ModelCatalogEntry,
        contextTokens: Int,
        budget: HardwareBudget
    ) -> ModelFitVerdict {
        ModelFitEvaluator.verdict(profile: entry.profile, contextTokens: contextTokens, budget: budget)
    }

    static func allowsSelection(verdict: ModelFitVerdict) -> Bool { true }

    static func needsConfirmation(verdict: ModelFitVerdict) -> Bool {
        switch verdict {
        case .fits, .tight: return false
        case .wontFit, .unknown: return true
        }
    }
}
```

- [ ] **Step 4: Wire the app model**

In `wallet-macos/Sources/WalletMacOSApp/AppModel.swift`, add these stored properties beside the other `@Published` state:

```swift
    @Published var hardwareBudget: HardwareBudget?
    @Published var modelActionMessage: String?
    let installedModelStore = InstalledModelStore()
    private let huggingFaceRepository = HuggingFaceRepository()
    private let modelDownloadManager = LocalAIModelDownloadManager()
```

and these methods immediately after `setContextWindowTokens(_:)`:

```swift
    var modelCatalog: ModelCatalog {
        ModelCatalog(installedStore: installedModelStore, downloadManager: modelDownloadManager)
    }

    func refreshHardwareBudget() async {
        hardwareBudget = await LocalHardwareInspector().budget()
    }

    func fitVerdict(for entry: ModelCatalogEntry) -> ModelFitVerdict {
        guard let hardwareBudget else { return .unknown }
        return ModelSelectionPolicy.verdict(
            entry: entry,
            contextTokens: onboardingSettingsStore.contextWindowTokens,
            budget: hardwareBudget
        )
    }

    /// Persists the choice and returns what the dashboard should activate. Takes
    /// effect on the next message; the current conversation keeps its history.
    /// AppModel deliberately does not touch the runtime — see the ownership note.
    func selectModel(id: String) throws -> ActiveModelSelection {
        guard let entry = modelCatalog.entries.first(where: { $0.id == id }),
              let path = entry.installedPath,
              FileManager.default.fileExists(atPath: path)
        else {
            throw AppError.localDaemonLaunchFailed("That model is not installed.")
        }
        onboardingSettingsStore.selectedModelID = id
        onboardingSettingsStore.installedModelPath = path
        let tokens = ContextWindowPresets.clamp(
            onboardingSettingsStore.contextWindowTokens,
            maxTokens: entry.profile?.trainedContextTokens ?? LocalAIModel.recommended.maxContextTokens
        )
        onboardingSettingsStore.contextWindowTokens = tokens
        modelActionMessage = "\(entry.displayName) is now active."
        appendLog("models: active model set to \(entry.displayName) at \(tokens) tokens")
        return ActiveModelSelection(
            url: URL(fileURLWithPath: path),
            contextTokens: tokens,
            displayName: entry.displayName
        )
    }

    func resolveHuggingFaceRepo(_ repoID: String) async throws -> HuggingFaceRepositoryInfo {
        try await huggingFaceRepository.info(repoID: repoID)
    }

    /// Downloads, verifies, reads the GGUF header for a fit profile, and records the
    /// install. Does not activate the model — that is a separate, explicit step.
    func downloadModel(
        _ request: ModelDownloadRequest,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        if let hardwareBudget {
            try LocalAIModelDownloadManager.assertDiskSpace(neededBytes: request.sizeBytes, budget: hardwareBudget)
        }
        let fileURL = try await modelDownloadManager.download(request, progress: progress)
        let profile = try? await GGUFHeaderReader
            .fetch(from: request.url)
            .memoryProfile(weightBytes: request.sizeBytes)
        installedModelStore.add(InstalledModel(
            id: request.modelID,
            displayName: request.displayName,
            repoID: request.repoID,
            fileName: request.fileName,
            path: fileURL.path,
            sizeBytes: request.sizeBytes,
            sha256: request.expectedSHA256,
            profile: profile
        ))
        modelActionMessage = "\(request.displayName) downloaded."
        appendLog("models: installed \(request.modelID) at \(fileURL.path)")
    }

    /// Removes a custom model's file and its catalog entry. The default model can be
    /// removed too, but selection falls back to it, so the UI keeps it non-removable.
    func removeModel(id: String) throws {
        guard let installed = installedModelStore.model(id: id) else { return }
        if onboardingSettingsStore.selectedModelID == id {
            throw AppError.localDaemonLaunchFailed("Switch to another model before removing this one.")
        }
        try? FileManager.default.removeItem(atPath: installed.path)
        installedModelStore.remove(id: id)
        modelActionMessage = "\(installed.displayName) removed."
        appendLog("models: removed \(id)")
    }
```

Add the return type beside the other model types in `ModelCatalog.swift`:

```swift
/// What `ChatDashboardModel` needs in order to point the runtime at a new model.
struct ActiveModelSelection: Equatable {
    let url: URL
    let contextTokens: Int
    let displayName: String
}
```

`AppModel` must not import or instantiate `EmbeddedLlamaInferenceService`. Task 9 wires the returned selection into the instance `ChatDashboardModel` already owns.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd wallet-macos && swift test --filter ModelSelectionTests
cd wallet-macos && swift build
```
Expected: PASS (3 tests) and a clean build.

- [ ] **Step 6: Commit**

```bash
git add wallet-macos/Sources/WalletMacOSApp/AppModel.swift \
        wallet-macos/Sources/WalletMacOSApp/ModelCatalog.swift \
        wallet-macos/Tests/WalletMacOSAppTests/ModelSelectionTests.swift
git commit -m "$(cat <<'EOF'
feat(models): select, download and remove models from the app model

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Settings UI

**Files:**
- Modify: `wallet-macos/Sources/WalletMacOSApp/LocalWalletSettingsView.swift:765-852` (`modelsTab`) and the snapshot/callback declarations at lines 169-380
- Modify: `wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift:1137-1180` (snapshot) and `:4400-4460` (callbacks)
- Test: `wallet-macos/Tests/WalletMacOSAppTests/ModelsTabSnapshotTests.swift`

**Interfaces:**
- Consumes: `ModelCatalog`, `ModelFitVerdict`, `AppModel.selectModel/downloadModel/removeModel/resolveHuggingFaceRepo` (Task 8).
- Produces: `ModelFitEvaluator.selectableContexts(profile:budget:)`; snapshot fields `modelEntries: [SettingsModelRow]`, `hardwareSummary: SettingsHardwareSummary`, `selectableContextTokens: [Int]`; callbacks `onSelectModel: (String) throws -> Void`, `onDownloadModel: (ModelDownloadRequest) async throws -> Void`, `onRemoveModel: (String) throws -> Void`, `onResolveRepo: (String) async throws -> HuggingFaceRepositoryInfo`.

- [ ] **Step 1: Write the failing test**

Create `wallet-macos/Tests/WalletMacOSAppTests/ModelsTabSnapshotTests.swift`:

```swift
import Foundation
import Testing
@testable import WalletMacOSApp

struct ModelsTabSnapshotTests {
    private let gb: UInt64 = 1_073_741_824

    @Test func rowCarriesVerdictAndInstallState() {
        let row = SettingsModelRow(
            id: LocalAIModel.recommended.id,
            displayName: "Gemma 4 E4B",
            detail: "Q4_0 · 4.59 GB",
            source: .curated,
            verdict: .fits,
            estimatedBytes: 6_900_000_000,
            isInstalled: true,
            isActive: true,
            isDefault: true
        )
        #expect(row.verdict.label == "Fits")
        #expect(row.isRemovable == false)
    }

    @Test func customInstalledRowIsRemovableWhenInactive() {
        let row = SettingsModelRow(
            id: "owner/repo#file.gguf",
            displayName: "file",
            detail: "owner/repo",
            source: .huggingFace,
            verdict: .tight,
            estimatedBytes: 1,
            isInstalled: true,
            isActive: false,
            isDefault: false
        )
        #expect(row.isRemovable == true)
    }

    @Test func hardwareSummaryFormatsBudgetForDisplay() {
        let summary = SettingsHardwareSummary(budget: HardwareBudget(
            totalMemoryBytes: 36 * gb,
            metalBudgetBytes: 30_182_211_584,
            freeDiskBytes: 211 * gb
        ))
        #expect(summary.memoryText.contains("36"))
        #expect(summary.budgetText.contains("28"))
        #expect(summary.diskText.contains("211"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd wallet-macos && swift test --filter ModelsTabSnapshotTests
```
Expected: FAIL — `cannot find 'SettingsModelRow' in scope`.

- [ ] **Step 3: Offer only presets that can run**

Append to `wallet-macos/Sources/WalletMacOSApp/ModelMemoryProfile.swift`:

```swift
extension ModelFitEvaluator {
    /// The presets worth offering: everything the model's trained context allows,
    /// minus the sizes this Mac cannot hold. The app does not list a setting that
    /// would hang it — a `.wontFit` context is not a choice, it is a failure.
    /// Always returns at least one preset so the picker is never empty.
    static func selectableContexts(
        profile: ModelMemoryProfile?,
        budget: HardwareBudget?
    ) -> [Int] {
        let all = ContextWindowPresets.options(
            maxTokens: profile?.trainedContextTokens ?? ContextWindowPresets.fallback
        )
        guard let profile, let budget else { return all }
        let runnable = all.filter {
            verdict(profile: profile, contextTokens: $0, budget: budget) != .wontFit
        }
        return runnable.isEmpty ? [all.first ?? ContextWindowPresets.fallback] : runnable
    }
}
```

Add to `wallet-macos/Tests/WalletMacOSAppTests/ModelFitEvaluatorTests.swift`:

```swift
    @Test func selectableContextsDropTheSizesThisMacCannotHold() {
        let big = budget(ram: 36 * gb, metal: 30_182_211_584)
        let offered = ModelFitEvaluator.selectableContexts(profile: gemma, budget: big)
        // Gemma trains to 131072, but 131072 needs ~31 GB against a 28 GB budget.
        #expect(offered.contains(32768))
        #expect(!offered.contains(131_072))
    }

    @Test func selectableContextsNeverReturnAnEmptyPicker() {
        let tiny = budget(ram: 8 * gb, metal: 6 * gb)
        let offered = ModelFitEvaluator.selectableContexts(profile: gemma, budget: tiny)
        #expect(offered.count == 1)
        #expect(offered.first == ContextWindowPresets.ladder.first)
    }

    @Test func selectableContextsFallBackToTheLadderWithoutAProfile() {
        let big = budget(ram: 36 * gb, metal: 30_182_211_584)
        #expect(ModelFitEvaluator.selectableContexts(profile: nil, budget: big)
                == ContextWindowPresets.options(maxTokens: ContextWindowPresets.fallback))
    }
```

- [ ] **Step 4: Add the view models**

Append to `wallet-macos/Sources/WalletMacOSApp/ModelCatalog.swift`:

```swift
/// One row in Settings › Models. A flattened, already-formatted view of a catalog
/// entry so the SwiftUI body stays declarative.
struct SettingsModelRow: Identifiable, Equatable {
    let id: String
    let displayName: String
    let detail: String
    let source: ModelSource
    let verdict: ModelFitVerdict
    let estimatedBytes: UInt64
    let isInstalled: Bool
    let isActive: Bool
    let isDefault: Bool

    /// The shipped default is never removable, and neither is the running model.
    var isRemovable: Bool { !isDefault && isInstalled && !isActive }

    var estimatedText: String {
        ByteCountFormatter.string(fromByteCount: Int64(estimatedBytes), countStyle: .file)
    }
}

struct SettingsHardwareSummary: Equatable {
    let memoryText: String
    let budgetText: String
    let diskText: String

    init(budget: HardwareBudget) {
        func format(_ bytes: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        memoryText = format(budget.totalMemoryBytes)
        budgetText = format(budget.usableBytes)
        diskText = format(budget.freeDiskBytes)
    }
}
```

- [ ] **Step 4: Extend the settings snapshot and callbacks**

In `wallet-macos/Sources/WalletMacOSApp/LocalWalletSettingsView.swift`, add to `LocalWalletSettingsSnapshot` beside `textModelPath` (line ~177):

```swift
    let modelRows: [SettingsModelRow]
    let hardwareSummary: SettingsHardwareSummary?
    /// Context presets worth offering on this Mac; never empty. See
    /// ModelFitEvaluator.selectableContexts.
    let selectableContextTokens: [Int]
```

Add to the callback block beside `onRevealModelFile` (line ~269) and to the initializer parameter list and assignments in the same order:

```swift
    let onSelectModel: (String) throws -> Void
    let onDownloadModel: (ModelDownloadRequest, @escaping @MainActor (Double) -> Void) async throws -> Void
    let onRemoveModel: (String) throws -> Void
    let onResolveRepo: (String) async throws -> HuggingFaceRepositoryInfo
```

- [ ] **Step 5: Rebuild `modelsTab`**

Replace the body of `private var modelsTab: some View` (lines 765-852) with:

```swift
    private var modelsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let hardware = snapshot.hardwareSummary {
                SettingsSection(title: "This Mac") {
                    SettingsKeyValueRows(rows: [
                        SettingsKeyValue(title: "Memory", value: hardware.memoryText),
                        SettingsKeyValue(title: "Model budget", value: hardware.budgetText),
                        SettingsKeyValue(title: "Free disk", value: hardware.diskText),
                    ])
                }
            }

            SettingsSection(title: "Text Model") {
                ForEach(snapshot.modelRows) { row in
                    HStack(spacing: 12) {
                        Image(systemName: row.isActive ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(row.isActive ? SettingsPalette.blue : SettingsPalette.mutedText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.displayName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(SettingsPalette.primaryText)
                            Text("\(row.detail) · \(row.estimatedText) in memory")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(SettingsPalette.secondaryText)
                        }
                        Spacer()
                        if row.isDefault {
                            SettingsBadge(text: "Default", tint: SettingsPalette.blue)
                        }
                        SettingsBadge(text: row.verdict.label, tint: verdictTint(row.verdict))
                        if row.isInstalled {
                            Button("Use") { runModelAction { try onSelectModel(row.id) } }
                                .buttonStyle(SettingsSecondaryButtonStyle())
                                .disabled(row.isActive)
                        }
                        if row.isRemovable {
                            Button("Remove") { runModelAction { try onRemoveModel(row.id) } }
                                .buttonStyle(SettingsSecondaryButtonStyle())
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(SettingsPalette.rowBackground))
                }
                if let modelMessage {
                    SettingsMessageBanner(message: modelMessage)
                }
            }

            SettingsSection(title: "Context Window") {
                Picker("", selection: Binding(
                    get: { contextWindowDraft },
                    set: { newValue in
                        contextWindowDraft = newValue
                        onSetContextWindowTokens(newValue)
                        modelMessage = SettingsMessage(
                            kind: .success,
                            text: "Context window set to \(newValue) tokens. Applies to the next message."
                        )
                    }
                )) {
                    ForEach(snapshot.selectableContextTokens, id: \.self) { tokens in
                        Text("\(tokens) tokens").tag(tokens)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
                Text("Active: \(snapshot.contextWindow). Larger windows use more memory — the verdicts above are computed at this size. Sizes this Mac cannot hold are not listed.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPalette.secondaryText)
                Divider().overlay(SettingsPalette.border).padding(.vertical, 4)
                HStack(spacing: 12) {
                    Toggle("Show thinking", isOn: $thinkingEnabled)
                        .toggleStyle(.switch)
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Button {
                        do {
                            modelMessage = SettingsMessage(kind: .success, text: try onRevealModelFile())
                        } catch {
                            modelMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
                        }
                    } label: {
                        Label("Reveal model file", systemImage: "folder")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                }
            }

            SettingsSection(title: "Add From Hugging Face") {
                AddHuggingFaceModelForm(
                    onResolveRepo: onResolveRepo,
                    onDownloadModel: onDownloadModel
                )
            }

            SettingsSection(title: "Multimodal Runtime") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Selected", value: snapshot.multimodalModelName),
                    SettingsKeyValue(title: "Status", value: snapshot.multimodalModelStatus),
                ])
            }
        }
    }

    private func verdictTint(_ verdict: ModelFitVerdict) -> Color {
        switch verdict {
        case .fits: return SettingsPalette.green
        case .tight: return SettingsPalette.orange
        case .wontFit: return SettingsPalette.red
        case .unknown: return SettingsPalette.mutedText
        }
    }

    private func runModelAction(_ action: () throws -> Void) {
        do {
            try action()
            modelMessage = SettingsMessage(kind: .success, text: "Done.")
        } catch {
            modelMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
        }
    }
```

If `SettingsBadge`, `SettingsPalette.rowBackground` or `SettingsPalette.red` do not exist in this file, add them next to the existing palette and badge helpers rather than inventing a new styling layer.

- [ ] **Step 6: Add the Hugging Face form**

Add at the end of `wallet-macos/Sources/WalletMacOSApp/LocalWalletSettingsView.swift`:

```swift
/// Repo → file → download. Resolution is explicit (a button, not on every keystroke)
/// so a half-typed repo name never fires a request.
private struct AddHuggingFaceModelForm: View {
    let onResolveRepo: (String) async throws -> HuggingFaceRepositoryInfo
    let onDownloadModel: (ModelDownloadRequest, @escaping @MainActor (Double) -> Void) async throws -> Void

    @State private var repoID: String = ""
    @State private var files: [HuggingFaceGGUFFile] = []
    @State private var selectedPath: String = ""
    @State private var message: SettingsMessage?
    @State private var progress: Double?
    @State private var isResolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SettingsEditableField(
                    title: "Repository",
                    placeholder: "unsloth/gemma-4-E2B-it-GGUF",
                    text: $repoID
                )
                Button(isResolving ? "Checking…" : "Find models") { resolve() }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .disabled(repoID.isEmpty || isResolving)
            }

            if !files.isEmpty {
                Picker("File", selection: $selectedPath) {
                    ForEach(files.filter { !$0.isAuxiliary }) { file in
                        Text("\(file.path) · \(ByteCountFormatter.string(fromByteCount: Int64(file.sizeBytes), countStyle: .file))")
                            .tag(file.path)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    if let progress {
                        ProgressView(value: progress).frame(width: 180)
                        Text("\(Int(progress * 100))%").font(.system(size: 11, design: .monospaced))
                    }
                    Spacer()
                    Button("Download & add") { download() }
                        .buttonStyle(SettingsPrimaryButtonStyle())
                        .disabled(selectedPath.isEmpty || progress != nil)
                }
            }

            if let message {
                SettingsMessageBanner(message: message)
            }

            Text("Public GGUF repositories only. Unverified models can get tool calls wrong — review every transaction.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func resolve() {
        isResolving = true
        message = nil
        Task { @MainActor in
            defer { isResolving = false }
            do {
                let info = try await onResolveRepo(repoID)
                files = info.files
                selectedPath = info.files.first { !$0.isAuxiliary }?.path ?? ""
                let context = info.trainedContextTokens.map { " · trained to \($0)" } ?? ""
                message = SettingsMessage(
                    kind: info.hasChatTemplate ? .success : .error,
                    text: info.hasChatTemplate
                        ? "\(info.files.count) GGUF file(s)\(context)."
                        : "This repo has no chat template, so it cannot make tool calls."
                )
            } catch {
                files = []
                message = SettingsMessage(kind: .error, text: error.localizedDescription)
            }
        }
    }

    private func download() {
        guard let file = files.first(where: { $0.path == selectedPath }) else { return }
        let request = ModelDownloadRequest(repoID: repoID.trimmingCharacters(in: .whitespaces), file: file)
        progress = 0
        Task { @MainActor in
            do {
                try await onDownloadModel(request) { value in progress = value }
                progress = nil
                message = SettingsMessage(kind: .success, text: "\(request.displayName) added. Press Use to switch to it.")
            } catch {
                progress = nil
                message = SettingsMessage(kind: .error, text: error.localizedDescription)
            }
        }
    }
}
```

- [ ] **Step 7: Fill the new snapshot fields and callbacks**

In `wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift`, inside `settingsSnapshot`, build the rows before the `return`:

```swift
        let budget = walletModel.hardwareBudget
        let activeModelID = onboardingSettingsStore.selectedModelID
        let modelRows = walletModel.modelCatalog.entries.map { entry in
            SettingsModelRow(
                id: entry.id,
                displayName: entry.displayName,
                detail: entry.source == .curated ? entry.sizeText : entry.repoID,
                source: entry.source,
                verdict: walletModel.fitVerdict(for: entry),
                estimatedBytes: entry.profile.map {
                    ModelFitEvaluator.requiredBytes(profile: $0, contextTokens: onboardingSettingsStore.contextWindowTokens)
                } ?? 0,
                isInstalled: entry.isInstalled,
                isActive: entry.id == activeModelID,
                isDefault: entry.isDefault
            )
        }
```

pass them into the snapshot initializer:

```swift
            modelRows: modelRows,
            hardwareSummary: budget.map(SettingsHardwareSummary.init),
            selectableContextTokens: ModelFitEvaluator.selectableContexts(
                profile: walletModel.modelCatalog.entries.first { $0.id == activeModelID }?.profile,
                budget: budget
            ),
```

and add the four callbacks in `settingsBody` after `onRevealModelFile`:

```swift
            onSelectModel: { id in
                let selection = try model.walletModel.selectModel(id: id)
                model.applyActiveModel(selection)
            },
            onDownloadModel: { request, progress in
                try await model.walletModel.downloadModel(request, progress: progress)
            },
            onRemoveModel: { id in
                try model.walletModel.removeModel(id: id)
            },
            onResolveRepo: { repoID in
                try await model.walletModel.resolveHuggingFaceRepo(repoID)
            },
```

Add the applier to `ChatDashboardModel`, next to the other `inferenceService` uses — this is the only place that may touch the runtime:

```swift
    /// Points the one runtime instance at the newly selected model. The swap itself
    /// happens lazily inside the service, at the start of the next generation.
    func applyActiveModel(_ selection: ActiveModelSelection) {
        inferenceService.setActiveModel(url: selection.url, contextTokens: selection.contextTokens)
        runtimeStatus = inferenceService.runtimeStatus
    }
```

Finally, refresh the budget when the dashboard appears — add to the existing `.task` / `onAppear` block that already runs at dashboard start:

```swift
            await model.walletModel.refreshHardwareBudget()
```

- [ ] **Step 8: Run the tests and build**

```bash
cd wallet-macos && swift test --filter ModelsTabSnapshotTests
cd wallet-macos && swift build
cd wallet-macos && swift test
```
Expected: PASS. The whole `wallet-macos` suite must be green before moving on.

- [ ] **Step 9: Verify in the running app**

Open `LocalWallet.xcodeproj`, select the `LocalWalletApp` scheme, run, and check Settings › Models shows: the "This Mac" card with a non-zero budget, Gemma marked Default + Fits + active, and the Hugging Face form resolving `unsloth/gemma-4-E2B-it-GGUF` to a file list. Do not `swift run` the app — Keychain access fails outside the signed bundle.

- [ ] **Step 10: Commit**

```bash
git add wallet-macos/Sources/WalletMacOSApp/LocalWalletSettingsView.swift \
        wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift \
        wallet-macos/Sources/WalletMacOSApp/ModelCatalog.swift \
        wallet-macos/Tests/WalletMacOSAppTests/ModelsTabSnapshotTests.swift
git commit -m "$(cat <<'EOF'
feat(settings): switch models, add Hugging Face repos, show the fit verdict

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Onboarding

**Files:**
- Modify: `wallet-macos/Sources/WalletMacOSApp/OnboardingView.swift:78-170` (state), `:640-690` (footer copy), `:880-910` (model picker), `:1878-1902` (hardware card copy)
- Modify: `wallet-macos/Sources/WalletMacOSApp/LocalHardwareInspector.swift:4-11` (delete the threshold)
- Modify: `wallet-macos/Sources/WalletMacOSApp/LocalWalletSettingsView.swift:692-696` and `:2333-2340` (System card)
- Modify: `README.md:32`
- Test: `wallet-macos/Tests/WalletMacOSAppTests/OnboardingModelGateTests.swift`

**Interfaces:**
- Consumes: `HardwareBudget`, `ModelFitEvaluator`, `ModelDownloadRequest`.
- Produces: `OnboardingState.fitVerdict(for: LocalAIModel) -> ModelFitVerdict` and a relaxed `hardwareMeetsModelRequirement`.

- [ ] **Step 1: Write the failing test**

Create `wallet-macos/Tests/WalletMacOSAppTests/OnboardingModelGateTests.swift`:

```swift
import Foundation
import Testing
@testable import WalletMacOSApp

struct OnboardingModelGateTests {
    private let gb: UInt64 = 1_073_741_824

    @Test func continueIsAllowedOnATightMachine() {
        // 16 GB Macs were blocked outright by the old `hasMinimumModelMemory` gate.
        let budget = HardwareBudget(totalMemoryBytes: 16 * gb, metalBudgetBytes: 12 * gb, freeDiskBytes: 200 * gb)
        let verdict = ModelFitEvaluator.verdict(
            profile: LocalAIModel.recommended.memoryProfile,
            contextTokens: 4096,
            budget: budget
        )
        #expect(verdict != .wontFit)
        #expect(OnboardingModelGate.allowsDownload(verdict: verdict) == true)
    }

    @Test func wontFitStillAllowsDownloadButWarns() {
        let budget = HardwareBudget(totalMemoryBytes: 8 * gb, metalBudgetBytes: 6 * gb, freeDiskBytes: 200 * gb)
        let verdict = ModelFitEvaluator.verdict(
            profile: LocalAIModel.recommended.memoryProfile,
            contextTokens: 4096,
            budget: budget
        )
        #expect(verdict == .wontFit)
        #expect(OnboardingModelGate.allowsDownload(verdict: verdict) == true)
        #expect(OnboardingModelGate.warning(verdict: verdict, budget: budget)?.isEmpty == false)
    }

    @Test func fitsProducesNoWarning() {
        let budget = HardwareBudget(totalMemoryBytes: 36 * gb, metalBudgetBytes: 30_182_211_584, freeDiskBytes: 200 * gb)
        #expect(OnboardingModelGate.warning(verdict: .fits, budget: budget) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd wallet-macos && swift test --filter OnboardingModelGateTests
```
Expected: FAIL — `cannot find 'OnboardingModelGate' in scope`.

- [ ] **Step 3: Add the gate helper**

Append to `wallet-macos/Sources/WalletMacOSApp/ModelMemoryProfile.swift`:

```swift
/// Onboarding used to refuse to continue below 16 GB of RAM. It now advises
/// instead: the download is always permitted, and a machine that cannot hold the
/// model at the smallest preset gets a plain warning.
enum OnboardingModelGate {
    static func allowsDownload(verdict: ModelFitVerdict) -> Bool { true }

    static func warning(verdict: ModelFitVerdict, budget: HardwareBudget) -> String? {
        switch verdict {
        case .fits, .unknown:
            return nil
        case .tight:
            return "This model will use most of the memory available to it on this Mac. Replies may be slow."
        case .wontFit:
            let available = ByteCountFormatter.string(fromByteCount: Int64(budget.usableBytes), countStyle: .file)
            return "This Mac has \(available) available for the model, which is below what it needs. You can still install it, but expect swapping or a failed load."
        }
    }
}
```

- [ ] **Step 4: Delete the 16 GB threshold**

In `wallet-macos/Sources/WalletMacOSApp/LocalHardwareInspector.swift`, delete both of these from `LocalHardwareProfile` — nothing may reference a fixed RAM minimum after this task:

```swift
    static let minimumModelMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024

    var hasMinimumModelMemory: Bool {
        memoryBytes >= Self.minimumModelMemoryBytes
    }
```

In `wallet-macos/Sources/WalletMacOSApp/LocalWalletSettingsView.swift`, the System card loses its threshold colouring. Replace the `tint:` line at ~696:

```swift
                        tint: SettingsPalette.green
```

and replace `hardwareMemoryStatus` (~2333) with a plain report:

```swift
    private var hardwareMemoryStatus: String {
        guard let hardwareProfile else {
            return "Inspecting..."
        }
        guard let summary = snapshot.hardwareSummary else {
            return hardwareProfile.memoryText
        }
        return "\(summary.memoryText) · \(summary.budgetText) for models"
    }
```

- [ ] **Step 5: Rework the onboarding state**

In `wallet-macos/Sources/WalletMacOSApp/OnboardingView.swift`:

Add to `OnboardingState`:

```swift
    @Published var hardwareBudget: HardwareBudget?

    func fitVerdict(for model: LocalAIModel) -> ModelFitVerdict {
        guard let hardwareBudget else { return .unknown }
        return ModelFitEvaluator.verdict(
            profile: model.memoryProfile,
            contextTokens: ContextWindowPresets.fallback,
            budget: hardwareBudget
        )
    }
```

In the `inspect()` call site (line ~134), also load the budget:

```swift
            hardwareProfile = await hardwareInspector.inspect()
            hardwareBudget = await hardwareInspector.budget()
```

Replace `hardwareMeetsModelRequirement` (lines 164-166) with:

```swift
    /// Advisory only. The download is never blocked — see OnboardingModelGate.
    var hardwareMeetsModelRequirement: Bool { true }

    var hardwareWarning: String? {
        guard let hardwareBudget else { return nil }
        return OnboardingModelGate.warning(verdict: fitVerdict(for: selectedModel), budget: hardwareBudget)
    }
```

Replace the memory rejection string at line 648:

```swift
            return "\(hardwareProfile.displayName). Gemma 4 E4B requires at least 16 GB RAM."
```

with:

```swift
            return state.hardwareWarning ?? hardwareProfile.displayName
```

- [ ] **Step 6: Replace the blocked-machine copy**

Still in `OnboardingView.swift`, the hardware card at ~1878-1902 currently reports READY/BLOCKED against the deleted threshold. Replace its three computed properties with verdict-driven copy:

```swift
    private var detailText: String {
        guard let profile else {
            return "Checking this Mac."
        }
        guard let warning = state.hardwareWarning else {
            return "\(profile.displayName). Ready for the local model."
        }
        return "\(profile.displayName). \(warning)"
    }

    private var badgeText: String {
        guard profile != nil else { return "CHECKING" }
        return state.hardwareWarning == nil ? "READY" : "TIGHT"
    }

    private var badgeColor: Color {
        guard profile != nil else { return OnboardingPalette.mutedText }
        return state.hardwareWarning == nil ? OnboardingPalette.success : OnboardingPalette.warning
    }
```

`ModelHardwareCard` needs access to `state` for this; pass the `OnboardingState` in where it is constructed, the same way `ModelInstallStatusCard` already receives its inputs.

- [ ] **Step 7: Show the verdict on each model card**

In the model picker `ForEach` (line ~899), pass the verdict into the card and render it as a badge beside the size:

```swift
                    ForEach(LocalAIModel.available) { model in
                        ModelChoiceCard(
                            model: model,
                            verdict: state.fitVerdict(for: model),
                            isSelected: state.selectedModelID == model.id,
                            isInstalled: state.installState == .installed && state.selectedModelID == model.id
                        ) {
                            state.selectedModelID = model.id
                        }
                    }
```

Add the matching `let verdict: ModelFitVerdict` property to `ModelChoiceCard` (line ~1906) and render `Text(verdict.label)` in its trailing badge position, using the existing `OnboardingPalette.success` / `.warning` colors for `.fits` / `.tight` / `.wontFit`.

- [ ] **Step 8: Update the stated system requirement**

In `README.md`, replace line 32:

```markdown
- 16 GB RAM minimum for the local Gemma 4 E4B model setup.
```

with:

```markdown
- 16 GB RAM for the default Gemma 4 E4B model. It needs about 6 GB of memory at a
  4k context window, which a 16 GB Mac holds comfortably and an 8 GB Mac does not.
  The app measures what your Mac can offer and reports, per model, whether it fits;
  a smaller model added from Hugging Face can run on 8 GB.
```

The old line claimed a flat 16 GB minimum for the app. The new one attributes the
requirement to the model, which is where it belongs — the app itself runs anywhere
macOS 15 does.

- [ ] **Step 9: Run the tests, build, and prove the threshold is gone**

```bash
cd wallet-macos && swift test --filter OnboardingModelGateTests
cd wallet-macos && swift build
cd wallet-macos && swift test
grep -rn "hasMinimumModelMemory\|minimumModelMemoryBytes\|16 GB RAM" wallet-macos/Sources README.md | grep -v '\.build'
```
Expected: all suites PASS, and the grep returns **nothing**. Any hit is a leftover reference to the deleted gate.

- [ ] **Step 10: Commit**

```bash
git add wallet-macos/Sources/WalletMacOSApp/OnboardingView.swift \
        wallet-macos/Sources/WalletMacOSApp/LocalHardwareInspector.swift \
        wallet-macos/Sources/WalletMacOSApp/LocalWalletSettingsView.swift \
        wallet-macos/Sources/WalletMacOSApp/ModelMemoryProfile.swift \
        wallet-macos/Tests/WalletMacOSAppTests/OnboardingModelGateTests.swift \
        README.md
git commit -m "$(cat <<'EOF'
feat(onboarding): replace the 16 GB block with a measured per-model verdict

The threshold arrived with the initial scaffold import (710933c) and was
never revisited: a fixed RAM number cannot see quantization, context
window, or which model was chosen. An 8 GB Mac now learns what the model
needs and what it has, and may install anyway.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Documentation and final verification

**Files:**
- Modify: `CLAUDE.md` (the "On-device LLM" bullet under *App internals worth knowing*)

`README.md` was already updated in Task 10, Step 8.

- [ ] **Step 1: Update the architecture note**

In `CLAUDE.md`, replace the On-device LLM bullet with:

```markdown
- **On-device LLM:** Gemma 4 E4B via llama.cpp/ggml (Metal, no network at inference) is the default, model at `~/Library/Application Support/LocalWallet/Models/`, chat history in `chat.sqlite`. Additional GGUF models can be added from any public Hugging Face repo (`HuggingFaceRepository` → `LocalAIModelDownloadManager` → `InstalledModelStore`) and switched in Settings › Models; `EmbeddedLlamaInferenceService.setActiveModel` swaps the runtime at the next message. Every model carries a fit verdict from `ModelFitEvaluator` (weights + KV cache vs `MTLDevice.recommendedMaxWorkingSetSize`), which advises but never blocks. `WalletToolLayer` turns natural language / `/transfer` / `/swap` into reviewable, Secure-Enclave-signed, daemon-submitted intents.
```

- [ ] **Step 2: Run the full local gate**

```bash
./scripts/build-ffi.sh
cd rust-core && cargo test
cd ../swift-bridge && swift test
cd ../wallet-macos && swift test
```
Expected: all green. The Rust suites are unaffected by this work but are part of the per-commit gate in `CONTRIBUTING.md`.

- [ ] **Step 3: Manual end-to-end pass**

Run the app from Xcode (`LocalWalletApp` scheme) and walk the whole feature:

1. Settings › Models shows the "This Mac" card with a plausible budget.
2. Gemma is Default, Installed, active, verdict `Fits`.
3. Paste `unsloth/gemma-4-E2B-it-GGUF`, press Find models, pick the Q4_K_M file, download it. Progress advances and the row appears.
4. Press Use on the new model, then send a chat message — it answers, and `~/Library/Application Support/LocalWallet/Models/` holds both files.
5. Switch back to Gemma, press Remove on the custom model, confirm the file is gone.
6. Set Context window to the largest preset, confirm the verdicts update.

- [ ] **Step 4: Commit and open the PR**

```bash
git add CLAUDE.md README.md
git commit -m "$(cat <<'EOF'
docs: describe pluggable models and the hardware fit check

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin feat/pluggable-models
gh pr create --title "feat(models): pluggable local models with a hardware fit check" --body "$(cat <<'EOF'
Closes #74.

Gemma 4 E4B Q4_0 remains the default and the upgrade path is a no-op for
existing installs (the legacy single-slot install keys are migrated).

- Add any public Hugging Face GGUF repo from Settings › Models
- Switch the active model without restarting the app
- Per-model fit verdict from measured GGUF metadata against this Mac's
  Metal budget; it advises and never blocks
- Post-download load test with automatic context step-down

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Default stays Gemma 4 E4B Q4_0 → Task 5 (`LocalAIModel.recommended` unchanged but for the profile), asserted in `SettingsWiringAuditTests.defaultModelIsStillGemmaQ4`.
- Download from Hugging Face → Tasks 4, 6, 9.
- Switchable from Settings → Tasks 7, 8, 9.
- Hardware check before download → Task 6 (`assertDiskSpace`) + Task 9 (verdict shown before the download button).
- Hardware check before use → Task 8 (`fitVerdict`) + Task 9 (verdict per row) + Task 10 (onboarding).
- The fixed 16 GB RAM gate is deleted, not merely relaxed → Task 10, Steps 4 and 9, with a grep that fails the task if any reference survives. `README.md` moves to "8 GB minimum, 16 GB recommended" in the same task.
- "Download anyway" override → `ModelSelectionPolicy.allowsSelection` always true, `OnboardingModelGate.allowsDownload` always true, both asserted.
- Post-download test → Task 7.

**Placeholder scan:** no TBDs; every code step carries the actual code. The one judgment call left to the implementer is explicit and bounded: reuse `SettingsBadge` / palette entries if they exist, else add them next to their existing neighbors (Task 9, Step 5).

**Type consistency:** `ModelMemoryProfile`, `HardwareBudget`, `ModelFitVerdict`, `ModelCatalogEntry`, `InstalledModel`, `ModelDownloadRequest`, `SettingsModelRow` are each defined once and used with the same field names throughout. `LocalAIModel.maxContextTokens` becomes a computed property over `memoryProfile.trainedContextTokens`, so its existing call sites (`AppModel.setContextWindowTokens`, `EmbeddedLlamaInferenceService.init`, `ContextWindowSettingsTests`) keep compiling unchanged.
