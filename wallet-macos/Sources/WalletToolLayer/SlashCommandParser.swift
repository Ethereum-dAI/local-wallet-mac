import Foundation

public struct SlashCommandParser: Sendable {
    public init() {}

    public func parse(_ raw: String) throws -> ToolIntent {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            throw SlashParseError.unknownCommand(trimmed)
        }
        let withoutSlash = String(trimmed.dropFirst())
        let split = withoutSlash.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).map(String.init)
        let name = split.first ?? ""
        let rest = split.count > 1 ? split[1] : ""

        switch name {
        case "transfer":
            return try parseTransfer(rest: rest)
        case "swap":
            return try parseSwap(rest: rest)
        case "shield":
            return try parseShield(rest: rest)
        default:
            throw SlashParseError.unknownCommand("/" + name)
        }
    }

    // /shield <amount> [ETH]  — native ETH only, so a trailing token is ignored.
    private func parseShield(rest: String) throws -> ToolIntent {
        if rest.contains("=") {
            let args = try parseKeyValueArgs(rest, allowedKeys: ["amount"])
            try require(args, key: "amount")
            return ToolIntent(tool: .shield, args: args, source: .slash)
        }
        let tokens = rest.split(separator: " ").map(String.init)
        guard let amount = tokens.first, !amount.isEmpty else {
            throw SlashParseError.missingRequiredArgument("amount")
        }
        return ToolIntent(tool: .shield, args: ["amount": amount], source: .slash)
    }

    private func parseTransfer(rest: String) throws -> ToolIntent {
        if rest.contains("=") {
            let args = try parseKeyValueArgs(rest, allowedKeys: ["to", "amount", "token"])
            try require(args, key: "to")
            try require(args, key: "amount")
            var withDefaults = args
            if withDefaults["token"] == nil { withDefaults["token"] = "ETH" }
            return ToolIntent(tool: .transfer, args: withDefaults, source: .slash)
        }
        guard let toRange = rest.range(of: " to ") else {
            throw SlashParseError.missingRequiredArgument("to")
        }
        let left = rest[..<toRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let right = rest[toRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !right.isEmpty else { throw SlashParseError.missingRequiredArgument("to") }
        let leftTokens = left.split(separator: " ").map(String.init)
        let amount: String
        let token: String
        switch leftTokens.count {
        case 0:
            throw SlashParseError.missingRequiredArgument("amount")
        case 1:
            amount = leftTokens[0]
            token = "ETH"
        default:
            amount = leftTokens[0]
            token = leftTokens[1]
        }
        return ToolIntent(tool: .transfer, args: ["amount": amount, "token": token, "to": right], source: .slash)
    }

    private func parseSwap(rest: String) throws -> ToolIntent {
        if rest.contains("=") {
            let args = try parseKeyValueArgs(rest, allowedKeys: ["from_token", "to_token", "amount", "amount_side"])
            try require(args, key: "from_token")
            try require(args, key: "to_token")
            try require(args, key: "amount")
            var withDefaults = args
            if withDefaults["amount_side"] == nil { withDefaults["amount_side"] = "input" }
            guard withDefaults["amount_side"]?.lowercased() == "input" else {
                throw SlashParseError.malformedArgument("amount_side", value: "only input is supported")
            }
            return ToolIntent(tool: .swap, args: withDefaults, source: .slash)
        }
        guard let toRange = rest.range(of: " to ") else {
            throw SlashParseError.missingRequiredArgument("to_token")
        }
        let left = rest[..<toRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let right = rest[toRange.upperBound...].trimmingCharacters(in: .whitespaces)
        let leftTokens = left.split(separator: " ").map(String.init)
        guard leftTokens.count >= 2 else {
            throw SlashParseError.missingRequiredArgument("from_token")
        }
        guard !right.isEmpty else {
            throw SlashParseError.missingRequiredArgument("to_token")
        }
        return ToolIntent(
            tool: .swap,
            args: ["amount": leftTokens[0], "from_token": leftTokens[1], "to_token": right, "amount_side": "input"],
            source: .slash
        )
    }

    private func parseKeyValueArgs(_ s: String, allowedKeys: [String]) throws -> [String: String] {
        var args: [String: String] = [:]
        let fragments = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for f in fragments {
            guard let eq = f.firstIndex(of: "=") else {
                throw SlashParseError.malformedArgument(f, value: "missing =")
            }
            let key = String(f[..<eq])
            let val = String(f[f.index(after: eq)...])
            guard allowedKeys.contains(key) else {
                throw SlashParseError.malformedArgument(key, value: "unknown key")
            }
            args[key] = val
        }
        return args
    }

    private func require(_ args: [String: String], key: String) throws {
        if args[key] == nil { throw SlashParseError.missingRequiredArgument(key) }
    }
}
