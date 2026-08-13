import Foundation
import Testing

@Suite struct DashboardChromeAuditTests {
    @Test func footerShowsOnlyActiveExecutionAndKeepsSlashToolsInComposer() throws {
        let source = try dashboardSource()
        let footer = try slice(source, from: "private var footerControls", until: "private var composer")
        let composer = try slice(source, from: "private var composer", until: "private var greeting")

        #expect(!source.contains("isToolsPopoverPresented"))
        #expect(!source.contains("private struct SlashCommandPalette"))
        #expect(!footer.contains("Text(\"Tools\")"))
        #expect(!footer.contains("SlashCommandPalette"))
        #expect(footer.contains("if model.hasExecutingIntent"))
        #expect(footer.contains("arrow.triangle.2.circlepath"))
        #expect(!footer.contains("slider.horizontal.3"))

        #expect(composer.contains("SlashSuggestionPanel(commands: model.slashSuggestions)"))
        #expect(composer.contains("model.insertSlashCommand(command)"))
        #expect(composer.contains("type / for tools"))
    }

    @Test func bundlerCardNeverFallsThroughFromUnknownToKernelFund() throws {
        let source = try dashboardSource()
        let card = try slice(
            source,
            from: "private struct FundableAccountCard",
            until: "private struct TokenBalancePopover"
        )

        #expect(card.contains("switch effectiveFundingState"))
        #expect(card.contains("case .checking"))
        #expect(card.contains("case .unavailable"))
        #expect(card.contains("case .externalRequired"))
        #expect(card.contains("case .kernelTopUpCandidate"))
        #expect(card.contains("case .healthy"))
        #expect(card.contains("BundlerExternalFundingActions("))
        #expect(card.contains("compact: true"))
        #expect(card.contains("if case .healthy = fundingState") == false)
        #expect(card.contains("stateBadge") == false)
        #expect(card.contains("healthy-status") == false)
    }

    @Test func exactTopUpPreflightFailureForcesExternalRecoveryActions() throws {
        let source = try dashboardSource()
        let funding = try slice(
            source,
            from: "func fundHelper",
            until: "private func fundingFailureMessage"
        )

        #expect(funding.contains("executeBundlerTopUp"))
        #expect(funding.contains("AppError.bundlerRelayShortfall"))
        #expect(funding.contains("AppError.bundlerRelayPreflightUnavailable"))
        #expect(funding.contains("helperRequiresExternalFundingAddress = address"))
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

    private func slice(_ source: String, from start: String, until end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
