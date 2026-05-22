import Foundation

public struct ChatMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable, Equatable {
        case system
        case user
        case assistant
        case tool
    }

    public let role: Role
    public let content: String?
    public let toolCalls: [ToolCall]?
    public let toolCallId: String?
    public let name: String?
    public let reasoning: String?

    public init(
        role: Role,
        content: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        name: String? = nil,
        reasoning: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
        self.reasoning = reasoning
    }
}

public struct ToolCall: Codable, Sendable, Equatable {
    public struct Function: Codable, Sendable, Equatable {
        public let name: String
        public let arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    public let id: String
    public let type: String
    public let function: Function

    public init(id: String, function: Function) {
        self.id = id
        self.type = "function"
        self.function = function
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case function
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.type = "function"
        self.function = try container.decode(Function.self, forKey: .function)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(function, forKey: .function)
    }
}

public struct ToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSONSchema: String

    public init(name: String, description: String, parametersJSONSchema: String) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
    }

    public static func toOpenAISchemaJSON(_ tools: [ToolDefinition]) -> String {
        let objects = tools.map { tool in
            """
            {"type":"function","function":{"name":\(quote(tool.name)),"description":\(quote(tool.description)),"parameters":\(tool.parametersJSONSchema)}}
            """
        }
        return "[\(objects.joined(separator: ","))]"
    }

    private static func quote(_ s: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(s.count + 2)

        for character in s {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.append(character)
            }
        }

        return "\"\(escaped)\""
    }
}

public struct SamplerOptions: Sendable, Equatable {
    public var temperature: Float
    public var topP: Float
    public var topK: Int32
    public var minP: Float
    public var repeatPenalty: Float
    public var maxTokens: Int32
    public var seed: UInt32
    public var stopSequences: [String]
    public var grammarGBNF: String?
    public var enableThinking: Bool

    public init() {
        self.temperature = 0.7
        self.topP = 0.95
        self.topK = 64
        self.minP = 0.05
        self.repeatPenalty = 1.0
        self.maxTokens = 512
        self.seed = 0
        self.stopSequences = []
        self.grammarGBNF = nil
        self.enableThinking = true
    }
}

public enum ChatEvent: Sendable {
    case textToken(String)
    case done(GenerationStats, stopReason: StopReason)
}

public enum StopReason: Sendable, Equatable {
    case endOfStream
    case maxTokens
    case stopSequence(String)
    case cancelled
}

public struct GenerationStats: Sendable, Equatable {
    public let promptTokens: Int
    public let generatedTokens: Int
    public let contextSize: Int
    public let duration: TimeInterval

    public init(
        promptTokens: Int,
        generatedTokens: Int,
        contextSize: Int,
        duration: TimeInterval
    ) {
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.contextSize = contextSize
        self.duration = duration
    }
}

public struct AudioAttachment: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}
