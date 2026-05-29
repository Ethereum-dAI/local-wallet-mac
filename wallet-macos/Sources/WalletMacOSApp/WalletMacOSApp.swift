import AppKit
import Combine
import SwiftUI

// This file owns the macOS demo shell for the project. The UI is meant to be a
// reference workbench for testing Secure Enclave, Kernel account derivation,
// and UserOperation flows rather than the final wallet product interface.
@main
enum WalletMacOSApp {
    static func main() {
        if CommandLine.arguments.contains("--reset-demo-wallet") {
            resetDemoWalletAndExit()
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = delegate.makeMainMenu()
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    private static func resetDemoWalletAndExit() -> Never {
        do {
            try KeyStore().deleteKey()
            try BundlerKeyStore.shared.deleteAll()
            try WalletMetadataStore().clear()
            print("Deleted Local Wallet demo key, local relayer keys, and metadata.")
            exit(0)
        } catch {
            fputs("Failed to reset Local Wallet demo wallet: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: AppModel?

    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let resetItem = NSMenuItem(
            title: "Reset Demo Wallet",
            action: #selector(resetDemoWallet),
            keyEquivalent: ""
        )
        resetItem.target = self
        appMenu.addItem(resetItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit Local Wallet",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        return mainMenu
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Local Wallet"
        window.minSize = NSSize(width: 1080, height: 700)
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        if OnboardingSettingsStore().isCompleted {
            showDashboard()
        } else {
            showOnboarding()
        }
    }

    private func showOnboarding() {
        window?.contentViewController = NSHostingController(
            rootView: LocalWalletOnboardingView { [weak self] in
                self?.showDashboard()
            }
        )
    }

    private func showDashboard() {
        window?.contentViewController = NSHostingController(rootView: LocalWalletChatDashboardView())
    }

    private func showLegacyDashboard() {
        guard let model else {
            return
        }
        window?.contentViewController = WalletViewController(model: model)
        model.bootstrap()
    }

    @objc
    private func resetDemoWallet() {
        guard let model else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Reset demo wallet?"
        alert.informativeText = "This deletes the local Secure Enclave key reference and wallet metadata for the demo app. The next reload creates a new key and a new precomputed account address."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let reset = {
            model.resetDemoWallet()
        }

        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    reset()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            reset()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private final class DemoBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [
            NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.11, alpha: 1.0),
            NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 1.0),
            NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.08, alpha: 1.0),
        ])?.draw(in: bounds, angle: 315)

        NSColor(calibratedRed: 0.13, green: 0.77, blue: 0.37, alpha: 0.10).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 320, y: bounds.maxY - 240, width: 460, height: 360)).fill()

        NSColor(calibratedRed: 0.25, green: 0.43, blue: 1.0, alpha: 0.08).setFill()
        NSBezierPath(ovalIn: NSRect(x: -180, y: -140, width: 420, height: 340)).fill()
    }
}

private final class WalletViewController: NSViewController, NSTextFieldDelegate {
    private enum InputTag {
        static let recipient = 1
        static let amount = 2
    }

