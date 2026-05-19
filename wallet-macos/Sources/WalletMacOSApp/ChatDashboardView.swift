import AppKit
import SwiftUI
import WalletToolLayer

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case userText
        case assistantText
        case toolIntent
        case toolResponse
    }
    enum Role: String, Codable { case user, assistant, tool }
    var id = UUID()
    var kind: Kind
    var role: Role
    var text: String? = nil
    var thinking: String? = nil
    var stats: ChatGenerationStats? = nil
    var toolIntent: ToolIntent? = nil
    var toolCallId: String? = nil

    static func userText(_ text: String) -> ChatMessage {
        ChatMessage(kind: .userText, role: .user, text: text)
    }
    static func assistantText(_ text: String, thinking: String? = nil, stats: ChatGenerationStats? = nil) -> ChatMessage {
        ChatMessage(kind: .assistantText, role: .assistant, text: text, thinking: thinking, stats: stats)
    }
}

struct ChatGenerationStats: Equatable, Codable {
    let duration: TimeInterval
    let promptTokens: Int
    let generatedTokens: Int
    let contextSize: Int

    var usedContextTokens: Int {
        promptTokens + generatedTokens
    }

    var contextTokensLeft: Int {
        max(contextSize - usedContextTokens, 0)
    }
}

struct ChatConversation: Identifiable, Equatable, Codable {
    var id = UUID()
    var title: String
    var messages: [ChatMessage]
    var createdAt = Date()
    var updatedAt = Date()
}

private struct ChatAccountIdentity: Equatable {
    let kernelAddress: String
    let bundlerAddress: String
}

@MainActor
private final class ChatDashboardModel: ObservableObject {
    @Published var inputText = ""
    @Published private(set) var conversations: [ChatConversation]
    @Published private(set) var activeConversationID: UUID
    @Published private(set) var isGenerating = false
    @Published private(set) var runtimeStatus: String
    @Published var thinkingEnabled = true
    @Published var isSidebarVisible = true
    @Published private(set) var accountIdentity: ChatAccountIdentity

    private let inferenceService: EmbeddedLlamaInferenceService
    private let chatStore: ChatSQLiteStore
    private let preferencesStore: ChatPreferencesStore

    init(
        inferenceService: EmbeddedLlamaInferenceService = EmbeddedLlamaInferenceService(),
        chatStore: ChatSQLiteStore = ChatSQLiteStore(),
        preferencesStore: ChatPreferencesStore = ChatPreferencesStore(),
        settingsStore: OnboardingSettingsStore = OnboardingSettingsStore(),
        metadataStore: WalletMetadataStore = WalletMetadataStore()
    ) {
        self.inferenceService = inferenceService
        self.chatStore = chatStore
        self.preferencesStore = preferencesStore
        self.runtimeStatus = inferenceService.runtimeStatus
        self.thinkingEnabled = preferencesStore.thinkingEnabled
        self.isSidebarVisible = preferencesStore.sidebarVisible

        if !preferencesStore.migratedToSQLite {
            let legacyConversations = preferencesStore.loadLegacyConversations()
            if !legacyConversations.isEmpty {
                try? chatStore.replaceConversations(legacyConversations)
            }
            preferencesStore.migratedToSQLite = true
        }

        let loadedConversations = ((try? chatStore.loadConversations()) ?? []).sorted { $0.updatedAt > $1.updatedAt }
        if loadedConversations.isEmpty {
            let conversation = ChatConversation(title: "New chat", messages: [])
            self.conversations = [conversation]
            self.activeConversationID = conversation.id
            try? chatStore.createConversation(conversation)
        } else {
            self.conversations = loadedConversations
            self.activeConversationID = preferencesStore.activeConversationID.flatMap { savedID in
                loadedConversations.contains { $0.id == savedID } ? savedID : nil
            } ?? loadedConversations[0].id
        }

        let kernelAddress = (try? metadataStore.load())?.kernelAccountAddress ?? "Not available"
        self.accountIdentity = ChatAccountIdentity(
            kernelAddress: kernelAddress,
            bundlerAddress: settingsStore.bundlerAddress ?? "Not available"
        )
        preferencesStore.activeConversationID = self.activeConversationID
    }

    var activeConversation: ChatConversation? {
        conversations.first { $0.id == activeConversationID }
    }

