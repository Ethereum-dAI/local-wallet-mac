import Testing
import WalletToolLayer
@testable import WalletMacOSApp

/// The bundler EOA relays every UserOp and pays its gas, so the daemon refuses a send while
/// its balance is under `thresholdLow`. These cover the app-side half: what the card says,
/// which intents get declined before the passkey prompt, and the raw-error backstop.
@Suite struct BundlerGasWarningTests {
    private static let keyRef = "bundler-eoa:owner:11155111:1"

    private static var identity: VerifiedRelayerIdentity {
        try! VerifiedRelayerIdentity(
            chainID: 11_155_111,
            keyRef: keyRef,
            address: "0x7A3f000000000000000000000000000000009C21"
        )
    }

    private static func relayer(
        balance: String,
        needsTopup: Bool,
        eoa: String = "0x7A3f000000000000000000000000000000009C21"
    ) -> WalletNodeClient.RelayerStatus {
        WalletNodeClient.RelayerStatus(
            ready: !needsTopup && balance != "unavailable",
            keyLoaded: true,
            reason: needsTopup
                ? BundlerGasStatus.needsTopupReason
                : balance == "unavailable" ? "bundler_balance_unavailable" : nil,
            ownerScope: "owner",
            chainId: 11_155_111,
            networkProfile: "sepolia",
            eoa: eoa,
            keyRef: keyRef,
            balance: balance,
            thresholdLow: "0x11c37937e08000", // 0.005 ETH — daemon's THRESHOLD_LOW
            needsTopup: needsTopup,
            lifecycle: "active",
            compromiseSubmissionBlocked: false,
            pendingFundingAddress: nil,
            pendingFundingCount: 0,
            retiringCount: 0,
            keyHistory: [],
            latestAuditEvent: nil,
            replacement: nil
        )
    }

