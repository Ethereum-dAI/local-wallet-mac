import Foundation
import Testing
@testable import LocalLLM
import CLlamaBridge

@Test func chatTemplateMetadataIsAvailableAfterLoad() async throws {
    guard let runtime = try sharedLoadedRuntime() else { return }

    let template = runtime.embeddedChatTemplate
    #expect(template != nil)
    #expect(template?.contains("<|tool_call>") == true)
    #expect(template?.contains("format_function_declaration") == true)
}
