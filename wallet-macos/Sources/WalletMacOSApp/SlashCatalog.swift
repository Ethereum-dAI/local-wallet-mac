import Foundation

struct SlashCommand: Identifiable, Equatable {
    let id: String
    let displayName: String
    let summary: String
    let signature: String
    let scaffold: String
    let firstPlaceholder: String?
}

enum SlashCatalog {
    static let all: [SlashCommand] = [
        SlashCommand(
            id: "transfer",
            displayName: "/transfer",
            summary: "Send ETH or an ERC-20 token to an address or ENS name",
            signature: "/transfer <amount> <token> to <recipient>",
            scaffold: "/transfer 0.1 ETH to <recipient>",
            firstPlaceholder: "<recipient>"
        ),
        SlashCommand(
            id: "swap",
            displayName: "/swap",
            summary: "Exchange one token for another on your smart account",
            signature: "/swap <amount> <from_token> to <to_token>",
            scaffold: "/swap 100 USDC to ETH",
            firstPlaceholder: nil
        ),
        SlashCommand(
            id: "shield",
            displayName: "/shield",
            summary: "Deposit ETH into your RAILGUN shielded (private) pool",
            signature: "/shield <amount> [ETH]",
            scaffold: "/shield 0.01",
            firstPlaceholder: nil
        ),
        SlashCommand(
            id: "unshield",
            displayName: "/unshield",
            summary: "Withdraw ETH from the shielded pool to a recipient as native ETH",
            signature: "/unshield <amount> to <recipient-0x-address>",
            scaffold: "/unshield 0.01 to <recipient>",
            firstPlaceholder: "<recipient>"
        )
    ]

    static func suggestions(for input: String) -> [SlashCommand] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            return []
        }
        let afterSlash = String(trimmed.dropFirst())
        if afterSlash.contains(where: { $0.isWhitespace }) {
            return []
        }
        let needle = afterSlash.lowercased()
        if needle.isEmpty {
            return all
        }
        return all.filter { $0.id.hasPrefix(needle) }
    }
}
