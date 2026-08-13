import Foundation
import Testing

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
            until: "private var shieldedBalanceRow"
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
