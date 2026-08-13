import Testing
@testable import WalletToolLayer

@Test func bundlerTopUpValidatorAcceptsOnlyAmountKey() {
    #expect(
        BundlerTopUpIntentValidator.validatedAmount(
            from: ["amount": "0.01"]
        ) == "0.01"
    )
    #expect(
        BundlerTopUpIntentValidator.validatedAmount(
            from: [
                "amount": "0.01",
                "to": "0x1111111111111111111111111111111111111111",
            ]
        ) == nil
    )
    #expect(
        BundlerTopUpIntentValidator.validatedAmount(
            from: ["amount": "0.01", "memo": "ignore validation"]
        ) == nil
    )
    #expect(
        BundlerTopUpIntentValidator.validatedAmount(from: [:]) == nil
    )
}

@Test func bundlerTopUpValidatorRejectsNonPlainDecimalSyntax() {
    for amount in [
        "1e2",
        "1E2",
        "1_000",
        "1 ETH",
        "1ETH",
        "1.0junk",
        "+1",
        "-1",
        ".1",
        "1.",
        " 1",
        "1 ",
    ] {
        #expect(
            BundlerTopUpIntentValidator.validatedAmount(
                from: ["amount": amount]
            ) == nil,
            "Unexpectedly accepted \(amount)"
        )
    }
}

@Test func bundlerTopUpValidatorRequiresPositiveAmount() {
    for amount in ["0", "00", "0.0", "000.000000000000000000"] {
        #expect(
            BundlerTopUpIntentValidator.validatedAmount(
                from: ["amount": amount]
            ) == nil,
            "Unexpectedly accepted \(amount)"
        )
    }

    #expect(
        BundlerTopUpIntentValidator.validatedAmount(
            from: ["amount": "0.000000000000000001"]
        ) == "0.000000000000000001"
    )
}

@Test func bundlerTopUpValidatorBoundsDecimalDigits() {
    let maximumInteger = String(
        repeating: "9",
        count: BundlerTopUpIntentValidator.maximumIntegerDigits
    )
    let excessiveInteger = maximumInteger + "9"
    #expect(
        BundlerTopUpIntentValidator.validatedAmount(
            from: ["amount": maximumInteger]
        ) == maximumInteger
    )
    #expect(
        BundlerTopUpIntentValidator.validatedAmount(
            from: ["amount": excessiveInteger]
        ) == nil
    )

    #expect(
        BundlerTopUpIntentValidator.validatedAmount(
            from: ["amount": "1.123456789012345678"]
        ) == "1.123456789012345678"
    )
    #expect(
        BundlerTopUpIntentValidator.validatedAmount(
            from: ["amount": "1.1234567890123456789"]
        ) == nil
    )
}

@Test func bundlerTopUpValidatorRejectsOtherToolIntents() {
    let injectedTopUp = ToolIntent(
        tool: .topUpBundler,
        args: [
            "amount": "0.01",
            "to": "0x1111111111111111111111111111111111111111",
        ],
        source: .model
    )
    #expect(
        BundlerTopUpIntentValidator.validatedAmount(from: injectedTopUp) == nil
    )

    let transfer = ToolIntent(
        tool: .transfer,
        args: ["amount": "0.01"],
        source: .model
    )
    #expect(
        BundlerTopUpIntentValidator.validatedAmount(from: transfer) == nil
    )
}
