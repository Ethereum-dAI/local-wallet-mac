import Foundation
import LocalLLM

public enum ToolDefinitions {
    public static let transfer = ToolDefinition(
        name: "transfer",
        description: """
        Send native ETH or an ERC-20 token from the user's smart account to a recipient.         Use this whenever the user expresses intent to send, transfer, pay, or move tokens         to an address, an ENS name (*.eth), or a saved contact name. If the recipient or         amount is missing or ambiguous, ask a clarifying question in natural language         instead of calling the tool.
        """,
        parametersJSONSchema: #"""
        {"type":"object","properties":{"to":{"type":"string","description":"Recipient. Accepts a 0x-prefixed 40-hex Ethereum address, an ENS name ending in .eth, or a contact name the user mentioned. Pass the value as the user expressed it - do not attempt to resolve ENS yourself."},"amount":{"type":"string","description":"Amount in human units as a decimal string (e.g. \"0.1\", \"100.5\"). Do not include the token symbol here. Use the literal string \"all\" if the user clearly intends to send their entire balance."},"token":{"type":"string","description":"Token symbol such as ETH, USDC, DAI, WETH, or a 0x-prefixed contract address. Default to ETH if the user does not name a token."}},"required":["to","amount"]}
        """#
    )

    public static let swap = ToolDefinition(
        name: "swap",
        description: """
        Exchange one token for another on the user's smart account. Use this whenever the         user expresses intent to swap, convert, exchange, trade, or change one token for         another. If the source or destination token is missing or ambiguous, ask a         clarifying question in natural language instead of calling the tool.
        """,
        parametersJSONSchema: #"""
        {"type":"object","properties":{"from_token":{"type":"string","description":"Token to spend. Symbol (ETH, USDC, DAI, WETH) or 0x-prefixed contract address."},"to_token":{"type":"string","description":"Token to receive. Symbol (ETH, USDC, DAI, WETH) or 0x-prefixed contract address."},"amount":{"type":"string","description":"Exact input amount to spend as a decimal string in human units. Do not use this tool when the user specifies only the desired output amount."},"amount_side":{"type":"string","enum":["input"],"description":"Always \"input\". Only exact-input swaps are supported."}},"required":["from_token","to_token","amount"]}
        """#
    )

    public static let shield = ToolDefinition(
        name: "shield",
        description: """
        Deposit ETH into the user's RAILGUN shielded (private) pool. Use this whenever the         user expresses intent to shield, make private, deposit into privacy, or hide funds.         Shielding is a public on-chain deposit signed by the user's own account. If the         amount is missing or ambiguous, ask a clarifying question in natural language         instead of calling the tool.
        """,
        parametersJSONSchema: #"""
        {"type":"object","properties":{"amount":{"type":"string","description":"Amount of ETH to shield, in human units as a decimal string (e.g. \"0.01\")."},"token":{"type":"string","description":"Token to shield. Only ETH is supported; default to ETH."}},"required":["amount"]}
        """#
    )

    public static let unshield = ToolDefinition(
        name: "unshield",
        description: """
        Withdraw ETH from the user's RAILGUN shielded (private) pool to a recipient as         native ETH. Use this whenever the user expresses intent to unshield, withdraw from         privacy, or make funds public again. The withdrawal is relayed by the wallet's own         local broadcaster. If the amount or recipient is missing or ambiguous, ask a         clarifying question in natural language instead of calling the tool.
        """,
        parametersJSONSchema: #"""
        {"type":"object","properties":{"amount":{"type":"string","description":"Amount of ETH to unshield, in human units as a decimal string (e.g. \"0.01\")."},"to":{"type":"string","description":"Recipient, as a 0x-prefixed 40-hex Ethereum address. ENS names and contact names are NOT yet supported for unshield - if the user gives one, ask them for the 0x address."},"token":{"type":"string","description":"Token to unshield. Only ETH is supported; default to ETH."}},"required":["amount","to"]}
        """#
    )

    public static let phase1: [ToolDefinition] = [transfer, swap, shield, unshield]

    public static let systemNudge: String = """
    When the user clearly expresses intent to perform an on-chain action (transfer, swap,     etc.), you MUST call the corresponding tool with structured arguments instead of     describing the action in prose. If essential information is missing, ask one short     clarifying question in natural language and wait for the answer before calling the     tool. Never invent recipient addresses, ENS names, contact names, token symbols, or     amounts that the user has not provided.
    """
}
