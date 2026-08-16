import Foundation
import Testing
@testable import WalletMacOSApp

@Suite struct DashboardAccountCardAuditTests {
    @Test func bothAccountsUseSharedFixedHeightShell() throws {
        let source = try dashboardSource()
        let shell = try slice(
            source,
            from: "private struct AccountSummaryCard",
            until: "private struct KernelAccountCard"
        )
        #expect(shell.contains(".frame(height: 78)"))

        let header = try slice(
            source,
            from: "private var accountHeader",
            until: "private func explorerAddressURL"
        )
        #expect(header.contains("KernelAccountCard("))
        #expect(header.contains("BundlerAccountCard("))
    }

    @Test func bundlerCardHasTopUpAndNoTokenPopover() throws {
        let source = try dashboardSource()
        let bundler = try slice(
            source,
            from: "private struct BundlerAccountCard",
            until: "private struct TokenBalancePopover"
        )
        #expect(bundler.contains("Top up"))
        #expect(!bundler.contains("isTokenListPresented"))
        #expect(!bundler.contains("TokenBalancePopover"))
        #expect(!bundler.contains("onRefreshTokenBalances"))
    }

    @Test func legacyBundlerVerificationOwnsTheCardUntilAuthorityIsEstablished() throws {
        let source = try dashboardSource()
        let bundler = try slice(
            source,
            from: "private struct BundlerAccountCard",
            until: "private struct TokenBalancePopover"
        )

        #expect(bundler.contains("BundlerAccountActionPolicy.route("))
        #expect(bundler.contains("case .verifyLegacyRelayer(let candidate):"))
        #expect(bundler.contains("Text(showsVerificationProgress ? \"Verifying\" : primaryActionTitle)"))
        #expect(bundler.contains("return \"Verify bundler\""))
        #expect(bundler.contains("Verify the existing local bundler key once."))
        #expect(bundler.contains(".disabled(showsVerificationProgress)"))
        #expect(bundler.contains("if presentation.showsDestinationActions"))
        #expect(bundler.contains("accountCopyButton(address: presentation.address"))
        #expect(bundler.contains("accountExplorerLink(explorerURL)"))
        #expect(bundler.contains(".onAppear") == false)
    }

    @Test func dashboardRoutesOnlyTheAppOwnedLegacyCandidateIntoTheCard() throws {
        let source = try dashboardSource()
        let authority = try slice(
            source,
            from: "var bundlerAccountAuthority: BundlerAccountAuthorityState",
            until: "var isVerifyingLegacyRelayer"
        )

        #expect(authority.contains("DashboardBundlerAuthorityPolicy.authority("))
        #expect(authority.contains("migrationCandidate: walletModel.legacyRelayerMigrationCandidate"))
        #expect(authority.contains("liveVerifiedIdentity: walletModel.verifiedLocalRelayerIdentity"))
        #expect(authority.contains("cachedVerifiedIdentity: accountIdentity.bundlerGas.verifiedIdentity"))
        #expect(authority.contains("localRelayerStatus") == false)

        let header = try slice(
            source,
            from: "private var accountHeader",
            until: "private func explorerAddressURL"
        )
        #expect(header.contains("authority: model.bundlerAccountAuthority"))
        #expect(header.contains("isVerifyingLegacyRelayer: model.isVerifyingLegacyRelayer"))
        #expect(header.contains("await model.verifyLegacyRelayer(candidate)"))
    }

