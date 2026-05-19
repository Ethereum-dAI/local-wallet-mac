import Foundation

public enum ToolExtractionError: Error, Equatable, Sendable {
    /// LlamaRuntime.parseAssistantTurn raised; message is the bridge's error string.
    case parseFailed(message: String)
    /// The bridge runtime is not loaded.
    case runtimeNotLoaded
}

public enum SlashParseError: Error, Equatable, Sendable {
    case unknownCommand(String)
    case missingRequiredArgument(String)
    case malformedArgument(String, value: String)
}