    @Test func fundingPolicyClassifiesExactBoundaries() {
        #expect(BundlerFundingPolicy.fromObservedBalance(nil) == .unavailable)
        #expect(BundlerFundingPolicy.fromObservedBalance("unavailable") == .unavailable)
        #expect(
            BundlerFundingPolicy.fromObservedBalance("0x0")
                == .externalRequired(balanceWeiHex: "0x0")
        )
        #expect(
            BundlerFundingPolicy.fromObservedBalance("0x11c37937e07fff")
                == .externalRequired(balanceWeiHex: "0x11c37937e07fff")
        )
        #expect(
            BundlerFundingPolicy.fromObservedBalance("0x11c37937e08000")
                == .kernelTopUpCandidate(balanceWeiHex: "0x11c37937e08000")
        )
        #expect(
            BundlerFundingPolicy.fromObservedBalance("0x2386f26fc0ffff")
                == .kernelTopUpCandidate(balanceWeiHex: "0x2386f26fc0ffff")
        )
        #expect(
            BundlerFundingPolicy.fromObservedBalance("0x2386f26fc10000")
                == .healthy(balanceWeiHex: "0x2386f26fc10000")
        )
    }

    @Test func missingAndUnreadableDaemonStatusNeverExposeKernelFunding() {
        let checking = BundlerGasStatus.from(
            relayer: nil,
            verifiedIdentity: Self.identity,
            chain: .ethereumSepolia
        )
        #expect(checking.fundingState == .checking)
        #expect(checking.fundingState.shouldOfferKernelTopUp == false)

        let unreadable = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "unavailable", needsTopup: false),
            verifiedIdentity: Self.identity,
            chain: .ethereumSepolia
        )
        #expect(unreadable.fundingState == .unavailable)
        #expect(unreadable.fundingState.shouldOfferKernelTopUp == false)
    }

    @Test func contradictoryDaemonBalanceFailsClosed() {
        let status = BundlerGasStatus.from(
            relayer: Self.relayer(
                balance: BundlerFundingPolicy.recommendedBalanceWeiHex,
                needsTopup: true
            ),
            verifiedIdentity: Self.identity,
            chain: .ethereumSepolia
        )
        #expect(status.fundingState == .unavailable)
        #expect(status.address == nil)
    }

    @Test func unboundDaemonIdentityNeverExposesAFundingAddress() {
        let status = BundlerGasStatus.from(
            relayer: Self.relayer(
                balance: BundlerFundingPolicy.recommendedBalanceWeiHex,
                needsTopup: false,
                eoa: "0x2222222222222222222222222222222222222222"
            ),
            verifiedIdentity: Self.identity,
            chain: .ethereumSepolia
        )

        #expect(status.fundingState == .unavailable)
        #expect(status.verifiedIdentity == nil)
        #expect(status.address == nil)
    }

    @Test func mapsDaemonThresholdIntoHumanCopy() throws {
        let status = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "0x0", needsTopup: true),
            verifiedIdentity: Self.identity,
            chain: .ethereumSepolia
        )

        #expect(status.needsGas)
        #expect(status.badgeText == "Out of gas. Can't send")
        #expect(status.balance == "0 ETH")
        #expect(status.thresholdDisplay == "0.005 ETH")
        #expect(status.declineDetail.contains("0.005 ETH"))
        #expect(status.declineDetail.contains(Self.identity.address))
        #expect(status.cardDetail.contains("can't fund itself"))
        // The Sepolia-only app always provides its faucet route.
        #expect(status.faucetURL != nil)
    }

    /// The daemon gates on a threshold, not on zero: a bundler holding 0.004 ETH dead-ends
    /// exactly like an empty one, so the UI must follow `needsTopup` rather than a local
    /// `balance == 0` check.
    @Test func blocksBelowThresholdEvenWithANonZeroBalance() throws {
        let status = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "0xe35fa931a0000", needsTopup: true), // 0.004 ETH
            verifiedIdentity: Self.identity,
            chain: .ethereumSepolia
        )

        #expect(status.needsGas)
        #expect(status.balance == "0.004 ETH")
        #expect(status.declineDetail.contains("holds 0.004 ETH"))
    }

    @Test func doesNotBlockWhenFundedOrUnknown() throws {
        let funded = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "0x2386f26fc10000", needsTopup: false), // 0.01 ETH
            verifiedIdentity: Self.identity,
            chain: .ethereumSepolia
        )
        #expect(funded.needsGas == false)

        // Balance unavailable: the daemon reports needsTopup=false and stays the authority,
        // so the app must not refuse locally on a read it could not make.
        let unreadable = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "unavailable", needsTopup: false),
            verifiedIdentity: Self.identity,
            chain: .ethereumSepolia
        )
        #expect(unreadable.needsGas == false)
        #expect(unreadable.balance == nil)

        // No daemon status at all (pre-connect) is not a block either.
        let disconnected = BundlerGasStatus.from(
            relayer: nil,
            verifiedIdentity: Self.identity,
            chain: .ethereumSepolia
        )
        #expect(disconnected.needsGas == false)
        #expect(disconnected.address == nil)
    }

    @Test func declinesOnlyPendingIntentsTheBundlerRelays() throws {
        let blocked = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "0x0", needsTopup: true),
            verifiedIdentity: Self.identity,
            chain: .ethereumSepolia
        )

        for tool in [ToolIntent.Tool.transfer, .swap, .shield] {
            #expect(
                BundlerGasPolicy.block(tool: tool, disposition: .pending, status: blocked) != nil,
                "\(tool) is relayed by the bundler and must be declined"
            )
        }

        // An unshield exit is paymaster-sponsored and publicly bundled, so the local bundler
        // EOA's gas balance cannot block it.
        #expect(BundlerGasPolicy.block(tool: .unshield, disposition: .pending, status: blocked) == nil)

        // History is not re-decorated: an already-confirmed card keeps its execution result.
        for disposition in [ToolIntent.Disposition.confirmed, .edited, .rejected] {
            #expect(
                BundlerGasPolicy.block(tool: .transfer, disposition: disposition, status: blocked) == nil
            )
        }
    }

    @Test func doesNotDeclineWhenTheBundlerHasGas() throws {
        let funded = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "0x2386f26fc10000", needsTopup: false),
            verifiedIdentity: Self.identity,
            chain: .ethereumSepolia
        )

        #expect(BundlerGasPolicy.block(tool: .transfer, disposition: .pending, status: funded) == nil)
    }

    @Test func translatesTheDaemonRefusalAndLeavesOtherErrorsAlone() throws {
        let status = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "0x0", needsTopup: true),
            verifiedIdentity: Self.identity,
            chain: .ethereumSepolia
        )
        let refusal = WalletNodeClient.ClientError.rpcError(
            method: "localwallet_sendUserOperation",
            code: -32002,
            message: "Not ready: bundler_eoa_needs_topup",
            reason: "bundler_eoa_needs_topup"
        )

        #expect(BundlerGasStatus.isNeedsTopupError(refusal))
        let message = try #require(BundlerGasStatus.friendlyMessage(for: refusal, status: status))
        #expect(message.hasPrefix(BundlerGasStatus.warningTitle))
        #expect(message.contains("bundler_eoa_needs_topup") == false)
        #expect(message.contains("-32002") == false)

        // Without a cached status the copy is generic, never the raw reason.
        let generic = try #require(BundlerGasStatus.friendlyMessage(for: refusal, status: nil))
        #expect(generic.contains("bundler_eoa_needs_topup") == false)

        // A refusal that only kept its message text still maps (persisted/replayed errors).
        let textOnly = WalletNodeClient.ClientError.rpcError(
            method: "localwallet_sendUserOperation",
            code: -32002,
            message: "Not ready: bundler_eoa_needs_topup",
            reason: nil
        )
        #expect(BundlerGasStatus.isNeedsTopupError(textOnly))

        // Every other failure keeps its own message.
        let unrelated = WalletNodeClient.ClientError.rpcError(
            method: "localwallet_sendUserOperation",
            code: -32002,
            message: "Not ready: chain_not_synced",
            reason: "chain_not_synced"
        )
        #expect(BundlerGasStatus.isNeedsTopupError(unrelated) == false)
        #expect(BundlerGasStatus.friendlyMessage(for: unrelated, status: status) == nil)
    }
}
