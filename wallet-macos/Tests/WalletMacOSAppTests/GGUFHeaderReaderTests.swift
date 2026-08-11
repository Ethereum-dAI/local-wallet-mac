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

/// Serves a fixed body over a stubbed URL protocol so the ranged header probe can
/// be exercised without a network. Serialized because the stub's configuration is
/// necessarily static — `URLProtocol` subclasses are instantiated by URLSession.
@Suite(.serialized)
struct GGUFHeaderFetchTests {
    /// Same shape as `GGUFHeaderReaderTests.fixture`, kept local so the two suites
    /// do not share mutable state.
    private func fixture() -> Data {
        var data = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func str(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); data.append(contentsOf: b) }
        u32(3); u64(666); u64(6)
        str("general.architecture"); u32(8); str("gemma4")
        str("gemma4.block_count"); u32(4); u32(42)
        str("gemma4.context_length"); u32(4); u32(131_072)
        str("gemma4.attention.head_count_kv"); u32(4); u32(2)
        str("gemma4.attention.key_length"); u32(4); u32(512)
        str("gemma4.attention.value_length"); u32(4); u32(512)
        return data
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeStubProtocol.self]
        return configuration
    }

    private let url = URL(string: "https://huggingface.co/owner/repo/resolve/main/model.gguf")!

    @Test func readsTheHeaderFromThePrefixOfARangedResponse() async throws {
        // The "file" is far larger than its header: the probe must come back with
        // a usable profile without the rest ever being transferred.
        RangeStubProtocol.reset(body: fixture() + Data(count: 4_000_000), status: 206)
        let header = try await GGUFHeaderReader.fetch(from: url, configuration: configuration())
        #expect(header.architecture == "gemma4")
        #expect(header.memoryProfile(weightBytes: 4_590_807_392)?.blockCount == 42)
        #expect(RangeStubProtocol.observedRangeHeaders == ["bytes=0-\(GGUFHeaderReader.headerProbeBytes - 1)"])
    }

    /// The whole point of the probe: a host that ignores `Range` and starts
    /// streaming the entire model must be refused, not buffered into RAM.
    @Test func refusesAHostThatIgnoresTheRangeHeader() async {
        RangeStubProtocol.reset(body: fixture(), status: 200)
        await #expect(throws: GGUFHeaderError.rangeNotSupported(status: 200)) {
            try await GGUFHeaderReader.fetch(from: url, configuration: configuration())
        }
    }

    @Test func aShortPartialResponseIsReportedAsTruncatedNotParsedAsGarbage() async {
        RangeStubProtocol.reset(body: fixture().prefix(40), status: 206)
        await #expect(throws: GGUFHeaderError.truncated) {
            try await GGUFHeaderReader.fetch(from: url, configuration: configuration())
        }
    }

    @Test func aServerErrorIsSurfacedWithItsStatus() async {
        RangeStubProtocol.reset(body: Data(), status: 403)
        await #expect(throws: GGUFHeaderError.rangeNotSupported(status: 403)) {
            try await GGUFHeaderReader.fetch(from: url, configuration: configuration())
        }
    }
}

