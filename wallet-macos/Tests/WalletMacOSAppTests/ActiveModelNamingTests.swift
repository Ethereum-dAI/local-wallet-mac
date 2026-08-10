import Foundation
import Testing
@testable import WalletMacOSApp

/// The chat called the model "Gemma" in six hardcoded places, written when Gemma
/// was the only option. Switching to Qwen changed the runtime and nothing the user
/// could see. The name now comes from here.
struct ActiveModelNamingTests {
    private func custom(id: String, name: String) -> InstalledModel {
        InstalledModel(
            id: id,
            displayName: name,
            repoID: "owner/repo",
            fileName: "m.gguf",
            path: "/tmp/m.gguf",
            sizeBytes: 1,
            sha256: nil,
            profile: nil
        )
    }

    @Test func theSecondCuratedModelIsNamedRatherThanTheDefault() {
        let name = ActiveModelNaming.displayName(
            forModelID: LocalAIModel.qwen3.id,
            installed: []
        )
        #expect(name == LocalAIModel.qwen3.name)
        #expect(name != LocalAIModel.recommended.name)
    }

    @Test func theDefaultIsNamedWhenItIsSelected() {
        #expect(ActiveModelNaming.displayName(forModelID: LocalAIModel.recommended.id, installed: [])
            == LocalAIModel.recommended.name)
    }

    /// A Hugging Face model is not in the curated list; its name comes from the
    /// install record.
    @Test func aCustomModelUsesItsInstalledName() {
        let installed = [custom(id: "owner/repo#file.gguf", name: "file")]
        #expect(ActiveModelNaming.displayName(forModelID: "owner/repo#file.gguf", installed: installed) == "file")
    }

    /// An id can outlive its model — removed on a previous launch. The chat still
    /// needs something to call itself.
    @Test func anUnknownIDFallsBackToTheDefaultRatherThanEmpty() {
        let name = ActiveModelNaming.displayName(forModelID: "gone/missing", installed: [])
        #expect(name == LocalAIModel.recommended.name)
        #expect(name.isEmpty == false)
    }

    /// Curated wins over an install record with the same id, so a curated model's
    /// shipped name is what shows even after it has been downloaded.
    @Test func curatedNamesWinOverInstallRecords() {
        let installed = [custom(id: LocalAIModel.qwen3.id, name: "Qwen3-8B-Q4_K_M")]
        #expect(ActiveModelNaming.displayName(forModelID: LocalAIModel.qwen3.id, installed: installed)
            == LocalAIModel.qwen3.name)
    }
}
