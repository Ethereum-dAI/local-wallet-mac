import Foundation
import WalletToolLayer

struct ToolIntentFeedback: Codable, Equatable, Identifiable {
    enum Rating: String, Codable {
        case thumbsUp = "thumbs_up"
        case thumbsDown = "thumbs_down"
    }

    var id: UUID
    var conversationID: UUID
    var messageID: UUID
    var intentID: UUID
    var tool: ToolIntent.Tool
    var prompt: String
    var args: [String: String]
    var rating: Rating
    var note: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        messageID: UUID,
        intentID: UUID,
        tool: ToolIntent.Tool,
        prompt: String,
        args: [String: String],
        rating: Rating,
        note: String?,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
        self.intentID = intentID
        self.tool = tool
        self.prompt = prompt
        self.args = args
        self.rating = rating
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ToolIntentFeedbackExportRecord: Codable, Equatable {
    let id: UUID
    let conversationID: UUID
    let conversationTitle: String
    let messageID: UUID
    let intentID: UUID
    let tool: String
    let prompt: String
    let parameters: [String: String]
    let valuation: String
    let notes: String?
    let createdAt: Date
    let updatedAt: Date
}