    var messages: [ChatMessage] {
        activeConversation?.messages ?? []
    }

    var contextStatsText: String {
        guard let stats = messages.last(where: { $0.stats != nil })?.stats else {
            return "Context 0 / \(inferenceService.contextSize) · \(inferenceService.contextSize) left"
        }
        return "Context \(stats.usedContextTokens) / \(stats.contextSize) · \(stats.contextTokensLeft) left"
    }

    func toggleThinking() {
        thinkingEnabled.toggle()
        preferencesStore.thinkingEnabled = thinkingEnabled
    }

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSidebarVisible.toggle()
        }
        preferencesStore.sidebarVisible = isSidebarVisible
    }

    func createNewChat() {
        guard !isGenerating else {
            return
        }
        let conversation = ChatConversation(title: "New chat", messages: [])
        conversations.insert(conversation, at: 0)
        activeConversationID = conversation.id
        preferencesStore.activeConversationID = conversation.id
        try? chatStore.createConversation(conversation)
    }

    func selectConversation(_ conversation: ChatConversation) {
        guard !isGenerating else {
            return
        }
        activeConversationID = conversation.id
        preferencesStore.activeConversationID = conversation.id
    }

    func send(_ text: String? = nil) {
        let prompt = (text ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating else {
            return
        }

        let conversationID = activeConversationID
        let existingMessages = messages
        let history = existingMessages.map { message in
            EmbeddedLlamaChatTurn(
                role: message.role == .user ? .user : .assistant,
                text: message.text ?? ""
            )
        }
        inputText = ""
        appendMessage(.userText(prompt), to: conversationID)
        updateTitleIfNeeded(for: conversationID, prompt: prompt)
        isGenerating = true
        runtimeStatus = thinkingEnabled ? "Gemma is thinking" : "Gemma is generating"

        Task {
            do {
                let response = try await inferenceService.generate(
                    prompt: prompt,
                    history: history,
                    thinkingEnabled: thinkingEnabled
                )
                let stats = ChatGenerationStats(
                    duration: response.duration,
                    promptTokens: response.promptTokens,
                    generatedTokens: response.generatedTokens,
                    contextSize: response.contextSize
                )
                appendMessage(.assistantText(response.response, thinking: response.thinking, stats: stats), to: conversationID)
                runtimeStatus = inferenceService.runtimeStatus
            } catch {
                appendMessage(.assistantText(error.localizedDescription), to: conversationID)
                runtimeStatus = "Needs attention"
            }
            isGenerating = false
        }
    }

    private func appendMessage(_ message: ChatMessage, to conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }
        conversations[index].messages.append(message)
        conversations[index].updatedAt = Date()
        let updatedConversation = conversations[index]
        try? chatStore.appendMessage(message, to: conversationID)
        try? chatStore.updateConversationMetadata(updatedConversation)
        sortConversationsKeepingActive()
    }

    private func updateTitleIfNeeded(for conversationID: UUID, prompt: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }
        guard conversations[index].title == "New chat" else {
            return
        }

        let title = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[index].title = String(title.prefix(44))
        try? chatStore.updateConversationMetadata(conversations[index])
    }

    private func sortConversationsKeepingActive() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }
}

struct LocalWalletChatDashboardView: View {
    @StateObject private var model = ChatDashboardModel()

    var body: some View {
        ZStack {
            ChatPalette.background.ignoresSafeArea()
            HStack(spacing: 0) {
                if model.isSidebarVisible {
                    chatSidebar
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                VStack(spacing: 0) {
                    toolbar
                    accountHeader
                    chatBody
                    footerControls
                    composer
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
        }
        .frame(minWidth: 980, minHeight: 720)
    }

    private var chatSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Chats")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(ChatPalette.primaryText)
                Spacer()
                Button {
                    model.createNewChat()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(ChatPalette.primaryText)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(ChatPalette.buttonCircle))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 18)
            .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.conversations) { conversation in
                        ChatConversationRow(
                            conversation: conversation,
                            isSelected: conversation.id == model.activeConversationID
                        ) {
                            model.selectConversation(conversation)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 270)
        .background(ChatPalette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(ChatPalette.border.opacity(0.75))
                .frame(width: 1)
        }
    }

    private var toolbar: some View {
        HStack {
            HStack(spacing: 14) {
                Button {
                    model.toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(ChatPalette.secondaryText)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(ChatPalette.buttonCircle.opacity(model.isSidebarVisible ? 0.75 : 1)))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .frame(width: 180)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(ChatPalette.secondaryText)
                Text("Default")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ChatPalette.primaryText)
            }
            .padding(.horizontal, 13)
            .frame(height: 36)
            .background(Capsule().fill(ChatPalette.panel).overlay(Capsule().stroke(ChatPalette.border, lineWidth: 1)))

            Spacer()

            Menu {
                Toggle("Show thinking", isOn: $model.thinkingEnabled)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ChatPalette.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(ChatPalette.buttonCircle))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(width: 180, alignment: .trailing)
        }
        .frame(height: 42)
    }

