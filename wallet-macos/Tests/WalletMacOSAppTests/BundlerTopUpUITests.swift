import Testing
@testable import WalletMacOSApp

@Suite struct BundlerTopUpUITests {
    @Test func operationalBundlerRoutesToComposer() {
        #expect(BundlerTopUpUI.route(
            fundingState: .kernelTopUpCandidate(balanceWeiHex: "0x11c37937e08000"),
            forceExternalFunding: false
        ) == .prefillComposer)
        #expect(BundlerTopUpUI.route(
            fundingState: .healthy(balanceWeiHex: "0x2386f26fc10000"),
            forceExternalFunding: false
        ) == .prefillComposer)
    }

    @Test func unavailableOrUnderfundedBundlerRoutesToRecovery() {
        #expect(BundlerTopUpUI.route(
            fundingState: .externalRequired(balanceWeiHex: "0x0"),
            forceExternalFunding: false
        ) == .externalFunding)
        #expect(BundlerTopUpUI.route(
            fundingState: .checking,
            forceExternalFunding: false
        ) == .retryOnly)
        #expect(BundlerTopUpUI.route(
            fundingState: .healthy(balanceWeiHex: "0x2386f26fc10000"),
            forceExternalFunding: true
        ) == .externalFunding)
    }

    @Test func explicitTopUpActionReplacesExistingDraft() {
        #expect(BundlerTopUpUI.draft(existing: "") == BundlerTopUpUI.defaultPrompt)
        #expect(BundlerTopUpUI.draft(existing: "  ") == BundlerTopUpUI.defaultPrompt)
        #expect(BundlerTopUpUI.draft(existing: "Send 1 ETH") == BundlerTopUpUI.defaultPrompt)
    }

    @Test func exactShortfallSurvivesCoarseHealthyRefresh() throws {
        let identity = try relayerIdentity(addressSuffix: "01")
        let requirement = BundlerExternalFundingRequirement(
            identity: identity,
            // 0.02 ETH, intentionally above the normal 0.005 ETH floor.
            requiredBalanceWeiHex: "0x470de4df820000",
            balanceAtFailureWeiHex: BundlerFundingPolicy.recommendedBalanceWeiHex
        )

        #expect(!BundlerExternalFundingRequirementPolicy.shouldClear(
            requirement,
            verifiedIdentity: identity,
            // 0.01 ETH is operational but still cannot afford this exact op.
            observedBalanceWeiHex: BundlerFundingPolicy.recommendedBalanceWeiHex
        ))
        #expect(BundlerExternalFundingRequirementPolicy.shouldClear(
            requirement,
            verifiedIdentity: identity,
            observedBalanceWeiHex: "0x470de4df820000"
        ))
        #expect(BundlerExternalFundingRequirementPolicy.shouldClear(
            requirement,
            verifiedIdentity: identity,
            // A verified increase permits a fresh exact quote even if it has
            // not yet reached the stale quote's old requirement.
            observedBalanceWeiHex: "0x2386f26fc10001"
        ))
    }

    @Test func exactShortfallRequiresVerifiedIdentityAndDoesNotFollowRotation() throws {
        let original = try relayerIdentity(addressSuffix: "01")
        let replacement = try relayerIdentity(addressSuffix: "02")
        let requirement = BundlerExternalFundingRequirement(
            identity: original,
            requiredBalanceWeiHex: BundlerFundingPolicy.minimumBalanceWeiHex,
            balanceAtFailureWeiHex: "0x0"
        )

        #expect(!BundlerExternalFundingRequirementPolicy.shouldClear(
            requirement,
            verifiedIdentity: nil,
            observedBalanceWeiHex: BundlerFundingPolicy.recommendedBalanceWeiHex
        ))
        #expect(BundlerExternalFundingRequirementPolicy.shouldClear(
            requirement,
            verifiedIdentity: replacement,
            observedBalanceWeiHex: "0x0"
        ))
    }

    private func relayerIdentity(addressSuffix: String) throws -> VerifiedRelayerIdentity {
        try VerifiedRelayerIdentity(
            chainID: 11_155_111,
            keyRef: "bundler-eoa:test-owner:11155111:0",
            address: "0x" + String(repeating: "0", count: 38) + addressSuffix
        )
    }
}
