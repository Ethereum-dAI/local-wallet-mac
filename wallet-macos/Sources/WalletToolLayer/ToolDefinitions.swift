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
        {"type":"object","properties":{"from_token":{"type":"string","description":"Token to spend. Symbol (ETH, USDC, DAI, WETH) or 0x-prefixed contract address."},"to_token":{"type":"string","description":"Token to receive. Symbol (ETH, USDC, DAI, WETH) or 0x-prefixed contract address."},"amount":{"type":"string","description":"Amount as a decimal string in human units. Whether this refers to the input or the output is given by the amount_side argument."},"amount_side":{"type":"string","enum":["input","output"],"description":"\"input\" when the user is specifying how much to spend (e.g. \"swap 100 USDC for ETH\"); \"output\" when the user is specifying how much to receive (e.g. \"buy me 1 ETH with USDC\"). Default to \"input\" when ambiguous."}},"required":["from_token","to_token","amount"]}
        """#
    )

    public static let phase1: [ToolDefinition] = [transfer, swap]

    public static let systemNudge: String = """
    When the user clearly expresses intent to perform an on-chain action (transfer, swap,     etc.), you MUST call the corresponding tool with structured arguments instead of     describing the action in prose. If essential information is missing, ask one short     clarifying question in natural language and wait for the answer before calling the     tool. Never invent recipient addresses, ENS names, contact names, token symbols, or     amounts that the user has not provided.
    """
}