    @Test func legacyVerificationUsesAnExplicitAsyncCandidateCallback() throws {
        let source = try dashboardSource()
        let bundler = try slice(
            source,
            from: "private struct BundlerAccountCard",
            until: "private struct TokenBalancePopover"
        )

        #expect(bundler.contains(
            "let onVerifyLegacyRelayer: (LegacyRelayerMigrationCandidate) async -> Void"
        ))
        #expect(bundler.contains("await onVerifyLegacyRelayer(candidate)"))
    }

    @Test func cachedVerifiedBundlerWithoutLiveAuthorityFailsClosed() throws {
        let cached = try relayerIdentity(index: 1, byte: 0x11)

        #expect(DashboardBundlerAuthorityPolicy.authority(
            migrationCandidate: nil,
            liveVerifiedIdentity: nil,
            cachedVerifiedIdentity: cached,
            fundingState: .healthy(balanceWeiHex: "0x1")
        ) == .unavailable)
    }

    @Test func mismatchedLiveAndCachedBundlerAuthorityFailsClosed() throws {
        let live = try relayerIdentity(index: 1, byte: 0x11)
        let cached = try relayerIdentity(index: 2, byte: 0x22)

        #expect(DashboardBundlerAuthorityPolicy.authority(
            migrationCandidate: nil,
            liveVerifiedIdentity: live,
            cachedVerifiedIdentity: cached,
            fundingState: .healthy(balanceWeiHex: "0x1")
        ) == .unavailable)
    }

    @Test func candidateStillOutranksMismatchedCachedAuthority() throws {
        let candidate = LegacyRelayerMigrationCandidate(
            identity: try relayerIdentity(index: 3, byte: 0x33)
        )

        #expect(DashboardBundlerAuthorityPolicy.authority(
            migrationCandidate: candidate,
            liveVerifiedIdentity: try relayerIdentity(index: 1, byte: 0x11),
            cachedVerifiedIdentity: try relayerIdentity(index: 2, byte: 0x22),
            fundingState: .healthy(balanceWeiHex: "0x1")
        ) == .legacyVerification(candidate))
    }

    @Test func unavailableAuthorityRedactsStaleDestinationValues() {
        let presentation = BundlerAccountCardPresentation.resolve(
            authority: .unavailable,
            address: "0x1111111111111111111111111111111111111111",
            balance: "9 ETH",
            state: "Identity unavailable"
        )

        #expect(presentation.address == "Not available")
        #expect(presentation.balance == "Balance unavailable")
        #expect(presentation.state == "Identity unavailable")
        #expect(presentation.showsDestinationActions == false)
    }

    @Test func dashboardDoesNotKeepBundlerTokenBalanceState() throws {
        #expect(!(try dashboardSource()).contains("bundlerTokenBalances"))
    }

    @Test func verifiedRefreshBindsOnlyPreviouslyUnreviewedPendingTopUps() throws {
        let source = try dashboardSource()
        let binding = try slice(
            source,
            from: "private func bindPendingBundlerTopUpsIfNeeded",
            until: "private func clearExternalFundingRequirementIfSatisfied"
        )
        #expect(binding.contains("intent.tool == .topUpBundler"))
        #expect(binding.contains("intent.disposition == .pending"))
        #expect(binding.contains("reviewedBundlerIdentities[intent.id] == nil"))
        #expect(binding.contains("reviewedBundlerIdentities[intent.id] = identity"))
    }

    @Test func genericRefreshDoesNotForgetAnExactExternalFundingRequirement() throws {
        let source = try dashboardSource()
        let refresh = try slice(
            source,
            from: "func refreshOnchainAccountStatus()",
            until: "func retryBundlerFundingStatus()"
        )
        #expect(!refresh.contains("bundlerExternalFundingRequirement = nil"))

        let identityRefresh = try slice(
            source,
            from: "private func refreshAccountIdentity()",
            until: "private func bindPendingBundlerTopUpsIfNeeded"
        )
        #expect(identityRefresh.contains("clearExternalFundingRequirementIfSatisfied"))
    }

    private func dashboardSource() throws -> String {
        try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/WalletMacOSApp/ChatDashboardView.swift"),
            encoding: .utf8
        )
    }

    private func relayerIdentity(
        index: UInt64,
        byte: UInt8
    ) throws -> VerifiedRelayerIdentity {
        try VerifiedRelayerIdentity(
            chainID: 11_155_111,
            keyRef: "bundler-eoa:default:11155111:\(index)",
            address: "0x" + String(repeating: String(format: "%02x", byte), count: 20)
        )
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func slice(
        _ source: String,
        from start: String,
        until end: String
    ) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(
            source.range(of: end, range: startRange.upperBound..<source.endIndex)
        )
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