    private enum Palette {
        static let text = NSColor(calibratedRed: 0.95, green: 0.97, blue: 1.0, alpha: 1.0)
        static let mutedText = NSColor(calibratedRed: 0.58, green: 0.64, blue: 0.74, alpha: 1.0)
        static let faintText = NSColor(calibratedRed: 0.39, green: 0.46, blue: 0.58, alpha: 1.0)
        static let cardFill = NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.16, alpha: 0.78)
        static let cardBorder = NSColor(calibratedRed: 0.55, green: 0.68, blue: 0.84, alpha: 0.16)
        static let cardShadow = NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        static let controlFill = NSColor(calibratedRed: 0.11, green: 0.15, blue: 0.23, alpha: 0.96)
        static let primaryGreen = NSColor(calibratedRed: 0.13, green: 0.77, blue: 0.37, alpha: 1.0)
        static let primaryGreenSoft = NSColor(calibratedRed: 0.13, green: 0.77, blue: 0.37, alpha: 0.18)
        static let blue = NSColor(calibratedRed: 0.25, green: 0.43, blue: 1.0, alpha: 1.0)
        static let orange = NSColor(calibratedRed: 1.0, green: 0.63, blue: 0.20, alpha: 1.0)
    }

    private let model: AppModel
    private let qrCodeFactory = QRCodeImageFactory()
    private var cancellables = Set<AnyCancellable>()
    private var pendingCopyResetWorkItem: DispatchWorkItem?

    private let scrollView = NSScrollView()
    private let contentView = NSView()
    private let rootStack = NSStackView()

    private let heroCard = WalletViewController.makeCard()
    private let accountCard = WalletViewController.makeCard()
    private let composerCard = WalletViewController.makeCard()
    private let relayerCard = WalletViewController.makeCard()
    private let logsCard = WalletViewController.makeCard()
    private let lowerRow = NSStackView()

    private let titleLabel = NSTextField(labelWithString: "Local Wallet")
    private let subtitleLabel = NSTextField(labelWithString: "A native macOS demo for Secure Enclave signing, Kernel smart-account precompute, and Sepolia transaction composition.")
    private let statusHeadlineLabel = NSTextField(labelWithString: "Bootstrapping local signer…")
    private let addressLabel = NSTextField(labelWithString: "0x—")
    private let networkLabel = WalletViewController.makeBadge()
    private let stateLabel = WalletViewController.makeBadge()
    private let rpcLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let addressBlock = NSStackView()
    private let badgeRow = NSStackView()
    private let heroCopyAddressButton = NSButton(title: "Copy Address", target: nil, action: nil)
    private let accountCopyAddressButton = NSButton(title: "Copy Address", target: nil, action: nil)

    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let howItWorksButton = NSButton(title: "How it works", target: nil, action: nil)
    private let testnetButton = NSButton(checkboxWithTitle: "Testnet Mode (Sepolia)", target: nil, action: nil)

    private let accountTitleLabel = NSTextField(labelWithString: "Smart Account")
    private let accountDetailLabel = NSTextField(labelWithString: "The app inspects deployment and balance automatically after bootstrap.")
    private let deploymentValueLabel = NSTextField(labelWithString: "Unknown")
    private let balanceValueLabel = NSTextField(labelWithString: "—")
    private let refreshBalanceButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let qrImageView = NSImageView()
    private let fundingHintLabel = NSTextField(labelWithString: "")
    private let fundingAddressLabel = NSTextField(labelWithString: "")

    private let composerTitleLabel = NSTextField(labelWithString: "Transaction Intent")
    private let composerDetailLabel = NSTextField(labelWithString: "Build and send a Sepolia ETH transfer. A precomputed account deploys automatically on first send.")
    private let transactionTypePopup = NSPopUpButton()
    private let recipientField = NSTextField()
    private let amountField = NSTextField()
    private let composerSummaryLabel = NSTextField(labelWithString: "")
    private let userOpDraftScrollView = NSScrollView()
    private let userOpDraftTextView = NSTextView()
    private let buildDraftButton = NSButton(title: "Build UserOperation Draft", target: nil, action: nil)
    private let sendUserOperationButton = NSButton(title: "Send UserOperation", target: nil, action: nil)
    private let submissionStatusLabel = NSTextField(labelWithString: "")
    private let relayerTitleLabel = NSTextField(labelWithString: "Local Relayer Key")
    private let relayerDetailLabel = NSTextField(labelWithString: "Local daemon not connected")
    private let relayerAddressLabel = NSTextField(labelWithString: "—")
    private let relayerBalanceLabel = NSTextField(labelWithString: "—")
    private let relayerLifecycleLabel = WalletViewController.makeBadge()
    private let relayerAuditLabel = NSTextField(labelWithString: "")
    private let relayerHistoryPopup = NSPopUpButton()
    private let refreshRelayerButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let rotateRelayerButton = NSButton(title: "Rotate", target: nil, action: nil)
    private let exportRelayerButton = NSButton(title: "Export", target: nil, action: nil)
    private let deleteRelayerButton = NSButton(title: "Delete / Reset", target: nil, action: nil)
    private let logsTitleLabel = NSTextField(labelWithString: "Debug Activity")
    private let logsDetailLabel = NSTextField(labelWithString: "Timestamps for bootstrap, inspection, gas estimation, Secure Enclave signing, bundler submission, and receipt polling.")
    private let clearLogsButton = NSButton(title: "Clear Logs", target: nil, action: nil)
    private let debugLogScrollView = NSScrollView()
    private let debugLogTextView = NSTextView()
    private var heroCardHeightConstraint: NSLayoutConstraint?
    private var accountCardHeightConstraint: NSLayoutConstraint?
    private var composerCardHeightConstraint: NSLayoutConstraint?
    private var relayerCardHeightConstraint: NSLayoutConstraint?
    private var logsCardHeightConstraint: NSLayoutConstraint?
    private var selectedRelayerKeyRef: String?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = DemoBackgroundView()

        configureViews()
        layoutViews()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.render()
            }
            .store(in: &cancellables)

        render()
    }

    private func configureViews() {
        titleLabel.font = NSFont.systemFont(ofSize: 40, weight: .black)
        titleLabel.textColor = Palette.text
        configureTitleLabel(titleLabel)
        configureSelectableLabel(titleLabel)

        subtitleLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        subtitleLabel.textColor = Palette.mutedText
        configureWrappingLabel(subtitleLabel)
        configureSelectableLabel(subtitleLabel)

        statusHeadlineLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        statusHeadlineLabel.textColor = Palette.text
        configureWrappingLabel(statusHeadlineLabel)
        configureSelectableLabel(statusHeadlineLabel)

        addressLabel.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
        addressLabel.textColor = Palette.text
        addressLabel.lineBreakMode = .byTruncatingMiddle
        configureSelectableLabel(addressLabel)

        [rpcLabel].forEach {
            $0.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            $0.textColor = Palette.faintText
            $0.lineBreakMode = .byTruncatingMiddle
            configureSelectableLabel($0)
        }

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.setContentCompressionResistancePriority(.required, for: .horizontal)

        [reloadButton, howItWorksButton, heroCopyAddressButton, accountCopyAddressButton, refreshBalanceButton, buildDraftButton, sendUserOperationButton, refreshRelayerButton, rotateRelayerButton, exportRelayerButton, deleteRelayerButton, clearLogsButton].forEach {
            $0.bezelStyle = .rounded
            $0.setButtonType(.momentaryPushIn)
            $0.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        }
        styleButton(howItWorksButton, role: .primary)
        howItWorksButton.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        styleButton(reloadButton, role: .secondary)
        styleButton(heroCopyAddressButton, role: .secondary)
        styleButton(accountCopyAddressButton, role: .secondary)
        styleButton(refreshBalanceButton, role: .quiet)
        styleButton(buildDraftButton, role: .secondary)
        styleButton(sendUserOperationButton, role: .primary)
        styleButton(refreshRelayerButton, role: .quiet)
        styleButton(rotateRelayerButton, role: .secondary)
        styleButton(exportRelayerButton, role: .secondary)
        styleButton(deleteRelayerButton, role: .quiet)
        styleButton(clearLogsButton, role: .quiet)
        reloadButton.target = self
        reloadButton.action = #selector(reloadWallet)
        howItWorksButton.target = self
        howItWorksButton.action = #selector(showHowItWorks)
        heroCopyAddressButton.target = self
        heroCopyAddressButton.action = #selector(copyAddress)
        accountCopyAddressButton.target = self
        accountCopyAddressButton.action = #selector(copyAddress)
        refreshBalanceButton.target = self
        refreshBalanceButton.action = #selector(refreshBalance)
        buildDraftButton.target = self
        buildDraftButton.action = #selector(buildUserOperationDraft)
        sendUserOperationButton.target = self
        sendUserOperationButton.action = #selector(sendUserOperation)
        refreshRelayerButton.target = self
        refreshRelayerButton.action = #selector(refreshLocalRelayer)
        rotateRelayerButton.target = self
        rotateRelayerButton.action = #selector(rotateLocalRelayer)
        exportRelayerButton.target = self
        exportRelayerButton.action = #selector(exportLocalRelayer)
        deleteRelayerButton.target = self
        deleteRelayerButton.action = #selector(deleteLocalRelayer)
        clearLogsButton.target = self
        clearLogsButton.action = #selector(clearDebugLog)
        relayerHistoryPopup.target = self
        relayerHistoryPopup.action = #selector(selectRelayerHistoryEntry)

        testnetButton.target = self
        testnetButton.action = #selector(toggleTestnetMode)
        testnetButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        testnetButton.contentTintColor = .white
        testnetButton.isHidden = true

        accountTitleLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        accountTitleLabel.textColor = Palette.text
        configureTitleLabel(accountTitleLabel)
        configureSelectableLabel(accountTitleLabel)
        composerTitleLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        composerTitleLabel.textColor = Palette.text
        configureTitleLabel(composerTitleLabel)
        configureSelectableLabel(composerTitleLabel)
        relayerTitleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        relayerTitleLabel.textColor = Palette.text
        configureTitleLabel(relayerTitleLabel)
        configureSelectableLabel(relayerTitleLabel)

        [accountDetailLabel, composerDetailLabel, fundingHintLabel, composerSummaryLabel, relayerDetailLabel, relayerAuditLabel].forEach {
            $0.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            $0.textColor = Palette.mutedText
            configureWrappingLabel($0)
            configureSelectableLabel($0)
        }

        deploymentValueLabel.font = NSFont.systemFont(ofSize: 24, weight: .black)
        deploymentValueLabel.textColor = Palette.text
        configureSelectableLabel(deploymentValueLabel)

        balanceValueLabel.font = NSFont.monospacedSystemFont(ofSize: 20, weight: .bold)
        balanceValueLabel.textColor = Palette.primaryGreen
        configureSelectableLabel(balanceValueLabel)

        [relayerAddressLabel, relayerBalanceLabel].forEach {
            $0.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
            $0.textColor = Palette.text
            $0.lineBreakMode = .byTruncatingMiddle
            configureSelectableLabel($0)
        }

        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.wantsLayer = true
        qrImageView.layer?.cornerRadius = 14
        qrImageView.layer?.masksToBounds = true
        qrImageView.layer?.backgroundColor = NSColor.white.cgColor
        qrImageView.layer?.borderWidth = 3
        qrImageView.layer?.borderColor = Palette.text.withAlphaComponent(0.92).cgColor

        fundingAddressLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        fundingAddressLabel.textColor = Palette.mutedText
        fundingAddressLabel.maximumNumberOfLines = 3
        fundingAddressLabel.lineBreakMode = .byCharWrapping
        configureSelectableLabel(fundingAddressLabel)

        transactionTypePopup.addItems(withTitles: DemoTransactionKind.allCases.map(\.rawValue))
        transactionTypePopup.target = self
        transactionTypePopup.action = #selector(transactionTypeChanged)

        relayerHistoryPopup.addItem(withTitle: "Current key")
        relayerHistoryPopup.isEnabled = false

        recipientField.placeholderString = "Recipient address"
        recipientField.delegate = self
        recipientField.tag = InputTag.recipient
        recipientField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        configureInputField(recipientField)

        amountField.placeholderString = "Amount in ETH"
        amountField.delegate = self
        amountField.tag = InputTag.amount
        amountField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        configureInputField(amountField)

        composerSummaryLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        composerSummaryLabel.textColor = Palette.text

        userOpDraftTextView.isEditable = false
        userOpDraftTextView.isSelectable = true
        userOpDraftTextView.drawsBackground = false
        userOpDraftTextView.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        userOpDraftTextView.textColor = Palette.mutedText
        userOpDraftTextView.textContainerInset = NSSize(width: 6, height: 8)
        userOpDraftTextView.textContainer?.lineFragmentPadding = 0
        userOpDraftTextView.textContainer?.widthTracksTextView = true
        userOpDraftTextView.isHorizontallyResizable = false
        userOpDraftTextView.isVerticallyResizable = true

        userOpDraftScrollView.drawsBackground = false
        userOpDraftScrollView.borderType = .noBorder
        userOpDraftScrollView.hasVerticalScroller = true
        userOpDraftScrollView.documentView = userOpDraftTextView

        submissionStatusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        submissionStatusLabel.textColor = Palette.mutedText
        configureWrappingLabel(submissionStatusLabel)
        configureSelectableLabel(submissionStatusLabel)

        logsTitleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        logsTitleLabel.textColor = Palette.text
        configureTitleLabel(logsTitleLabel)
        configureSelectableLabel(logsTitleLabel)

        logsDetailLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        logsDetailLabel.textColor = Palette.faintText
        configureWrappingLabel(logsDetailLabel)
        configureSelectableLabel(logsDetailLabel)

        debugLogTextView.isEditable = false
        debugLogTextView.isSelectable = true
        debugLogTextView.drawsBackground = false
        debugLogTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        debugLogTextView.textColor = Palette.mutedText
        debugLogTextView.textContainerInset = NSSize(width: 6, height: 8)
        debugLogTextView.textContainer?.lineFragmentPadding = 0
        debugLogTextView.textContainer?.widthTracksTextView = true
        debugLogTextView.isHorizontallyResizable = false
        debugLogTextView.isVerticallyResizable = true

        debugLogScrollView.drawsBackground = false
        debugLogScrollView.borderType = .noBorder
        debugLogScrollView.hasVerticalScroller = true
        debugLogScrollView.documentView = debugLogTextView

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true

        configureFixedLayoutBehavior()
    }

    private func layoutViews() {
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 18
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView
        view.addSubview(scrollView)

        let heroStack = NSStackView(views: [
            makeHeaderBlock(),
            makeHeroMetaBlock()
        ])
        heroStack.orientation = .horizontal
        heroStack.alignment = .top
        heroStack.distribution = .fill
        heroStack.spacing = 32
        installCard(heroStack, in: heroCard)

        lowerRow.orientation = .horizontal
        lowerRow.alignment = .top
        lowerRow.orientation = .horizontal
        lowerRow.distribution = .fillEqually
        lowerRow.spacing = 18
        lowerRow.addArrangedSubview(makeAccountBlock())
        lowerRow.addArrangedSubview(makeComposerBlock())

        rootStack.addArrangedSubview(heroCard)
        rootStack.addArrangedSubview(lowerRow)
        rootStack.addArrangedSubview(makeRelayerBlock())
        rootStack.addArrangedSubview(makeLogsBlock())

        heroCardHeightConstraint = heroCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 166)
        accountCardHeightConstraint = accountCard.heightAnchor.constraint(equalToConstant: 420)
        composerCardHeightConstraint = composerCard.heightAnchor.constraint(equalToConstant: 420)
        relayerCardHeightConstraint = relayerCard.heightAnchor.constraint(equalToConstant: 250)
        logsCardHeightConstraint = logsCard.heightAnchor.constraint(equalToConstant: 164)
        heroCardHeightConstraint?.isActive = true
        accountCardHeightConstraint?.isActive = true
        composerCardHeightConstraint?.isActive = true
        relayerCardHeightConstraint?.isActive = true
        logsCardHeightConstraint?.isActive = true

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),

            heroCard.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            lowerRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            relayerCard.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            logsCard.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            accountCard.widthAnchor.constraint(equalTo: composerCard.widthAnchor),
        ])
    }

    private func makeHeaderBlock() -> NSView {
        let stack = NSStackView(views: [titleLabel, statusHeadlineLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        statusHeadlineLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusHeadlineLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
        ])
        return stack
    }

    private func makeHeroMetaBlock() -> NSView {
        badgeRow.addArrangedSubview(networkLabel)
        badgeRow.addArrangedSubview(stateLabel)
        badgeRow.addArrangedSubview(progressIndicator)
        badgeRow.orientation = .horizontal
        badgeRow.alignment = .centerY
        badgeRow.spacing = 10
        badgeRow.distribution = .gravityAreas
        badgeRow.translatesAutoresizingMaskIntoConstraints = false

        let addressCaption = NSTextField(labelWithString: "Predicted Kernel Account")
        addressCaption.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        addressCaption.textColor = Palette.faintText

        addressBlock.addArrangedSubview(addressCaption)
        let addressRow = NSStackView(views: [addressLabel, heroCopyAddressButton])
        addressRow.orientation = .horizontal
        addressRow.alignment = .centerY
        addressRow.spacing = 10

        addressBlock.addArrangedSubview(addressRow)
        addressBlock.addArrangedSubview(rpcLabel)
        addressBlock.orientation = .vertical
        addressBlock.alignment = .leading
        addressBlock.spacing = 8
        addressBlock.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [badgeRow, addressBlock, makeControlRow()])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        rpcLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rpcLabel.widthAnchor.constraint(equalTo: addressBlock.widthAnchor),
            addressBlock.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])
        return stack
    }

    private func makeControlRow() -> NSView {
        let stack = NSStackView(views: [howItWorksButton, reloadButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }

    private func makeAccountBlock() -> NSView {
        let deploymentCaption = NSTextField(labelWithString: "Deployment State")
        deploymentCaption.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        deploymentCaption.textColor = Palette.faintText
        configureMetricCaption(deploymentCaption)

        let balanceCaption = NSTextField(labelWithString: "Balance")
        balanceCaption.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        balanceCaption.textColor = Palette.faintText
        configureMetricCaption(balanceCaption)

        let qrCaption = NSTextField(labelWithString: "Funding QR")
        qrCaption.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        qrCaption.textColor = Palette.faintText
        configureMetricCaption(qrCaption)

        let deploymentStack = NSStackView(views: [deploymentCaption, deploymentValueLabel])
        deploymentStack.orientation = .vertical
        deploymentStack.alignment = .leading
        deploymentStack.spacing = 4

        let balanceHeaderRow = NSStackView(views: [balanceCaption, refreshBalanceButton])
        balanceHeaderRow.orientation = .horizontal
        balanceHeaderRow.alignment = .centerY
        balanceHeaderRow.spacing = 8
        balanceHeaderRow.setContentHuggingPriority(.required, for: .vertical)

        let balanceStack = NSStackView(views: [balanceHeaderRow, balanceValueLabel])
        balanceStack.orientation = .vertical
        balanceStack.alignment = .leading
        balanceStack.spacing = 4

        let metricsRow = NSStackView(views: [deploymentStack, balanceStack])
        metricsRow.orientation = .horizontal
        metricsRow.alignment = .top
        metricsRow.distribution = .fill
        metricsRow.spacing = 24
        deploymentStack.translatesAutoresizingMaskIntoConstraints = false
        balanceStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            deploymentStack.widthAnchor.constraint(equalToConstant: 160),
            balanceStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        let addressRow = NSStackView(views: [fundingAddressLabel, accountCopyAddressButton])
        addressRow.orientation = .horizontal
        addressRow.alignment = .firstBaseline
        addressRow.spacing = 10

        let qrStack = NSStackView(views: [qrCaption, qrImageView, fundingHintLabel, addressRow])
        qrStack.orientation = .vertical
        qrStack.alignment = .leading
        qrStack.spacing = 9

        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            qrImageView.widthAnchor.constraint(equalToConstant: 124),
            qrImageView.heightAnchor.constraint(equalToConstant: 124),
        ])

        let stack = NSStackView(views: [accountTitleLabel, accountDetailLabel, metricsRow, qrStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        accountDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        fundingHintLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            accountDetailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fundingHintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        installCard(stack, in: accountCard)
        return accountCard
    }

    private func makeComposerBlock() -> NSView {
        let typeCaption = NSTextField(labelWithString: "Transaction Type")
        typeCaption.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        typeCaption.textColor = Palette.faintText
        configureMetricCaption(typeCaption)

        let recipientCaption = NSTextField(labelWithString: "Recipient")
        recipientCaption.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        recipientCaption.textColor = Palette.faintText
        configureMetricCaption(recipientCaption)

        let amountCaption = NSTextField(labelWithString: "Amount")
        amountCaption.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        amountCaption.textColor = Palette.faintText
        configureMetricCaption(amountCaption)

        let typeStack = NSStackView(views: [typeCaption, transactionTypePopup])
        typeStack.orientation = .vertical
        typeStack.alignment = .leading
        typeStack.spacing = 8

        let recipientStack = NSStackView(views: [recipientCaption, recipientField])
        recipientStack.orientation = .vertical
        recipientStack.alignment = .leading
        recipientStack.spacing = 8

        let amountStack = NSStackView(views: [amountCaption, amountField])
        amountStack.orientation = .vertical
        amountStack.alignment = .leading
        amountStack.spacing = 8

        recipientField.translatesAutoresizingMaskIntoConstraints = false
        amountField.translatesAutoresizingMaskIntoConstraints = false
        transactionTypePopup.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            transactionTypePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            recipientField.widthAnchor.constraint(equalToConstant: 300),
            recipientField.heightAnchor.constraint(equalToConstant: 32),
            amountField.widthAnchor.constraint(equalToConstant: 140),
            amountField.heightAnchor.constraint(equalToConstant: 32),
        ])

        let formRow = NSStackView(views: [recipientStack, amountStack])
        formRow.orientation = .horizontal
        formRow.alignment = .top
        formRow.spacing = 16

        let buttonRow = NSView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addSubview(buildDraftButton)
        buttonRow.addSubview(sendUserOperationButton)
        buildDraftButton.translatesAutoresizingMaskIntoConstraints = false
        sendUserOperationButton.translatesAutoresizingMaskIntoConstraints = false
        buildDraftButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        sendUserOperationButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            buttonRow.heightAnchor.constraint(equalToConstant: 34),
            buildDraftButton.leadingAnchor.constraint(equalTo: buttonRow.leadingAnchor),
            buildDraftButton.topAnchor.constraint(equalTo: buttonRow.topAnchor),
            buildDraftButton.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
            sendUserOperationButton.leadingAnchor.constraint(equalTo: buildDraftButton.trailingAnchor, constant: 12),
            sendUserOperationButton.topAnchor.constraint(equalTo: buttonRow.topAnchor),
            sendUserOperationButton.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
            sendUserOperationButton.trailingAnchor.constraint(lessThanOrEqualTo: buttonRow.trailingAnchor),
        ])

        let actionBlock = NSStackView(views: [composerSummaryLabel, buttonRow, submissionStatusLabel])
        actionBlock.orientation = .vertical
        actionBlock.alignment = .leading
        actionBlock.spacing = 12
        actionBlock.setContentCompressionResistancePriority(.required, for: .vertical)

        let stack = NSStackView(views: [
            composerTitleLabel,
            composerDetailLabel,
            typeStack,
            formRow,
            actionBlock,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        composerDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        composerSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        actionBlock.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            composerDetailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionBlock.widthAnchor.constraint(equalTo: stack.widthAnchor),
            composerSummaryLabel.widthAnchor.constraint(equalTo: actionBlock.widthAnchor),
            submissionStatusLabel.widthAnchor.constraint(equalTo: actionBlock.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: actionBlock.widthAnchor),
        ])
        installCard(stack, in: composerCard)
        return composerCard
    }

    private func makeRelayerBlock() -> NSView {
        let addressCaption = NSTextField(labelWithString: "Relayer Address")
        addressCaption.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        addressCaption.textColor = Palette.faintText
        configureMetricCaption(addressCaption)

        let balanceCaption = NSTextField(labelWithString: "Balance")
        balanceCaption.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        balanceCaption.textColor = Palette.faintText
        configureMetricCaption(balanceCaption)

        let historyCaption = NSTextField(labelWithString: "History Target")
        historyCaption.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        historyCaption.textColor = Palette.faintText
        configureMetricCaption(historyCaption)

        let addressStack = NSStackView(views: [addressCaption, relayerAddressLabel])
        addressStack.orientation = .vertical
        addressStack.alignment = .leading
        addressStack.spacing = 5

        let balanceStack = NSStackView(views: [balanceCaption, relayerBalanceLabel])
        balanceStack.orientation = .vertical
        balanceStack.alignment = .leading
        balanceStack.spacing = 5

        let metricsRow = NSStackView(views: [addressStack, balanceStack, relayerLifecycleLabel])
        metricsRow.orientation = .horizontal
        metricsRow.alignment = .centerY
        metricsRow.spacing = 24
        addressStack.translatesAutoresizingMaskIntoConstraints = false
        balanceStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            addressStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            balanceStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])

        let historyStack = NSStackView(views: [historyCaption, relayerHistoryPopup])
        historyStack.orientation = .vertical
        historyStack.alignment = .leading
        historyStack.spacing = 5
        relayerHistoryPopup.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            relayerHistoryPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])

        let buttonRow = NSStackView(views: [
            refreshRelayerButton,
            rotateRelayerButton,
            exportRelayerButton,
            deleteRelayerButton,
        ])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10

        let headerRow = NSStackView(views: [relayerTitleLabel, buttonRow])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 16

        let stack = NSStackView(views: [
            headerRow,
            relayerDetailLabel,
            metricsRow,
            historyStack,
            relayerAuditLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        relayerDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        relayerAuditLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            relayerDetailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            relayerAuditLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        installCard(stack, in: relayerCard)
        return relayerCard
    }

    private func makeLogsBlock() -> NSView {
        let headerRow = NSStackView(views: [logsTitleLabel, clearLogsButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12

        debugLogScrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            debugLogScrollView.heightAnchor.constraint(equalToConstant: 88),
        ])

        let stack = NSStackView(views: [headerRow, logsDetailLabel, debugLogScrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        logsDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logsDetailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            debugLogScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        installCard(stack, in: logsCard)
        return logsCard
    }

    private func render() {
        let isWorking = model.isBootstrapping || model.isRunningDemo || model.isBuildingUserOperation || model.isSendingUserOperation

        progressIndicator.isHidden = !isWorking
        if isWorking {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }

        reloadButton.isEnabled = !model.isBootstrapping && !model.isSendingUserOperation
        let canRefreshBalance = model.walletRecord != nil
            && !model.isBootstrapping
            && !model.isRunningDemo
            && !model.isRefreshingBalance
            && !model.isBuildingUserOperation
            && !model.isSendingUserOperation
        refreshBalanceButton.isEnabled = canRefreshBalance
        refreshBalanceButton.title = model.isRefreshingBalance ? "Refreshing…" : "Refresh"
        styleButton(refreshBalanceButton, role: canRefreshBalance ? .quiet : .disabled)
        testnetButton.isEnabled = !model.isBootstrapping && !model.isRunningDemo && !model.isRefreshingBalance && !model.isBuildingUserOperation && !model.isSendingUserOperation
        testnetButton.state = model.configuration.isTestnetModeEnabled ? .on : .off

        networkLabel.stringValue = model.activeChain.name.uppercased()
        stateLabel.stringValue = badgeStateTitle()
        tintBadge(stateLabel, color: badgeStateColor())
        tintBadge(networkLabel, color: model.activeChain.isTestnet ? Palette.orange : Palette.blue)

        statusHeadlineLabel.stringValue = model.bridgeStatus
        rpcLabel.stringValue = "RPC  \(model.activeChain.rpcURL.absoluteString)"

        if let record = model.walletRecord {
            addressLabel.stringValue = record.kernelAccountAddress ?? "Address unavailable"
        } else {
            addressLabel.stringValue = "Waiting for Secure Enclave bootstrap…"
        }

        renderAccountCard()
        renderComposerCard()
        renderRelayerCard()
        renderDebugLog()
    }

    private func renderAccountCard() {
        guard let record = model.walletRecord, let address = record.kernelAccountAddress else {
            accountDetailLabel.stringValue = "Wallet bootstrap has not finished yet."
            deploymentValueLabel.stringValue = "Loading"
            balanceValueLabel.stringValue = "—"
            fundingHintLabel.stringValue = ""
            fundingAddressLabel.stringValue = ""
            qrImageView.image = nil
            return
        }

        if let inspection = model.accountInspection {
            deploymentValueLabel.stringValue = inspection.stateTitle
            fundingAddressLabel.stringValue = address
            if inspection.isDeployed {
                accountDetailLabel.stringValue = "Live on \(model.activeChain.name). Balance and transaction composition are ready."
                balanceValueLabel.stringValue = inspection.balanceDisplay
                fundingHintLabel.stringValue = "Code is deployed. The QR still targets this account for funding or receiving ETH."
                qrImageView.image = qrCodeFactory.image(for: "ethereum:\(address)", dimension: 180)
            } else {
                accountDetailLabel.stringValue = "Precomputed account. It can receive ETH now; the first UserOperation deploys it automatically."
                balanceValueLabel.stringValue = inspection.balanceDisplay
                fundingHintLabel.stringValue = "Fund this Sepolia address first. Deployment initCode and execution calldata are bundled together on first send."
                qrImageView.image = qrCodeFactory.image(for: "ethereum:\(address)", dimension: 180)
            }
        } else {
            deploymentValueLabel.stringValue = "Precomputed"
            balanceValueLabel.stringValue = "Inspecting…"
            accountDetailLabel.stringValue = "Address is computed locally. If there is no bytecode yet, the first UserOperation deploys it."
            fundingHintLabel.stringValue = "You can already fund this predicted address. The QR encodes `ethereum:\(address)`."
            fundingAddressLabel.stringValue = address
            qrImageView.image = qrCodeFactory.image(for: "ethereum:\(address)", dimension: 180)
        }
    }

    private func renderComposerCard() {
        let composer = model.transactionComposer
        transactionTypePopup.selectItem(withTitle: composer.selectedKind.rawValue)
        if recipientField.stringValue != composer.recipient {
            recipientField.stringValue = composer.recipient
        }
        if amountField.stringValue != composer.amountETH {
            amountField.stringValue = composer.amountETH
        }
        composerSummaryLabel.stringValue = composer.summary
        let canBuildUserOperation = model.walletRecord != nil
            && !model.isBootstrapping
            && !model.isBuildingUserOperation
            && !model.isSendingUserOperation
        buildDraftButton.isEnabled = canBuildUserOperation
        buildDraftButton.title = model.isBuildingUserOperation ? "Building Draft…" : "Build UserOperation Draft"
        styleButton(buildDraftButton, role: canBuildUserOperation ? .secondary : .disabled)

        let canSendUserOperation = model.walletRecord != nil
            && !model.isBootstrapping
            && !model.isBuildingUserOperation
            && !model.isSendingUserOperation
        sendUserOperationButton.isEnabled = canSendUserOperation
        sendUserOperationButton.title = model.isSendingUserOperation ? "Sending…" : "Send UserOperation"
        styleButton(sendUserOperationButton, role: canSendUserOperation ? .primary : .disabled)
        submissionStatusLabel.stringValue = makeSubmissionStatusSummary()
        userOpDraftTextView.string = makeUserOperationDraftSummary()
    }

    private func renderRelayerCard() {
        relayerDetailLabel.stringValue = model.localRelayerMessage

        if let status = model.localRelayerStatus {
            populateRelayerHistoryPopup(status)
            relayerAddressLabel.stringValue = status.eoa
            relayerBalanceLabel.stringValue = "\(status.balance) / low \(status.thresholdLow)"
            relayerLifecycleLabel.stringValue = status.lifecycle.uppercased()
            tintBadge(
                relayerLifecycleLabel,
                color: status.ready ? Palette.primaryGreen : (status.needsTopup ? Palette.orange : Palette.blue)
            )
            let rotation = status.pendingFundingCount > 0 || status.retiringCount > 0
                ? "pendingFunding=\(status.pendingFundingCount), retiring=\(status.retiringCount)"
                : "no rotation in progress"
            if let pendingFundingAddress = status.pendingFundingAddress {
                relayerDetailLabel.stringValue = "New relayer key is waiting for top-up: \(pendingFundingAddress)"
            }
            relayerAuditLabel.stringValue = status.latestAuditEvent.map {
                "Latest audit event: \($0). Rotation: \(rotation)."
            } ?? "Rotation: \(rotation)."
        } else {
            selectedRelayerKeyRef = nil
            relayerHistoryPopup.removeAllItems()
            relayerHistoryPopup.addItem(withTitle: "No relayer history")
            relayerHistoryPopup.isEnabled = false
            relayerAddressLabel.stringValue = "—"
            relayerBalanceLabel.stringValue = "—"
            relayerLifecycleLabel.stringValue = model.hasLocalRelayerClient ? "UNKNOWN" : "OFFLINE"
            tintBadge(relayerLifecycleLabel, color: Palette.faintText)
            relayerAuditLabel.stringValue = ""
        }

        let relayerBusy = model.isRefreshingLocalRelayer
            || model.isRotatingLocalRelayer
            || model.isExportingLocalRelayer
            || model.isDeletingLocalRelayer
        let canUseRelayer = model.hasLocalRelayerClient && !relayerBusy
        let selectedTarget = selectedRelayerAdminTarget()
        let canExportSelectedKey = canUseRelayer && selectedTarget?.canExport == true
        let canDeleteSelectedKey = canUseRelayer && selectedTarget?.canDelete == true

        refreshRelayerButton.isEnabled = canUseRelayer
        refreshRelayerButton.title = model.isRefreshingLocalRelayer ? "Refreshing…" : "Refresh"
        styleButton(refreshRelayerButton, role: canUseRelayer ? .quiet : .disabled)

        rotateRelayerButton.isEnabled = canUseRelayer
        rotateRelayerButton.title = model.isRotatingLocalRelayer ? "Rotating…" : "Rotate"
        styleButton(rotateRelayerButton, role: canUseRelayer ? .secondary : .disabled)

        exportRelayerButton.isEnabled = canExportSelectedKey
        exportRelayerButton.title = model.isExportingLocalRelayer ? "Exporting…" : "Export"
        styleButton(exportRelayerButton, role: canExportSelectedKey ? .secondary : .disabled)

        deleteRelayerButton.isEnabled = canDeleteSelectedKey
        deleteRelayerButton.title = model.isDeletingLocalRelayer ? "Deleting…" : "Delete / Reset"
        styleButton(deleteRelayerButton, role: canDeleteSelectedKey ? .quiet : .disabled)
    }

    private func populateRelayerHistoryPopup(_ status: WalletNodeClient.RelayerStatus) {
        let previousSelection = selectedRelayerKeyRef
        relayerHistoryPopup.removeAllItems()

        let entries = status.keyHistory.isEmpty
            ? status.keyRef.map {
                [WalletNodeClient.RelayerStatus.KeyHistoryEntry(
                    eoa: status.eoa,
                    keyRef: $0,
                    lifecycle: status.lifecycle,
                    createdAt: nil,
                    retiredAt: nil,
                    deletedAt: nil,
                    lastExportedAt: nil
                )]
            } ?? []
            : status.keyHistory

        for entry in entries {
            let prefix = entry.keyRef == status.keyRef ? "Current" : "History"
            relayerHistoryPopup.addItem(withTitle: "\(prefix): \(entry.displayTitle)")
            relayerHistoryPopup.lastItem?.representedObject = entry.keyRef
            relayerHistoryPopup.lastItem?.isEnabled = entry.canExport || entry.canDelete
        }

        let fallbackSelection = status.keyRef ?? entries.first?.keyRef
        let nextSelection = entries.contains(where: { $0.keyRef == previousSelection })
            ? previousSelection
            : fallbackSelection
        selectedRelayerKeyRef = nextSelection

        if let nextSelection,
           let item = relayerHistoryPopup.itemArray.first(where: { $0.representedObject as? String == nextSelection }) {
            relayerHistoryPopup.select(item)
        }
        relayerHistoryPopup.isEnabled = entries.count > 1
    }

    private func selectedRelayerAdminTarget() -> (keyRef: String, label: String, canExport: Bool, canDelete: Bool)? {
        guard let status = model.localRelayerStatus else {
            return nil
        }
        let keyRef = selectedRelayerKeyRef ?? status.keyRef
        guard let keyRef else {
            return nil
        }
        if let entry = status.keyHistory.first(where: { $0.keyRef == keyRef }) {
            return (
                keyRef: entry.keyRef,
                label: entry.eoa.shortAddress,
                canExport: entry.canExport,
                canDelete: entry.canDelete
            )
        }
        return (
            keyRef: keyRef,
            label: status.eoa.shortAddress,
            canExport: true,
            canDelete: true
        )
    }

    private func renderDebugLog() {
        if debugLogTextView.string != model.debugLogText {
            debugLogTextView.string = model.debugLogText
            debugLogTextView.scrollToEndOfDocument(nil)
        }
    }

    private func badgeStateTitle() -> String {
        if model.isBootstrapping {
            return "BOOTSTRAPPING"
        }
        if model.isRunningDemo {
            return "INSPECTING"
        }
        if model.isSendingUserOperation {
            return "SENDING"
        }
        if let inspection = model.accountInspection {
            return inspection.isDeployed ? "DEPLOYED" : "PRECOMPUTED"
        }
        return model.walletRecord == nil ? "LOCKED" : "PRECOMPUTED"
    }

    private func badgeStateColor() -> NSColor {
        if model.isBootstrapping || model.isRunningDemo {
            return NSColor.systemYellow
        }
        if model.isSendingUserOperation {
            return NSColor.systemPurple
        }
        if let inspection = model.accountInspection {
            return inspection.isDeployed ? NSColor.systemGreen : NSColor.systemOrange
        }
        return model.walletRecord == nil ? NSColor.systemRed : NSColor.systemOrange
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else {
            return
        }

        switch field.tag {
        case InputTag.recipient:
            model.updateRecipient(field.stringValue)
        case InputTag.amount:
            model.updateAmountETH(field.stringValue)
        default:
            break
        }
    }

    @objc
    private func reloadWallet() {
        model.bootstrap()
    }

    @objc
    private func refreshBalance() {
        model.refreshBalance()
    }

    @objc
    private func toggleTestnetMode() {
        model.setTestnetModeEnabled(testnetButton.state == .on)
    }

    @objc
    private func transactionTypeChanged() {
        guard let title = transactionTypePopup.selectedItem?.title,
              let kind = DemoTransactionKind(rawValue: title) else {
            return
        }
        model.setTransactionKind(kind)
    }

    @objc
    private func buildUserOperationDraft() {
        statusHeadlineLabel.stringValue = "Build UserOperation Draft clicked."
        model.buildUserOperationDraftPreview()
    }

    @objc
    private func sendUserOperation() {
        statusHeadlineLabel.stringValue = "Send UserOperation clicked."
        model.sendCurrentUserOperation()
    }

    @objc
    private func refreshLocalRelayer() {
        model.refreshLocalRelayerStatus()
    }

    @objc
    private func selectRelayerHistoryEntry() {
        selectedRelayerKeyRef = relayerHistoryPopup.selectedItem?.representedObject as? String
        renderRelayerCard()
    }

    @objc
    private func rotateLocalRelayer() {
        let alert = NSAlert()
        alert.messageText = "Rotate local relayer key?"
        alert.informativeText = "A new relayer key will be created and wait for top-up. The current key keeps submitting operations until the new key is funded."
        alert.addButton(withTitle: "Rotate")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        runConfirmation(alert) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.model.rotateLocalRelayerKey()
                } catch {
                    self.showError("Rotation failed", error)
                }
            }
        }
    }

    @objc
    private func exportLocalRelayer() {
        guard let target = selectedRelayerAdminTarget() else {
            showError("Export failed", AppError.localRelayerKeyMissing)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Export local relayer private key?"
        alert.informativeText = "The exported key for \(target.label) can spend ETH held by that relayer address. It cannot authorize smart-account transfers."
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .critical

        runConfirmation(alert) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let privateKey = try await self.model.exportLocalRelayerKey(
                        keyRef: target.keyRef,
                        label: target.label
                    )
                    self.showExportedRelayerKey(privateKey)
                } catch {
                    self.showError("Export failed", error)
                }
            }
        }
    }

    @objc
    private func deleteLocalRelayer() {
        guard let target = selectedRelayerAdminTarget() else {
            showError("Delete failed", AppError.localRelayerKeyMissing)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete or reset local relayer key?"
        alert.informativeText = "This targets \(target.label). Safe delete is blocked when pending relayer transactions exist. Unsafe reset deletes key material anyway and can orphan pending relay state."
        alert.addButton(withTitle: "Safe Delete")
        alert.addButton(withTitle: "Unsafe Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .critical

        let runDelete: (Bool) -> Void = { [weak self] unsafeReset in
            guard let self else { return }
            Task {
                do {
                    try await self.model.deleteLocalRelayerKey(
                        keyRef: target.keyRef,
                        label: target.label,
                        unsafeReset: unsafeReset
                    )
                } catch {
                    self.showError(unsafeReset ? "Unsafe reset failed" : "Delete failed", error)
                }
            }
        }

        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    runDelete(false)
                } else if response == .alertSecondButtonReturn {
                    runDelete(true)
                }
            }
        } else {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                runDelete(false)
            } else if response == .alertSecondButtonReturn {
                runDelete(true)
            }
        }
    }

    @objc
    private func clearDebugLog() {
        model.clearDebugLog()
    }

    @objc
    private func showHowItWorks() {
        let alert = NSAlert()
        alert.messageText = "How the demo works"
        alert.informativeText = """
        1. The app creates or loads a P-256 signing key in Secure Enclave.

        2. Rust helpers compute the Kernel account setup, WebAuthn signing payload, UserOperation hash, and final validator signature encoding.

        3. The app precomputes the Kernel smart-account address on Sepolia and checks its deployment state and balance through local wallet-node. A precomputed account is not deployed yet, but it can already receive ETH.

        4. If the account is still precomputed, the first UserOperation includes Kernel factory deployment initCode. The EntryPoint deploys the smart account and executes the requested call in the same flow.

        5. For an ETH transfer, the app builds an ERC-4337 UserOperation, asks local wallet-node for gas estimates, signs locally after user approval, submits it through the local bundler, and polls for a receipt.

        This is a Sepolia-only demo, not the final wallet product.
        """
        alert.addButton(withTitle: "Close")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc
    private func copyAddress() {
        guard let address = model.walletRecord?.kernelAccountAddress else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(address, forType: .string)

        pendingCopyResetWorkItem?.cancel()
        heroCopyAddressButton.title = "Copied"
        accountCopyAddressButton.title = "Copied"
        heroCopyAddressButton.contentTintColor = NSColor.systemGreen
        accountCopyAddressButton.contentTintColor = NSColor.systemGreen
        statusHeadlineLabel.stringValue = "Predicted smart-account address copied."

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.heroCopyAddressButton.title = "Copy Address"
            self.accountCopyAddressButton.title = "Copy Address"
            self.heroCopyAddressButton.contentTintColor = nil
            self.accountCopyAddressButton.contentTintColor = nil
            self.statusHeadlineLabel.stringValue = self.model.bridgeStatus
            self.pendingCopyResetWorkItem = nil
        }
        pendingCopyResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: workItem)
    }

    private func runConfirmation(_ alert: NSAlert, confirmed: @escaping () -> Void) {
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    confirmed()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            confirmed()
        }
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Close")
        alert.alertStyle = .warning
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func showExportedRelayerKey(_ privateKey: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(privateKey, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Relayer private key copied"
        alert.informativeText = privateKey
        alert.addButton(withTitle: "Close")
        alert.alertStyle = .warning
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func installCard(_ content: NSView, in card: NSView) {
        card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
        ])
    }

    private static func makeCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 22
        card.layer?.masksToBounds = false
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Palette.cardBorder.cgColor
        card.layer?.backgroundColor = Palette.cardFill.cgColor
        card.layer?.shadowColor = Palette.cardShadow.cgColor
        card.layer?.shadowOpacity = 0.32
        card.layer?.shadowRadius = 22
        card.layer?.shadowOffset = CGSize(width: 0, height: 10)
        return card
    }

    private enum ButtonRole {
        case primary
        case secondary
        case quiet
        case disabled
    }

    private func styleButton(_ button: NSButton, role: ButtonRole) {
        button.isBordered = true

        let titleColor: NSColor
        let titleWeight: NSFont.Weight

        switch role {
        case .primary:
            button.bezelColor = Palette.primaryGreen
            titleColor = .white
            titleWeight = .bold
        case .secondary:
            button.bezelColor = Palette.controlFill
            titleColor = .white
            titleWeight = .semibold
        case .quiet:
            button.bezelColor = NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.19, alpha: 1.0)
            titleColor = .white
            titleWeight = .medium
        case .disabled:
            button.bezelColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)
            titleColor = Palette.faintText.withAlphaComponent(0.62)
            titleWeight = .medium
        }

        let font = NSFont.systemFont(ofSize: 13, weight: titleWeight)
        button.font = font
        button.contentTintColor = titleColor
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .foregroundColor: titleColor,
                .font: font,
            ]
        )
    }

    private func configureInputField(_ field: NSTextField) {
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = Palette.controlFill
        field.textColor = Palette.text
        field.focusRingType = .exterior
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.setContentHuggingPriority(.required, for: .vertical)

        if let placeholder = field.placeholderString {
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [
                    .foregroundColor: Palette.faintText,
                    .font: field.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                ]
            )
        }

        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.isScrollable = true
            cell.wraps = false
        }
    }

    private func configureMetricCaption(_ label: NSTextField) {
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
        configureSelectableLabel(label)
    }

    private func configureWrappingLabel(_ label: NSTextField) {
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.defaultHigh, for: .vertical)
        if let cell = label.cell as? NSTextFieldCell {
            cell.wraps = true
            cell.usesSingleLineMode = false
            cell.isScrollable = false
        }
    }

    private func configureTitleLabel(_ label: NSTextField) {
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        if let cell = label.cell as? NSTextFieldCell {
            cell.wraps = false
            cell.usesSingleLineMode = true
            cell.isScrollable = false
        }

        let minimumHeight: CGFloat = label === titleLabel ? 56 : 30
        label.translatesAutoresizingMaskIntoConstraints = false
        label.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
    }

    private func configureSelectableLabel(_ label: NSTextField) {
        label.isSelectable = true
        label.allowsEditingTextAttributes = false
        label.importsGraphics = false
        label.isBezeled = false
        label.isBordered = false
        label.drawsBackground = false
        label.focusRingType = .none
        label.refusesFirstResponder = false
    }

    private static func makeBadge() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
        label.textColor = Palette.text
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 9
        label.layer?.masksToBounds = true
        label.layer?.backgroundColor = Palette.blue.withAlphaComponent(0.18).cgColor
        label.layer?.borderWidth = 1
        label.layer?.borderColor = Palette.blue.withAlphaComponent(0.35).cgColor
        label.cell?.wraps = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.heightAnchor.constraint(equalToConstant: 24),
            label.widthAnchor.constraint(equalToConstant: 124),
        ])
        return label
    }

    private func tintBadge(_ label: NSTextField, color: NSColor) {
        label.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        label.layer?.borderColor = color.withAlphaComponent(0.38).cgColor
        label.textColor = color.blended(withFraction: 0.28, of: .white) ?? Palette.text
    }

    private func configureFixedLayoutBehavior() {
        [heroCard, accountCard, composerCard, logsCard].forEach {
            $0.setContentCompressionResistancePriority(.required, for: .vertical)
            $0.setContentHuggingPriority(.required, for: .vertical)
        }

        [networkLabel, stateLabel].forEach {
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        addressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rpcLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fundingAddressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [heroCopyAddressButton, accountCopyAddressButton, refreshBalanceButton, clearLogsButton].forEach {
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
    }

    private func makeUserOperationDraftSummary() -> String {
        if let error = model.lastUserOperationBuildError {
            return "Build error: \(error)"
        }

        guard let draft = model.builtUserOperationDraft else {
            return """
            No draft built yet.
            Build an unsigned ERC-4337 UserOperation locally to inspect nonce, deployment path, calldata, and hash before signing or submission.
            """
        }

        let hashValue: String
        do {
            let userOpHash = try draft.userOpHash()
            hashValue = "0x" + userOpHash.hexEncodedString
        } catch {
            hashValue = "unavailable (\(error.localizedDescription))"
        }

        let deploymentMode = draft.initCode.isEmpty ? "existing account" : "includes deployment initCode"

        return """
        sender: \(draft.sender)
        nonce: 0x\(draft.nonce.hexEncodedString)
        mode: \(deploymentMode)
        initCode bytes: \(draft.initCode.count)
        callData bytes: \(draft.callData.count)
        accountGasLimits: 0x\(draft.gasPlan.accountGasLimits.hexEncodedString)
        preVerificationGas: 0x\(draft.gasPlan.preVerificationGas.hexEncodedString)
        gasFees: 0x\(draft.gasPlan.gasFees.hexEncodedString)
        entryPoint: \(draft.entryPoint)
        chainId: \(draft.chainId)
        userOpHash: \(hashValue)
        """
    }

    private func makeSubmissionStatusSummary() -> String {
        if let error = model.lastError, model.isSendingUserOperation == false {
            return "Last send error: \(error)"
        }

        if model.isSendingUserOperation {
            return "Signing and sending through local wallet-node on \(model.activeChain.shortName). Watch the debug activity panel for per-step logs."
        }

        if let userOpHash = model.lastSubmittedUserOperationHash {
            if let transactionHash = model.lastBundledTransactionHash {
                return "Last submission: \(userOpHash.shortAddress) included in bundle tx \(transactionHash.shortAddress)."
            }
            return "Last submission: \(userOpHash.shortAddress). Receipt may still be pending."
        }

        return "Build the draft, then send it through local wallet-node. The app will re-check deployment state, estimate gas, sign via Secure Enclave, and poll for a receipt."
    }
}

private extension String {
    var shortAddress: String {
        guard count > 14 else { return self }
        let prefix = prefix(8)
        let suffix = suffix(6)
        return "\(prefix)…\(suffix)"
    }
}
