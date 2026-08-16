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

    @Test func emptyChatStateHasNoDecorativeProfileAvatar() throws {
        let source = try dashboardSource()
        let emptyState = try slice(
            source,
            from: "private var emptyState",
            until: "private var welcomeStarters"
        )
        #expect(!emptyState.contains("person.fill"))
        #expect(emptyState.contains("Text(greeting)"))
        #expect(emptyState.contains("WelcomeStarterChip"))
    }

    @Test func activeFooterControlsUseSemanticHighlights() throws {
        let source = try dashboardSource()
        let footer = try slice(source, from: "private var footerControls", until: "private var composer")
        let thinkingControl = try slice(
            footer,
            from: "Button {\n                model.toggleThinking()",
            until: "if model.hasExecutingIntent"
        )
        let sessionControl = try slice(
            footer,
            from: "Button {\n                isSessionPopoverPresented.toggle()",
            until: "Button {\n                isGasPopoverPresented.toggle()"
        )
        let sessionHighlight = try slice(
            source,
            from: "private var sessionPillIsHighlighted",
            until: "private func runSessionPopoverAction"
        )
        let statusPill = try slice(
            source,
            from: "private struct StatusPill",
            until: "private struct SessionStatusPopover"
        )

        #expect(thinkingControl.contains("isHighlighted: model.thinkingEnabled"))
        #expect(thinkingControl.contains(".accessibilityLabel(\"Thinking\")"))
        #expect(thinkingControl.contains(".accessibilityValue(model.thinkingEnabled ? \"On\" : \"Off\")"))
        #expect(sessionControl.contains("isHighlighted: sessionPillIsHighlighted"))
        #expect(sessionHighlight.contains("model.settingsSnapshot.session.statusTitle == \"Active\""))
        #expect(statusPill.contains("var isHighlighted = false"))
        #expect(statusPill.contains("isHighlighted ? ChatPalette.primaryText : ChatPalette.secondaryText"))
        #expect(statusPill.contains("isHighlighted ? ChatPalette.selectedPanel : ChatPalette.panel"))
        #expect(statusPill.contains("isHighlighted ? tint.opacity(0.8) : ChatPalette.border"))
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
