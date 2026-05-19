import Foundation
import Testing
@testable import WalletToolLayer

@Test func parsesTransferPositionalShorthand() throws {
    let intent = try SlashCommandParser().parse("/transfer 0.1 ETH to vitalik.eth")

    #expect(intent.tool == .transfer)
    #expect(intent.source == .slash)
    #expect(intent.args == ["amount": "0.1", "token": "ETH", "to": "vitalik.eth"])
}

@Test func parsesTransferKeyValue() throws {
    let intent = try SlashCommandParser().parse("/transfer to=vitalik.eth amount=0.1 token=USDC")

    #expect(intent.tool == .transfer)
    #expect(intent.source == .slash)
    #expect(intent.args == ["to": "vitalik.eth", "amount": "0.1", "token": "USDC"])
}

@Test func parsesSwapPositionalShorthand() throws {
    let intent = try SlashCommandParser().parse("/swap 0.1 ETH to USDC")

    #expect(intent.tool == .swap)
    #expect(intent.source == .slash)
    #expect(intent.args == ["amount": "0.1", "from_token": "ETH", "to_token": "USDC", "amount_side": "input"])
}

@Test func parsesSwapKeyValue() throws {
    let intent = try SlashCommandParser().parse("/swap from_token=ETH to_token=USDC amount=0.1 amount_side=output")

    #expect(intent.tool == .swap)
    #expect(intent.source == .slash)
    #expect(intent.args == ["from_token": "ETH", "to_token": "USDC", "amount": "0.1", "amount_side": "output"])
}

@Test func unknownCommandThrows() {
    expectSlashParseError(try SlashCommandParser().parse("/balance")) { error in
        guard case .unknownCommand("/balance") = error else { return false }
        return true
    }
}

@Test func missingArgumentsThrows() {
    expectSlashParseError(try SlashCommandParser().parse("/transfer 0.1 ETH")) { error in
        guard case .missingRequiredArgument("to") = error else { return false }
        return true
    }

    expectSlashParseError(try SlashCommandParser().parse("/swap 0.1 to USDC")) { error in
        guard case .missingRequiredArgument("from_token") = error else { return false }
        return true
    }
}

@Test func transferDefaultsTokenToETH() throws {
    let positional = try SlashCommandParser().parse("/transfer 0.1 to vitalik.eth")
    let keyValue = try SlashCommandParser().parse("/transfer to=vitalik.eth amount=0.1")

    #expect(positional.args["token"] == "ETH")
    #expect(keyValue.args["token"] == "ETH")
}

@Test func nonSlashThrowsUnknownCommand() {
    expectSlashParseError(try SlashCommandParser().parse("transfer 0.1 ETH to vitalik.eth")) { error in
        guard case .unknownCommand("transfer 0.1 ETH to vitalik.eth") = error else { return false }
        return true
    }
}

@Test func unknownKVKeyThrows() {
    expectSlashParseError(try SlashCommandParser().parse("/transfer recipient=vitalik.eth amount=0.1")) { error in
        guard case .malformedArgument("recipient", value: "unknown key") = error else { return false }
        return true
    }
}

private func expectSlashParseError(
    _ expression: @autoclosure () throws -> ToolIntent,
    matches: (SlashParseError) -> Bool
) {
    do {
        _ = try expression()
        Issue.record("Expected SlashParseError")
    } catch let error as SlashParseError {
        #expect(matches(error))
    } catch {
        Issue.record("Expected SlashParseError, got \(error)")
    }
}
