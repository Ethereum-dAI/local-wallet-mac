import Foundation
import Testing
@testable import LocalLLM
import CLlamaBridge

@Test func countsExactBytesWithoutWrappingInPromptTemplate() async throws {
    guard let runtime = try sharedLoadedRuntime() else { return }

    var errorBuffer = [CChar](repeating: 0, count: 1024)
    let count = errorBuffer.withUnsafeMutableBufferPointer { buffer in
        "hello world".withCString { text in
            lllm_count_tokens(
                runtime.bridgeHandle,
                text,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
    }

    #expect(count > 0)
    #expect(count < 10)
}