    private var accountHeader: some View {
        HStack(spacing: 12) {
            AddressPill(
                icon: "lock.shield.fill",
                title: "Kernel smart account",
                address: model.accountIdentity.kernelAddress
            )
            AddressPill(
                icon: "key.fill",
                title: "Bundler address",
                address: model.accountIdentity.bundlerAddress
            )
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var chatBody: some View {
        if model.messages.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(model.messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }
                        if model.isGenerating {
                            ThinkingBubble()
                                .id("thinking")
                        }
                    }
                    .padding(.vertical, 28)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.messages) { _, messages in
                    if let last = messages.last {
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle()
                    .fill(ChatPalette.avatar)
                    .frame(width: 158, height: 158)
                Image(systemName: "person.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(ChatPalette.secondaryText)
            }
            VStack(spacing: 7) {
                Text(greeting)
                    .font(.system(size: 36, weight: .heavy))
                    .foregroundStyle(ChatPalette.primaryText)
                Text("How can I help you today?")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ChatPalette.secondaryText)
            }
            Spacer()
        }
    }

    private var footerControls: some View {
        HStack(spacing: 8) {
            StatusPill(icon: "circle.fill", text: "Gemma 4 E4B", tint: ChatPalette.success)
            Button {
                model.toggleThinking()
            } label: {
                StatusPill(icon: model.thinkingEnabled ? "brain" : "brain.head.profile", text: model.thinkingEnabled ? "Thinking on" : "Thinking off")
            }
            .buttonStyle(.plain)
            StatusPill(icon: "slider.horizontal.3", text: model.runtimeStatus)
            Spacer()
            Text(model.contextStatsText)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ChatPalette.mutedText)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                PromptTextEditor(text: $model.inputText) {
                    model.send()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .disabled(model.isGenerating)
                    .frame(minHeight: 78, maxHeight: 96)
                if model.inputText.isEmpty {
                    Text("Message Gemma...")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ChatPalette.mutedText)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Text("↩ to send")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ChatPalette.mutedText)
                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .black))
                        .frame(width: 42, height: 42)
                        .foregroundStyle(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isGenerating ? ChatPalette.mutedText : .white)
                        .background(Circle().fill(ChatPalette.accent.opacity(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isGenerating ? 0.35 : 0.95)))
                }
                .buttonStyle(.plain)
                .disabled(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isGenerating)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(ChatPalette.input)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(ChatPalette.accent.opacity(0.78), lineWidth: 1.4)
                )
        )
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return "Good morning"
        case 12..<18:
            return "Good afternoon"
        default:
            return "Good evening"
        }
    }
}

private struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 16, weight: .medium)
        textView.textColor = NSColor(ChatPalette.primaryText)
        textView.insertionPointColor = NSColor(ChatPalette.primaryText)
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit

        if textView.string != text {
            textView.string = text
        }

        textView.isEditable = isEnabled
        textView.textColor = NSColor(ChatPalette.primaryText)
        textView.font = .systemFont(ofSize: 16, weight: .medium)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }

            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                return false
            }

            onSubmit()
            return true
        }
    }
}

