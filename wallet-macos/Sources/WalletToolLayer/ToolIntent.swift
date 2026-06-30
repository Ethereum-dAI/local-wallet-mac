import Foundation

public struct ToolIntent: Codable, Equatable, Identifiable, Sendable {
    public enum Tool: String, Codable, Sendable {
        case transfer, swap, shield
    }

    public enum Source: String, Codable, Sendable {
        case model
        case slash
    }

    public enum Disposition: String, Codable, Sendable {
        case pending
        case confirmed
        case edited
        case rejected
    }

    public var id: UUID
    public var tool: Tool
    public var args: [String: String]
    public var rawDSL: String?
    public var source: Source
    public var disposition: Disposition
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        tool: Tool,
        args: [String: String],
        rawDSL: String? = nil,
        source: Source,
        disposition: Disposition = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.tool = tool
        self.args = args
        self.rawDSL = rawDSL
        self.source = source
        self.disposition = disposition
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
