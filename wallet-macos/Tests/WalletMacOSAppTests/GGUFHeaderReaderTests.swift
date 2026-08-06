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

    // MARK: - Malicious/corrupted length fields (attacker-controlled bytes must
    // never trap the process; they must throw GGUFHeaderError.truncated).

    @Test func stringLengthOfUInt64MaxThrowsRatherThanTraps() {
        var data = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        u32(3)                  // version
        u64(1)                  // tensor count
        u64(1)                  // kv count
        u64(UInt64.max)         // key length -- Int(UInt64.max) traps if not guarded

        #expect(throws: GGUFHeaderError.self) {
            try GGUFHeaderReader.parse(data)
        }
    }

    @Test func plausibleButTooLargeLengthThrowsRatherThanTraps() {
        var data = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        u32(3)                              // version
        u64(1)                              // tensor count
        u64(1)                              // kv count
        u64(UInt64(Int.max - 5))            // fits as Int, but offset + count overflows Int

        #expect(throws: GGUFHeaderError.self) {
            try GGUFHeaderReader.parse(data)
        }
    }

    /// NOTE on what this proves and what it doesn't: with zero bytes left after
    /// the count field, the very first (and only) inner element read fails via
    /// the ordinary "ran out of buffer" bounds check in `take(_:)` -- it cannot
    /// distinguish "the O(1) `count <= remaining` guard fired" from "the loop
    /// ran once and then hit normal truncation on its first read". It only
    /// proves `.truncated` is thrown, not that the guard is what caused it.
    /// `arrayCountVastlyExceedingBufferThrowsPromptlyEvenWithSubstantialTrailingData`
    /// below adds a buffer with real trailing data to at least rule out "only
    /// works when the buffer is trivially short".
    @Test func arrayCountVastlyExceedingBufferThrowsTruncated() {
        var data = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func str(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); data.append(contentsOf: b) }
        u32(3)                       // version
        u64(1)                       // tensor count
        u64(1)                       // kv count
        str("bogus.array")
        u32(9)                       // value type: array
        u32(4)                       // element type: u32 (4 bytes each)
        u64(UInt64(Int64.max))       // declared count vastly exceeds the remaining buffer

        #expect(throws: GGUFHeaderError.self) {
            try GGUFHeaderReader.parse(data)
        }
    }

    /// Strengthens the test above by leaving ~1 MB (250k) of genuinely
    /// well-formed `u32` elements after the declared count, so an unguarded
    /// implementation would have to iterate through all of them (rather than
    /// failing on the very first read) before it could exhaust the buffer and
    /// throw.
    ///
    /// What this proves: parsing an array whose declared count vastly exceeds
    /// the buffer still throws `.truncated` promptly, even when the buffer has
    /// substantial real trailing data to loop over -- i.e. it isn't only
    /// "works because there's nothing there to loop through".
    ///
    /// What this does NOT prove: that the `count <= remaining` guard is
    /// genuinely O(1) rather than O(n). At a scale an in-process unit test can
    /// afford without becoming slow or flaky (~250k cheap element reads, each
    /// just a 4-byte bounds-checked load), Swift completes the *unguarded*
    /// loop in the low tens of milliseconds on this hardware -- both a guarded
    /// and an unguarded implementation would clear the generous 2-second
    /// ceiling below. Telling O(1) apart from O(n) at this scale would need a
    /// wall-clock micro-benchmark comparing against a hand-reverted copy of
    /// the guard, which is a different kind of check than a unit test's
    /// pass/fail assertion. The timing assertion here is a hang/regression
    /// guard (catches a truly pathological blowup, e.g. an accidental
    /// quadratic-time bug), not proof of the guard's complexity class.
    @Test func arrayCountVastlyExceedingBufferThrowsPromptlyEvenWithSubstantialTrailingData() {
        var data = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func str(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); data.append(contentsOf: b) }
        u32(3)                       // version
        u64(1)                       // tensor count
        u64(1)                       // kv count
        str("bogus.array")
        u32(9)                       // value type: array
        u32(4)                       // element type: u32 (4 bytes each)
        u64(UInt64(Int64.max))       // declared count still vastly exceeds even this buffer
        data.append(Data(count: 1_000_000))   // ~250k well-formed-looking u32 elements

        let start = Date()
        #expect(throws: GGUFHeaderError.self) {
            try GGUFHeaderReader.parse(data)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "parsing an oversized array declaration took \(elapsed)s -- that smells like a hang")
    }

    @Test func u64ValueAboveIntMaxIsSkippedNotStoredAndCursorStaysInSync() throws {
        var data = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func str(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); data.append(contentsOf: b) }
        u32(3); u64(1); u64(3)
        str("general.architecture"); u32(8); str("gemma4")
        str("gemma4.huge_u64"); u32(10); u64(UInt64.max)   // Int(UInt64.max) traps if not guarded
        str("gemma4.block_count"); u32(4); u32(42)          // proves the cursor resynced afterwards

        let header = try GGUFHeaderReader.parse(data)
        #expect(header.integer("gemma4.huge_u64") == nil)
        #expect(header.integer("gemma4.block_count") == 42)
    }

    @Test func signedNarrowIntegersSignExtendCorrectly() throws {
        var data = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func str(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); data.append(contentsOf: b) }
        u32(3); u64(1); u64(3)
        str("general.architecture"); u32(8); str("gemma4")
        str("gemma4.some_i8"); u32(1); data.append(UInt8(bitPattern: -1))                // i8 = -1
        str("gemma4.some_i16"); u32(3)
        withUnsafeBytes(of: Int16(-1).littleEndian) { data.append(contentsOf: $0) }        // i16 = -1

        let header = try GGUFHeaderReader.parse(data)
        #expect(header.integer("gemma4.some_i8") == -1)
        #expect(header.integer("gemma4.some_i16") == -1)
    }
}