private struct ChatConversationRow: View {
    let conversation: ChatConversation
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(conversation.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ChatPalette.primaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text("\(conversation.messages.count) messages")
                    Text("·")
                    Text(conversation.updatedAt, style: .relative)
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ChatPalette.mutedText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? ChatPalette.selectedPanel : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isSelected ? ChatPalette.accent.opacity(0.65) : ChatPalette.border.opacity(0.45), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AddressPill: View {
    let icon: String
    let title: String
    let address: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(ChatPalette.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(ChatPalette.buttonCircle))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(ChatPalette.mutedText)
                    .textCase(.uppercase)
                Text(shortAddress(address))
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundStyle(ChatPalette.primaryText)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 62)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(ChatPalette.panel)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ChatPalette.border, lineWidth: 1))
        )
    }

    private func shortAddress(_ value: String) -> String {
        guard value.hasPrefix("0x"), value.count > 18 else {
            return value
        }

        let prefix = value.prefix(10)
        let suffix = value.suffix(8)
        return "\(prefix)...\(suffix)"
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    @State private var isThinkingExpanded = false

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 90)
            }
            VStack(alignment: .leading, spacing: 10) {
                if let thinking = message.thinking, message.role == .assistant {
                    DisclosureGroup(isExpanded: $isThinkingExpanded) {
                        MarkdownMessageText(markdown: thinking, fontSize: 14, color: ChatPalette.secondaryText)
                            .padding(.top, 6)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "brain")
                                .font(.system(size: 12, weight: .bold))
                            Text("Thinking")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(ChatPalette.secondaryText)
                    }
                    .tint(ChatPalette.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(ChatPalette.input)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ChatPalette.border, lineWidth: 0.8))
                    )
                }

                if message.role == .assistant {
                    MarkdownMessageText(markdown: message.text ?? "", fontSize: 16, color: ChatPalette.primaryText)
                } else {
                    Text(message.text ?? "")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ChatPalette.primaryText)
                        .textSelection(.enabled)
                }

                if let stats = message.stats, message.role == .assistant {
                    Text(stats.formattedSummary)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ChatPalette.mutedText)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(message.role == .user ? ChatPalette.userBubble : ChatPalette.assistantBubble)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(ChatPalette.border, lineWidth: 1)
                    )
            )
            if message.role == .assistant {
                Spacer(minLength: 90)
            }
        }
    }
}

private struct MarkdownMessageText: View {
    let markdown: String
    let fontSize: CGFloat
    let color: Color

    var body: some View {
        Text(attributedMarkdown)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(color)
            .textSelection(.enabled)
    }

    private var attributedMarkdown: AttributedString {
        do {
            return try AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            return AttributedString(markdown)
        }
    }
}

private extension ChatGenerationStats {
    var formattedSummary: String {
        let seconds = duration.formatted(.number.precision(.fractionLength(1)))
        return "\(seconds)s · \(generatedTokens) generated tokens · context \(usedContextTokens)/\(contextSize) · \(contextTokensLeft) left"
    }
}

private struct ThinkingBubble: View {
    var body: some View {
        HStack {
            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.75)
                Text("Thinking with Gemma 4 E4B...")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(ChatPalette.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ChatPalette.assistantBubble))
            Spacer(minLength: 90)
        }
    }
}

private struct StatusPill: View {
    let icon: String
    let text: String
    var tint: Color = ChatPalette.secondaryText

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ChatPalette.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(Capsule().fill(ChatPalette.panel).overlay(Capsule().stroke(ChatPalette.border, lineWidth: 0.8)))
    }
}

private enum ChatPalette {
    static let background = Color(red: 0.045, green: 0.055, blue: 0.115)
    static let sidebar = Color(red: 0.038, green: 0.047, blue: 0.100)
    static let panel = Color(red: 0.063, green: 0.075, blue: 0.135)
    static let selectedPanel = Color(red: 0.095, green: 0.118, blue: 0.215)
    static let input = Color(red: 0.048, green: 0.060, blue: 0.125)
    static let avatar = Color(red: 0.150, green: 0.165, blue: 0.250)
    static let border = Color(red: 0.170, green: 0.205, blue: 0.355)
    static let accent = Color(red: 0.300, green: 0.440, blue: 0.890)
    static let success = Color(red: 0.360, green: 0.900, blue: 0.340)
    static let primaryText = Color(red: 1.000, green: 0.990, blue: 0.880)
    static let secondaryText = Color(red: 0.720, green: 0.770, blue: 0.930)
    static let mutedText = Color(red: 0.460, green: 0.520, blue: 0.710)
    static let userBubble = Color(red: 0.115, green: 0.145, blue: 0.260)
    static let assistantBubble = Color(red: 0.070, green: 0.085, blue: 0.150)
    static let buttonCircle = Color(red: 0.115, green: 0.135, blue: 0.230)
}
