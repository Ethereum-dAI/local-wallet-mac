import Testing
import WalletToolLayer
@testable import WalletMacOSApp

/// The bundler EOA relays every UserOp and pays its gas, so the daemon refuses a send while
/// its balance is under `thresholdLow`. These cover the app-side half: what the card says,
/// which intents get declined before the passkey prompt, and the raw-error backstop.
@Suite struct BundlerGasWarningTests {
    private static func relayer(
        balance: String,
        needsTopup: Bool,
        eoa: String = "0x7A3f000000000000000000000000000000009C21"
    ) -> WalletNodeClient.RelayerStatus {
        WalletNodeClient.RelayerStatus(
            ready: !needsTopup,
            ownerScope: "owner",
            chainId: 11_155_111,
            networkProfile: "sepolia",
            eoa: eoa,
            keyRef: "key-1",
            balance: balance,
            thresholdLow: "0x11c37937e08000", // 0.005 ETH — daemon's THRESHOLD_LOW
            needsTopup: needsTopup,
            lifecycle: "active",
            pendingFundingAddress: nil,
            pendingFundingCount: 0,
            retiringCount: 0,
            keyHistory: [],
            latestAuditEvent: nil,
            replacement: nil
        )
    }

    @Test func mapsDaemonThresholdIntoHumanCopy() throws {
        let status = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "0x0", needsTopup: true),
            fallbackAddress: nil,
            chain: .ethereumSepolia
        )

        #expect(status.needsGas)
        #expect(status.balance == "0 ETH")
        #expect(status.thresholdDisplay == "0.005 ETH")
        #expect(status.declineDetail.contains("0.005 ETH"))
        #expect(status.declineDetail.contains("0x7A3f000000000000000000000000000000009C21"))
        #expect(status.cardDetail.contains("can't fund itself"))
        // Testnet gets a faucet route; mainnet has none to offer.
        #expect(status.faucetURL != nil)
    }

    /// The daemon gates on a threshold, not on zero: a bundler holding 0.004 ETH dead-ends
    /// exactly like an empty one, so the UI must follow `needsTopup` rather than a local
    /// `balance == 0` check.
    @Test func blocksBelowThresholdEvenWithANonZeroBalance() throws {
        let status = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "0xe35fa931a0000", needsTopup: true), // 0.004 ETH
            fallbackAddress: nil,
            chain: .ethereumSepolia
        )

        #expect(status.needsGas)
        #expect(status.balance == "0.004 ETH")
        #expect(status.declineDetail.contains("holds 0.004 ETH"))
    }

    @Test func doesNotBlockWhenFundedOrUnknown() throws {
        let funded = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "0x2386f26fc10000", needsTopup: false), // 0.01 ETH
            fallbackAddress: nil,
            chain: .ethereumSepolia
        )
        #expect(funded.needsGas == false)

        // Balance unavailable: the daemon reports needsTopup=false and stays the authority,
        // so the app must not refuse locally on a read it could not make.
        let unreadable = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "unavailable", needsTopup: false),
            fallbackAddress: nil,
            chain: .ethereumSepolia
        )
        #expect(unreadable.needsGas == false)
        #expect(unreadable.balance == nil)

        // No daemon status at all (pre-connect) is not a block either.
        let disconnected = BundlerGasStatus.from(
            relayer: nil,
            fallbackAddress: "0x7A3f000000000000000000000000000000009C21",
            chain: .ethereumSepolia
        )
        #expect(disconnected.needsGas == false)
        #expect(disconnected.address == "0x7A3f000000000000000000000000000000009C21")
    }

    @Test func mainnetDropsTheFaucetRoute() throws {
        let status = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "0x0", needsTopup: true),
            fallbackAddress: nil,
            chain: .ethereum
        )

        #expect(status.faucetURL == nil)
        #expect(status.cardDetail.contains("faucet") == false)
        #expect(status.cardDetail.contains("from another wallet"))
    }

    @Test func declinesOnlyPendingIntentsTheBundlerRelays() throws {
        let blocked = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "0x0", needsTopup: true),
            fallbackAddress: nil,
            chain: .ethereumSepolia
        )

        for tool in [ToolIntent.Tool.transfer, .swap] {
            #expect(
                BundlerGasPolicy.block(tool: tool, disposition: .pending, status: blocked) != nil,
                "\(tool) is relayed by the bundler and must be declined"
            )
        }

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
            fallbackAddress: nil,
            chain: .ethereumSepolia
        )

        #expect(BundlerGasPolicy.block(tool: .transfer, disposition: .pending, status: funded) == nil)
    }

    @Test func translatesTheDaemonRefusalAndLeavesOtherErrorsAlone() throws {
        let status = BundlerGasStatus.from(
            relayer: Self.relayer(balance: "0x0", needsTopup: true),
            fallbackAddress: nil,
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
