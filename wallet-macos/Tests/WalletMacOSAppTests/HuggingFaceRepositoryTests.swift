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

    private let gatedStringModelInfoJSON = """
    {"id":"meta-llama/Llama-4-GGUF","gated":"manual",
     "gguf":{"architecture":"llama4","context_length":8192}}
    """

    private let gatedAbsentModelInfoJSON = """
    {"id":"owner/name","gguf":{"architecture":"llama4","context_length":8192}}
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

    /// `gated` can also be a string like "auto"/"manual" instead of a bool — the
    /// polymorphic BoolOrString decoder exists precisely for this shape. A regression
    /// here would treat a gated repo as public and fail later with an opaque 401.
    @Test func gatedStringFormIsTreatedAsGated() throws {
        let info = try HuggingFaceRepository.decodeModelInfo(Data(gatedStringModelInfoJSON.utf8))
        #expect(info.isGated == true)
    }

    /// `gated` is absent entirely on most public repos.
    @Test func absentGatedKeyIsTreatedAsNotGated() throws {
        let info = try HuggingFaceRepository.decodeModelInfo(Data(gatedAbsentModelInfoJSON.utf8))
        #expect(info.isGated == false)
    }

    @Test func repoIDMustBeOwnerSlashName() throws {
        #expect(throws: HuggingFaceRepositoryError.self) {
            try HuggingFaceRepository.validate(repoID: "just-a-name")
        }
        #expect(throws: HuggingFaceRepositoryError.self) {
            try HuggingFaceRepository.validate(repoID: "https://huggingface.co/owner/name")
        }
        try #expect(HuggingFaceRepository.validate(repoID: " owner/name ") == "owner/name")
    }

    /// A pasted `#files-and-versions` fragment from a Hugging Face page must not
    /// silently truncate the interpolated request URL — reject it up front.
    @Test func repoIDWithFragmentIsRejected() {
        #expect(throws: HuggingFaceRepositoryError.malformedRepoID) {
            try HuggingFaceRepository.validate(repoID: "owner/name#files-and-versions")
        }
    }

    /// A `?query` suffix would similarly get swallowed by raw string interpolation
    /// into a URL — reject it rather than silently mis-routing the request.
    @Test func repoIDWithQueryIsRejected() {
        #expect(throws: HuggingFaceRepositoryError.malformedRepoID) {
            try HuggingFaceRepository.validate(repoID: "owner/name?x=1")
        }
    }

    /// Dot-segments satisfy the naive "two non-empty parts" rule but defeat the
    /// exact owner/name contract the validator exists to enforce.
    @Test func dotDotSegmentsAreRejected() {
        #expect(throws: HuggingFaceRepositoryError.malformedRepoID) {
            try HuggingFaceRepository.validate(repoID: "../..")
        }
    }

    /// A valid id, including the whitespace-trimming case, must still round-trip
    /// once the validator is tightened to an explicit character allowlist.
    @Test func validRepoIDStillRoundTrips() throws {
        try #expect(HuggingFaceRepository.validate(repoID: "owner/name") == "owner/name")
        try #expect(HuggingFaceRepository.validate(repoID: " owner/name ") == "owner/name")
        try #expect(HuggingFaceRepository.validate(repoID: "ggml-org/gemma-4-E4B-it-GGUF")
                    == "ggml-org/gemma-4-E4B-it-GGUF")
    }

    @Test func repoWithNoGGUFIsRejected() {
        let empty = """
        [{"type":"file","path":"model.safetensors","size":10}]
        """
        #expect(throws: HuggingFaceRepositoryError.noGGUFFiles) {
            _ = try HuggingFaceRepository.decodeTree(Data(empty.utf8), repoID: "r/x")
        }
    }

    /// The file `path` comes from the (untrusted) API response, not from the
    /// validator, so it must be percent-encoded before landing in a URL. `#` is
    /// not auto-encoded by `URL(string:)` on this platform (unlike a raw space) —
    /// it is parsed as the fragment delimiter, so raw interpolation silently
    /// truncates the path instead of producing a broken or nil URL.
    @Test func downloadURLPercentEncodesUnsafeCharactersInFilePath() throws {
        let json = """
        [{"type":"file","path":"weights#v2.gguf","size":10,
          "lfs":{"oid":"deadbeef","size":10}}]
        """
        let files = try HuggingFaceRepository.decodeTree(Data(json.utf8), repoID: "r/x")
        let file = try #require(files.first)
        #expect(file.downloadURL.absoluteString ==
                "https://huggingface.co/r/x/resolve/main/weights%23v2.gguf")
        #expect(file.downloadURL.fragment == nil)
    }
}
