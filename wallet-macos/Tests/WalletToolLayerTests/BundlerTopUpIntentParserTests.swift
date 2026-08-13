import Testing
@testable import WalletToolLayer

@Test func canonicalBundlerTopUpPhraseParsesWithoutDestination() throws {
    let intent = try #require(
        BundlerTopUpIntentParser.parse("Top up the bundler with 0.01 ETH")
    )

    #expect(intent.tool == .topUpBundler)
    #expect(intent.args == ["amount": "0.01"])
    #expect(intent.args["to"] == nil)
    #expect(intent.source == .model)
}

@Test func bundlerTopUpParserAcceptsOnlyExplicitProductPhrases() throws {
    let fund = try #require(BundlerTopUpIntentParser.parse("fund bundler with 0.02 eth"))
    #expect(fund.args == ["amount": "0.02"])

    let refill = try #require(BundlerTopUpIntentParser.parse("  Refill the bundler 1 ETH  "))
    #expect(refill.args == ["amount": "1"])
}

@Test func bundlerTopUpParserRejectsMissingOrInvalidAmount() {
    #expect(BundlerTopUpIntentParser.parse("Top up the bundler") == nil)
    #expect(BundlerTopUpIntentParser.parse("Top up the bundler with -1 ETH") == nil)
    #expect(BundlerTopUpIntentParser.parse("Top up the bundler with 0 ETH") == nil)
    #expect(BundlerTopUpIntentParser.parse("Top up the bundler with all ETH") == nil)
    #expect(BundlerTopUpIntentParser.parse("Top up the bundler with 1e2 ETH") == nil)
    #expect(BundlerTopUpIntentParser.parse("Top up the bundler with 1_000 ETH") == nil)
    #expect(BundlerTopUpIntentParser.parse("Top up the bundler with 1ETHjunk") == nil)
    #expect(BundlerTopUpIntentParser.parse("Top up the bundler with 1.1234567890123456789 ETH") == nil)
}

@Test func bundlerTopUpParserRejectsGenericTransfersAndInjectedDestinations() {
    #expect(BundlerTopUpIntentParser.parse("Send 0.01 ETH to vitalik.eth") == nil)
    #expect(
        BundlerTopUpIntentParser.parse(
            "Top up the bundler with 0.01 ETH to 0x1111111111111111111111111111111111111111"
        ) == nil
    )
}
