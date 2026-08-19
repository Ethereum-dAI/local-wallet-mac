import Foundation
import Testing
@testable import WalletMacOSApp

struct ModelDownloadRequestTests {
    @Test func curatedModelMapsOntoARequest() {
        let request = ModelDownloadRequest(model: .recommended)
        #expect(request.modelID == LocalAIModel.recommended.id)
        #expect(request.fileName == "gemma-4-E4B-it-Q4_K_M.gguf")
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
        #expect(curated.lastPathComponent == "gemma-4-E4B-it-Q4_K_M.gguf")
        // The fine-tune kept its own un-namespaced name across the default change,
        // which is what lets an existing install keep its file on disk.
        let tuned = try manager.localFileURL(for: ModelDownloadRequest(model: .walletFineTune))
        #expect(tuned.lastPathComponent == "gemma-4-E4B-wallet-ft.Q4_K_M.gguf")
    }

    @Test func diskCheckRejectsADownloadThatWillNotFit() {
        let gb: UInt64 = 1_073_741_824
        // freeDiskBytes must exceed neededBytes + the 2 GB slack in `assertDiskSpace`
        // for the second assertion below to pass; 2 * gb (the brief's original
        // literal) leaves only 2 GB total, which is consumed entirely by the slack
        // and rejects even a 1 GB download. Bumped to 4 * gb so both cases hold.
        let budget = HardwareBudget(totalMemoryBytes: 36 * gb, metalBudgetBytes: 28 * gb, freeDiskBytes: 4 * gb)
        #expect(throws: LocalAIModelDownloadError.self) {
            try LocalAIModelDownloadManager.assertDiskSpace(neededBytes: 5 * gb, budget: budget)
        }
        #expect(throws: Never.self) {
            try LocalAIModelDownloadManager.assertDiskSpace(neededBytes: 1 * gb, budget: budget)
        }
    }
}

/// Verification has to survive a Hugging Face entry with no LFS oid: the tree
/// API does not always carry one, and skipping the check outright turned a
/// truncated transfer into a "successful" install that only failed later, inside
/// llama.cpp's GGUF parse, with nothing pointing back at the download.
struct ModelDownloadIntegrityTests {
    private func file(sha256: String?, sizeBytes: UInt64) -> HuggingFaceGGUFFile {
        HuggingFaceGGUFFile(
            path: "Qwen3-8B-Q4_K_M.gguf",
            sizeBytes: sizeBytes,
            sha256: sha256,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf")!
        )
    }

    @Test func aDigestlessEntryFallsBackToItsByteCount() {
        let request = ModelDownloadRequest(repoID: "Qwen/Qwen3-8B-GGUF", file: file(sha256: nil, sizeBytes: 4_920_000_000))
        #expect(request.expectedSHA256 == nil)
        #expect(request.expectedSizeBytes == 4_920_000_000)
    }

    /// A missing `size` decodes as 0, which is a absent field rather than an empty
    /// file — checking against it would reject every real download.
    @Test func anAbsentByteCountLeavesNothingToCheck() {
        let request = ModelDownloadRequest(repoID: "Qwen/Qwen3-8B-GGUF", file: file(sha256: nil, sizeBytes: 0))
        #expect(request.expectedSizeBytes == nil)
    }

    /// A digest subsumes a size check, so curated models carry no size expectation
    /// — their `sizeBytes` is a memory-profile estimate, not a byte-exact figure.
    @Test func aPinnedCuratedModelReliesOnItsDigestAlone() {
        let request = ModelDownloadRequest(model: .recommended)
        #expect(request.expectedSHA256?.isEmpty == false)
        #expect(request.expectedSizeBytes == nil)
    }

    @Test func aTruncatedFileIsReportedWithBothSizes() {
        let error = LocalAIModelDownloadError.sizeMismatch(expected: 4_920_000_000, actual: 12_000)
        let message = try! #require(error.errorDescription)
        #expect(message.contains("incomplete"))
        #expect(message.contains("Try downloading it again."))
    }

    @Test func fileSizeReadsTheActualBytesOnDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("size-check-\(UUID().uuidString).bin")
        try Data(repeating: 0xAB, count: 4096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try LocalAIModelDownloadManager.fileSize(of: url) == 4096)
    }
}
