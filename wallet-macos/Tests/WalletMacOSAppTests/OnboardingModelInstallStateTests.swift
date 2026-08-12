import CryptoKit
import Foundation
import Testing
@testable import WalletMacOSApp

@Suite(.serialized)
struct OnboardingModelInstallStateTests {
    @Test func trustedInstallMetadataRestoresInstalledWithoutVerification() {
        let recordedURL = URL(fileURLWithPath: "/tmp/verified-model.gguf")
        let candidate = LocalAIModelInstallationResolver.resolve(
            model: .recommended,
            installedModelID: LocalAIModel.recommended.id,
            installedModelPath: recordedURL.path,
            discoveredFileURL: URL(fileURLWithPath: "/tmp/other-model.gguf"),
            fileExists: { $0 == recordedURL.path }
        )

        #expect(candidate == .trusted(recordedURL))
    }

    @Test func untrackedExistingModelRequiresVerification() {
        let discoveredURL = URL(fileURLWithPath: "/tmp/untracked-model.gguf")
        let candidate = LocalAIModelInstallationResolver.resolve(
            model: .recommended,
            installedModelID: nil,
            installedModelPath: nil,
            discoveredFileURL: discoveredURL,
            fileExists: { _ in true }
        )

        #expect(candidate == .needsVerification(discoveredURL))
    }

    @Test func missingModelStaysIdle() {
        let candidate = LocalAIModelInstallationResolver.resolve(
            model: .recommended,
            installedModelID: LocalAIModel.recommended.id,
            installedModelPath: "/tmp/missing-model.gguf",
            discoveredFileURL: nil,
            fileExists: { _ in false }
        )

        #expect(candidate == .missing)
    }

    @Test func checksumVerificationAcceptsOnlyTheCatalogDigest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("tiny-model.gguf")
        let data = Data("verified model fixture".utf8)
        try data.write(to: fileURL)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let model = testModel(sha256: checksum)
        let manager = LocalAIModelDownloadManager()

        let verifiedURL = try await manager.verifyExistingFile(model, at: fileURL)
        #expect(verifiedURL == fileURL)

        let wrongModel = testModel(sha256: String(repeating: "0", count: 64))
        await #expect(throws: LocalAIModelDownloadError.self) {
            try await manager.verifyExistingFile(wrongModel, at: fileURL)
        }
    }

    @Test @MainActor func existingUntrackedModelIsVerifiedBeforeDownloadIsAvailable() async throws {
        let defaultsSuite = "OnboardingModelInstallStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let existingURL = URL(fileURLWithPath: "/tmp/existing-gemma.gguf")
        let manager = FakeLocalAIModelManager(existingFileURL: existingURL)
        let settingsStore = OnboardingSettingsStore(defaults: defaults)
        let state = OnboardingState(
            settingsStore: settingsStore,
            networkSettingsStore: DemoSettingsStore(defaults: defaults),
            downloadManager: manager
        )

        #expect(state.installState == .verifying)
        for _ in 0..<20 where state.installState != .installed {
            await Task.yield()
        }

        #expect(state.installState == .installed)
        #expect(settingsStore.installedModelID == LocalAIModel.recommended.id)
        #expect(settingsStore.installedModelPath == existingURL.path)
        #expect(manager.verificationCount == 1)
        #expect(manager.downloadCount == 0)
    }

    @Test @MainActor func clickingTheSelectedModelNeverResetsItsInstallState() throws {
        let defaultsSuite = "OnboardingModelSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let state = OnboardingState(
            settingsStore: OnboardingSettingsStore(defaults: defaults),
            networkSettingsStore: DemoSettingsStore(defaults: defaults),
            downloadManager: FakeLocalAIModelManager(existingFileURL: nil)
        )
        let states: [OnboardingState.InstallState] = [
            .idle,
            .verifying,
            .installing(ModelDownloadProgress(
                completedBytes: 420,
                totalBytes: 1_000,
                bytesPerSecond: 100
            )),
            .installed,
            .failed("fixture"),
        ]
        for installState in states {
            state.installState = installState
            state.selectModel(.recommended)
            #expect(state.installState == installState)
        }
    }

    private func testModel(sha256: String) -> LocalAIModel {
        LocalAIModel(
            id: "test/model",
            name: "Test Model",
            size: "1 KB",
            detail: "Test fixture",
            tag: "GGUF",
            systemImage: "sparkles",
            artifactRepo: "test/model",
            artifactFileName: "tiny-model.gguf",
            artifactURL: URL(string: "https://example.invalid/tiny-model.gguf")!,
            sha256: sha256,
            memoryProfile: ModelMemoryProfile(
                weightBytes: 1_024,
                blockCount: 1,
                kvHeadCount: 1,
                keyLength: 1,
                valueLength: 1,
                trainedContextTokens: 4_096
            )
        )
    }
}

private final class FakeLocalAIModelManager: LocalAIModelManaging, @unchecked Sendable {
    let existingFileURL: URL?
    private(set) var verificationCount = 0
    private(set) var downloadCount = 0

    init(existingFileURL: URL?) {
        self.existingFileURL = existingFileURL
    }

    func existingFileURL(for model: LocalAIModel) -> URL? {
        existingFileURL
    }

    func verifyExistingFile(_ model: LocalAIModel, at fileURL: URL) async throws -> URL {
        verificationCount += 1
        return fileURL
    }

    func download(
        _ model: LocalAIModel,
        progress: @escaping LocalAIModelDownloadProgressHandler
    ) async throws -> URL {
        downloadCount += 1
        return existingFileURL ?? URL(fileURLWithPath: "/tmp/downloaded-model.gguf")
    }
}
