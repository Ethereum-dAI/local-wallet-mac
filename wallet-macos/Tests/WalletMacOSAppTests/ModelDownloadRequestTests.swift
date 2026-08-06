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