/// Replays a canned body and status for any request. `nonisolated(unsafe)` static
/// state is unavoidable — URLSession owns the instantiation — hence the
/// `.serialized` suite above.
final class RangeStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var status = 206
    nonisolated(unsafe) private(set) static var observedRangeHeaders: [String] = []

    static func reset(body: any DataProtocol, status: Int) {
        self.body = Data(body)
        self.status = status
        observedRangeHeaders = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let range = request.value(forHTTPHeaderField: "Range") {
            Self.observedRangeHeaders.append(range)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The GGUF value types 1/3/5/11 decode as genuinely signed, and the parser is
/// fed bytes from any repository a user pastes into Add From Hugging Face. A
/// negative or absurd attention dimension therefore has to end as "Size unknown",
/// because every consumer downstream converts these to `UInt64` and multiplies
/// them — and because `InstalledModelStore` would persist the bad profile and
/// replay it on every launch.
struct GGUFHostileHeaderTests {
    private func header(blockCount: Int32) throws -> GGUFHeader {
        var data = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func str(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); data.append(contentsOf: b) }

        u32(3); u64(1); u64(5)
        str("general.architecture"); u32(8); str("gemma4")
        // Type 5 is int32: the bit pattern is decoded as signed.
        str("gemma4.block_count"); u32(5); u32(UInt32(bitPattern: blockCount))
        str("gemma4.attention.head_count_kv"); u32(4); u32(2)
        str("gemma4.attention.key_length"); u32(4); u32(512)
        str("gemma4.attention.value_length"); u32(4); u32(512)
        return try GGUFHeaderReader.parse(data)
    }

    @Test func aNegativeBlockCountYieldsNoProfileRatherThanTrapping() throws {
        let parsed = try header(blockCount: -1)
        #expect(parsed.integer("gemma4.block_count") == -1)
        #expect(parsed.memoryProfile(weightBytes: 4_000_000_000) == nil)
    }

    @Test func anAbsurdBlockCountYieldsNoProfile() throws {
        #expect(try header(blockCount: .max).memoryProfile(weightBytes: 4_000_000_000) == nil)
    }

    @Test func aZeroBlockCountYieldsNoProfile() throws {
        #expect(try header(blockCount: 0).memoryProfile(weightBytes: 4_000_000_000) == nil)
    }

    /// Each nesting level costs only 12 header bytes and passes the
    /// remaining-budget guard, so without a depth cap a small header recurses
    /// deep enough to overflow the stack — a SIGSEGV no `catch` can see.
    @Test func deeplyNestedArraysThrowRatherThanOverflowingTheStack() {
        var data = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func str(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); data.append(contentsOf: b) }

        u32(3); u64(1); u64(1)
        str("nested"); u32(9)
        // A chain of singleton arrays: each level declares element type 9 (array)
        // and a count of 1, so it costs 12 bytes and recurses once. 20_000 levels
        // is ~240 KB of header and ~20_000 stack frames.
        for _ in 0..<20_000 { u32(9); u64(1) }
        u32(4); u64(1); u32(7)   // innermost: an array of one uint32

        #expect(throws: GGUFHeaderError.arrayNestingTooDeep) {
            try GGUFHeaderReader.parse(data)
        }
    }

    /// One level of nesting is real GGUF (an array of arrays of tokens), so the
    /// cap must not reject it.
    @Test func aSinglyNestedArrayStillParses() throws {
        var data = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func str(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); data.append(contentsOf: b) }

        u32(3); u64(1); u64(2)
        str("outer"); u32(9); u32(9); u64(2)
        u32(4); u64(1); u32(11)
        u32(4); u64(1); u32(12)
        str("general.architecture"); u32(8); str("gemma4")

        #expect(try GGUFHeaderReader.parse(data).architecture == "gemma4")
    }
}

/// A bad profile persisted by an earlier build is replayed from
/// `InstalledModelStore` on every launch, so the evaluator has to survive one
/// even though the parser now refuses to produce it.
struct ModelFitEvaluatorHostileProfileTests {
    private func profile(blockCount: Int) -> ModelMemoryProfile {
        ModelMemoryProfile(
            weightBytes: 4_000_000_000,
            blockCount: blockCount,
            kvHeadCount: 2,
            keyLength: 512,
            valueLength: 512,
            trainedContextTokens: 8192
        )
    }

    @Test func aNegativeDimensionDoesNotTrap() {
        let bad = profile(blockCount: -1)
        #expect(bad.isWellFormed == false)
        #expect(ModelFitEvaluator.kvCacheBytes(profile: bad, contextTokens: 8192) == .max)
        #expect(ModelFitEvaluator.requiredBytes(profile: bad, contextTokens: 8192) > 0)
    }

    @Test func anUnmeasurableProfileReadsAsUnknownNotAsAFit() {
        let verdict = ModelFitEvaluator.verdict(
            profile: profile(blockCount: -1),
            contextTokens: 8192,
            budget: HardwareBudget(
                totalMemoryBytes: 64 * 1_073_741_824,
                metalBudgetBytes: 48 * 1_073_741_824,
                freeDiskBytes: 500 * 1_073_741_824
            )
        )
        #expect(verdict == .unknown)
    }

    @Test func anEnormousButWellFormedProfileSaturatesInsteadOfOverflowing() {
        let huge = ModelMemoryProfile(
            weightBytes: .max,
            blockCount: 65_536,
            kvHeadCount: 65_536,
            keyLength: 65_536,
            valueLength: 65_536,
            trainedContextTokens: 131_072
        )
        #expect(ModelFitEvaluator.requiredBytes(profile: huge, contextTokens: 131_072) == .max)
        #expect(ModelFitEvaluator.minimumMemoryBytes(profile: huge, contextTokens: 131_072, comfortable: true) > 0)
    }
}
