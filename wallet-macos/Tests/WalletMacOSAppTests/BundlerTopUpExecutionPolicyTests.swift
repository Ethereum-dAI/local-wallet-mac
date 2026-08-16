import Testing
import WalletToolLayer
@testable import WalletMacOSApp

@Suite struct BundlerTopUpExecutionPolicyTests {
    @Test func topUpIsBlockedUnlessKernelRelayIsViable() {
        let blocked: [BundlerFundingState] = [
            .checking,
            .unavailable,
            .externalRequired(balanceWeiHex: "0x0"),
        ]
        for state in blocked {
            #expect(
                BundlerGasPolicy.block(
                    tool: .topUpBundler,
                    disposition: .pending,
                    status: bundlerGasStatus(fundingState: state)
                ) != nil
            )
        }

        let operational: [BundlerFundingState] = [
            .kernelTopUpCandidate(balanceWeiHex: "0x11c37937e08000"),
            .healthy(balanceWeiHex: "0x2386f26fc10000"),
        ]
        for state in operational {
            #expect(
                BundlerGasPolicy.block(
                    tool: .topUpBundler,
                    disposition: .pending,
                    status: bundlerGasStatus(fundingState: state)
                ) == nil
            )
        }
    }

    @Test func topUpAlwaysRequiresLocalBundlerGas() {
        #expect(BundlerGasPolicy.requiresBundlerGas(.topUpBundler))
    }

    @Test func topUpBlockCopyNamesExternalRecovery() {
        let unavailable = bundlerGasStatus(fundingState: .unavailable)
        #expect(unavailable.topUpBlockTitle == "Bundler balance unavailable")
        #expect(unavailable.topUpBlockDetail.contains("Retry"))

        let external = bundlerGasStatus(
            fundingState: .externalRequired(balanceWeiHex: "0x0")
        )
        #expect(external.topUpBlockTitle == "Fund the bundler externally first")
        #expect(external.topUpBlockDetail.contains("Sepolia faucet"))
    }

    private func bundlerGasStatus(
        fundingState: BundlerFundingState
    ) -> BundlerGasStatus {
        BundlerGasStatus(
            verifiedIdentity: nil,
            address: "0x7A3f000000000000000000000000000000009C21",
            balance: nil,
            thresholdDisplay: BundlerFundingPolicy.minimumBalanceDisplay,
            networkLabel: "Sepolia",
            fundingState: fundingState
        )
    }
}
