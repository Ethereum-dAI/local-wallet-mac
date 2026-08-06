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
