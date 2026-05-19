import AppKit
import SwiftUI
import WalletToolLayer

extension Notification.Name {
    static let chatComposerFocusRequested = Notification.Name("com.localwallet.chat.composer.focus")
}

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case userText
        case assistantText
        case assistantError
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

private enum ChatSidebarBucket: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case lastSevenDays = "Last 7 days"
    case lastThirtyDays = "Last 30 days"
    case older = "Older"

    static func bucket(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ChatSidebarBucket {
        if calendar.isDateInToday(date) {
            return .today
        }
        if calendar.isDateInYesterday(date) {
            return .yesterday
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days <= 7 {
            return .lastSevenDays
        }
        if days <= 30 {
            return .lastThirtyDays
        }
        return .older
    }
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

    var slashSuggestions: [SlashCommand] {
        SlashCatalog.suggestions(for: inputText)
    }

    func insertSlashCommand(_ command: SlashCommand) {
        inputText = command.scaffold
        NotificationCenter.default.post(name: .chatComposerFocusRequested, object: nil)
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

    func renameConversation(_ conversationID: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }
        guard conversations[index].title != trimmed else {
            return
        }
        conversations[index].title = String(trimmed.prefix(120))
        conversations[index].updatedAt = Date()
        try? chatStore.updateConversationMetadata(conversations[index])
        sortConversationsKeepingActive()
    }

    func deleteConversation(_ conversationID: UUID) {
        guard !isGenerating else {
            return
        }
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }
        let wasActive = conversationID == activeConversationID
        conversations.remove(at: index)
        try? chatStore.deleteConversation(conversationID)

        if conversations.isEmpty {
            let replacement = ChatConversation(title: "New chat", messages: [])
            conversations = [replacement]
            try? chatStore.createConversation(replacement)
            activeConversationID = replacement.id
            preferencesStore.activeConversationID = replacement.id
        } else if wasActive {
            let nextID = conversations[0].id
            activeConversationID = nextID
            preferencesStore.activeConversationID = nextID
        }
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

        if prompt.hasPrefix("/") {
            do {
                let intent = try SlashCommandParser().parse(prompt)
                appendMessage(
                    ChatMessage(kind: .toolIntent, role: .assistant, toolIntent: intent),
                    to: conversationID
                )
                return
            } catch {
                // Let the model clarify malformed slash commands in the normal chat flow.
            }
        }

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
                if let firstToolCall = response.toolCalls.first,
                   let tool = ToolIntent.Tool(rawValue: firstToolCall.name) {
                    let intent = ToolIntent(
                        tool: tool,
                        args: firstToolCall.arguments,
                        rawDSL: nil,
                        source: .model
                    )
                    appendMessage(
                        ChatMessage(kind: .toolIntent, role: .assistant, stats: stats, toolIntent: intent),
                        to: conversationID
                    )
                } else if let firstToolCall = response.toolCalls.first {
                    let warning = "[warn] unknown tool: \(firstToolCall.name)\n\n\(response.response)"
                    appendMessage(.assistantText(warning, thinking: response.thinking, stats: stats), to: conversationID)
                } else {
                    appendMessage(.assistantText(response.response, thinking: response.thinking, stats: stats), to: conversationID)
                }
                runtimeStatus = inferenceService.runtimeStatus
            } catch {
                appendMessage(
                    ChatMessage(
                        kind: .assistantError,
                        role: .assistant,
                        text: error.localizedDescription
                    ),
                    to: conversationID
                )
                runtimeStatus = "Needs attention"
            }
            isGenerating = false
        }
    }

    func regenerate(from assistantMessage: ChatMessage) {
        guard !isGenerating else {
            return
        }
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == activeConversationID }) else {
            return
        }
        let messages = conversations[conversationIndex].messages
        guard let assistantIndex = messages.firstIndex(where: { $0.id == assistantMessage.id }) else {
            return
        }

        var userIndex: Int?
        var lookbackIndex = assistantIndex - 1
        while lookbackIndex >= 0 {
            if messages[lookbackIndex].role == .user, messages[lookbackIndex].kind == .userText {
                userIndex = lookbackIndex
                break
            }
            lookbackIndex -= 1
        }
        guard let userIndex else {
            return
        }
        let userPrompt = messages[userIndex].text ?? ""
        guard !userPrompt.isEmpty else {
            return
        }

        let conversationID = conversations[conversationIndex].id
        let removed = Array(messages[userIndex...])
        for message in removed {
            try? chatStore.deleteMessage(message.id, from: conversationID)
        }
        conversations[conversationIndex].messages.removeSubrange(userIndex...)
        conversations[conversationIndex].updatedAt = Date()
        try? chatStore.updateConversationMetadata(conversations[conversationIndex])

        send(userPrompt)
    }

    func confirmIntent(_ message: ChatMessage) {
        updateIntent(message, disposition: .confirmed, args: nil)
    }

    func rejectIntent(_ message: ChatMessage) {
        updateIntent(message, disposition: .rejected, args: nil)
    }

    func editIntent(_ message: ChatMessage, with args: [String: String]) {
        updateIntent(message, disposition: .edited, args: args)
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

    private func updateIntent(_ message: ChatMessage, disposition: ToolIntent.Disposition, args: [String: String]?) {
        guard
            let conversationIndex = conversations.firstIndex(where: { $0.id == activeConversationID }),
            let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == message.id }),
            var intent = conversations[conversationIndex].messages[messageIndex].toolIntent
        else {
            return
        }

        if let args {
            intent.args = args
        }
        intent.disposition = disposition
        intent.updatedAt = Date()

        conversations[conversationIndex].messages[messageIndex].toolIntent = intent
        conversations[conversationIndex].updatedAt = Date()
        let updatedConversation = conversations[conversationIndex]
        try? chatStore.updateMessage(conversations[conversationIndex].messages[messageIndex], in: updatedConversation.id)
        try? chatStore.updateConversationMetadata(updatedConversation)

        let responseText: String
        switch disposition {
        case .confirmed:
            responseText = #"{"status":"acknowledged","intent_id":"\#(intent.id.uuidString)"}"#
        case .edited:
            responseText = editedIntentResponseText(for: intent)
        case .rejected:
            responseText = #"{"status":"rejected","intent_id":"\#(intent.id.uuidString)"}"#
        case .pending:
            return
        }

        appendMessage(
            ChatMessage(
                kind: .toolResponse,
                role: .tool,
                text: responseText,
                toolCallId: intent.id.uuidString
            ),
            to: updatedConversation.id
        )
    }

    private func editedIntentResponseText(for intent: ToolIntent) -> String {
        let payload: [String: Any] = [
            "status": "acknowledged",
            "intent_id": intent.id.uuidString,
            "edited": "true",
            "args": intent.args
        ]

        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"status":"acknowledged","intent_id":"\#(intent.id.uuidString)","edited":"true","args":{}}"#
        }

        return json
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
    @State private var conversationPendingDeletion: ChatConversation?
    @State private var isToolsPopoverPresented = false

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
        .background(keyboardShortcutLayer)
        .alert(
            "Delete chat?",
            isPresented: deletionAlertBinding,
            presenting: conversationPendingDeletion
        ) { conversation in
            Button("Delete", role: .destructive) {
                model.deleteConversation(conversation.id)
            }
            Button("Cancel", role: .cancel) { }
        } message: { conversation in
            Text("“\(conversation.title)” will be removed from this device. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var keyboardShortcutLayer: some View {
        ZStack {
            Button("New chat") {
                model.createNewChat()
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("Focus composer") {
                NotificationCenter.default.post(name: .chatComposerFocusRequested, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
            Button("Delete current chat") {
                if let active = model.activeConversation {
                    conversationPendingDeletion = active
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { conversationPendingDeletion != nil },
            set: { newValue in
                if !newValue {
                    conversationPendingDeletion = nil
                }
            }
        )
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
                LazyVStack(spacing: 8, pinnedViews: []) {
                    ForEach(groupedConversations, id: \.0) { bucket, conversations in
                        sidebarBucketHeader(bucket)
                        ForEach(conversations) { conversation in
                            ChatConversationRow(
                                conversation: conversation,
                                isSelected: conversation.id == model.activeConversationID,
                                onSelect: { model.selectConversation(conversation) },
                                onDelete: { conversationPendingDeletion = conversation },
                                onRename: { newTitle in
                                    model.renameConversation(conversation.id, to: newTitle)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
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

    private var groupedConversations: [(ChatSidebarBucket, [ChatConversation])] {
        var groups: [ChatSidebarBucket: [ChatConversation]] = [:]
        for conversation in model.conversations {
            let bucket = ChatSidebarBucket.bucket(for: conversation.updatedAt)
            groups[bucket, default: []].append(conversation)
        }
        return ChatSidebarBucket.allCases.compactMap { bucket in
            guard let conversations = groups[bucket], !conversations.isEmpty else {
                return nil
            }
            return (bucket, conversations)
        }
    }

    private func sidebarBucketHeader(_ bucket: ChatSidebarBucket) -> some View {
        HStack {
            Text(bucket.rawValue)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(ChatPalette.mutedText)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var toolbar: some View {
        HStack {
            HStack(spacing: 10) {
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

                Button {
                    isToolsPopoverPresented.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slash.circle.fill")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(ChatPalette.accent)
                        Text("Tools")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(ChatPalette.primaryText)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Capsule().fill(ChatPalette.panel).overlay(Capsule().stroke(ChatPalette.border, lineWidth: 1)))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isToolsPopoverPresented, arrowEdge: .bottom) {
                    SlashCommandPalette { command in
                        model.insertSlashCommand(command)
                        isToolsPopoverPresented = false
                    }
                    .frame(width: 420)
                }
                .help("Browse slash commands")

                Spacer()
            }
            .frame(width: 220)

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
            .frame(width: 220, alignment: .trailing)
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
                            switch message.kind {
                            case .userText, .assistantText:
                                ChatBubble(
                                    message: message,
                                    canRegenerate: message.role == .assistant && !model.isGenerating,
                                    onRegenerate: { model.regenerate(from: message) }
                                )
                                .id(message.id)
                            case .assistantError:
                                AssistantErrorBubble(
                                    message: message,
                                    canRetry: !model.isGenerating,
                                    onRetry: { model.regenerate(from: message) }
                                )
                                .id(message.id)
                            case .toolIntent:
                                if let intent = message.toolIntent {
                                    HStack {
                                        ToolIntentCardView(
                                            intent: intent,
                                            onConfirm: { model.confirmIntent(message) },
                                            onReject: { model.rejectIntent(message) },
                                            onEdit: { editedIntent in
                                                model.editIntent(message, with: editedIntent)
                                            }
                                        )
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal)
                                    .id(message.id)
                                }
                            case .toolResponse:
                                EmptyView()
                            }
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
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(ChatPalette.avatar)
                    .frame(width: 132, height: 132)
                Image(systemName: "person.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(ChatPalette.secondaryText)
            }
            VStack(spacing: 6) {
                Text(greeting)
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(ChatPalette.primaryText)
                Text("Pick a starter below or just message Gemma directly.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ChatPalette.secondaryText)
                    .multilineTextAlignment(.center)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(welcomeStarters, id: \.title) { starter in
                    WelcomeStarterChip(starter: starter) {
                        model.inputText = starter.prompt
                        NotificationCenter.default.post(name: .chatComposerFocusRequested, object: nil)
                    }
                }
            }
            .frame(maxWidth: 620)
            .padding(.top, 6)

            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private var welcomeStarters: [WelcomeStarter] {
        [
            WelcomeStarter(
                icon: "arrow.up.right.circle.fill",
                title: "Transfer",
                prompt: "Send 0.1 ETH to vitalik.eth"
            ),
            WelcomeStarter(
                icon: "arrow.triangle.swap",
                title: "Swap",
                prompt: "Swap 100 USDC for ETH"
            ),
            WelcomeStarter(
                icon: "slash.circle.fill",
                title: "Try a slash command",
                prompt: "/transfer 0.05 ETH to <recipient>"
            ),
            WelcomeStarter(
                icon: "lock.shield.fill",
                title: "How keys stay safe",
                prompt: "How does this wallet keep my private keys safe?"
            )
        ]
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
        VStack(spacing: 8) {
            if !model.slashSuggestions.isEmpty {
                SlashSuggestionPanel(commands: model.slashSuggestions) { command in
                    model.insertSlashCommand(command)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            composerInputBox
        }
        .animation(.easeOut(duration: 0.12), value: model.slashSuggestions)
    }

    private var composerInputBox: some View {
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
                    Text("Message Gemma — describe what you want, or type / for tools")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ChatPalette.mutedText)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Text("↩ to send · ⌘K to focus")
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
        context.coordinator.attach(textView: textView)
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        private weak var textView: NSTextView?

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleFocusRequest),
                name: .chatComposerFocusRequested,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(textView: NSTextView) {
            self.textView = textView
        }

        @objc private func handleFocusRequest() {
            textView?.window?.makeFirstResponder(textView)
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
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var editingTitle = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: { if !isRenaming { onSelect() } }) {
                rowContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { startRenaming() }
            )
            .contextMenu {
                Button {
                    startRenaming()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete chat", systemImage: "trash")
                }
            }

            if isHovered, !isRenaming {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(ChatPalette.secondaryText)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(ChatPalette.buttonCircle)
                                .overlay(Circle().stroke(ChatPalette.border, lineWidth: 0.8))
                        )
                }
                .buttonStyle(.plain)
                .help("Delete chat")
                .padding(6)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isRenaming {
                TextField("Conversation title", text: $editingTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ChatPalette.primaryText)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused && isRenaming {
                            commitRename()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(conversation.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ChatPalette.primaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                Text("\(conversation.messages.count) messages")
                Text("·")
                Text(conversation.updatedAt, style: .relative)
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(ChatPalette.mutedText)
        }
    }

    private func startRenaming() {
        editingTitle = conversation.title
        isRenaming = true
        DispatchQueue.main.async {
            renameFocused = true
        }
    }

    private func commitRename() {
        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        isRenaming = false
        guard !trimmed.isEmpty, trimmed != conversation.title else {
            return
        }
        onRename(trimmed)
    }

    private func cancelRename() {
        isRenaming = false
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
    var canRegenerate: Bool = false
    var onRegenerate: (() -> Void)? = nil
    @State private var isThinkingExpanded = false
    @State private var isHovered = false
    @State private var justCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 90)
            }
            ZStack(alignment: .topTrailing) {
                bubbleContent
                if isHovered {
                    hoverActions
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .contextMenu {
                Button {
                    copyPlainText()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if message.stats != nil, message.role == .assistant {
                    Button {
                        copyWithStats()
                    } label: {
                        Label("Copy with stats", systemImage: "doc.on.doc.fill")
                    }
                }
                if canRegenerate, let onRegenerate {
                    Divider()
                    Button {
                        onRegenerate()
                    } label: {
                        Label("Regenerate response", systemImage: "arrow.clockwise")
                    }
                }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            if message.role == .assistant {
                Spacer(minLength: 90)
            }
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 6) {
            if canRegenerate, let onRegenerate {
                bubbleActionButton(systemImage: "arrow.clockwise", help: "Regenerate response", action: onRegenerate)
            }
            copyButton
        }
    }

    private func bubbleActionButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(ChatPalette.secondaryText)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(ChatPalette.buttonCircle)
                        .overlay(Circle().stroke(ChatPalette.border, lineWidth: 0.8))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var bubbleContent: some View {
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
    }

    private var copyButton: some View {
        Button(action: copyPlainText) {
            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(justCopied ? ChatPalette.success : ChatPalette.secondaryText)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(ChatPalette.buttonCircle)
                        .overlay(Circle().stroke(ChatPalette.border, lineWidth: 0.8))
                )
        }
        .buttonStyle(.plain)
        .help(justCopied ? "Copied" : "Copy message")
    }

    private func copyPlainText() {
        ChatClipboard.copy(message.text ?? "")
        flashCopied()
    }

    private func copyWithStats() {
        var pieces: [String] = [message.text ?? ""]
        if let stats = message.stats {
            pieces.append("")
            pieces.append("— \(stats.formattedSummary)")
        }
        ChatClipboard.copy(pieces.joined(separator: "\n"))
        flashCopied()
    }

    private func flashCopied() {
        withAnimation(.easeInOut(duration: 0.12)) {
            justCopied = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                justCopied = false
            }
        }
    }
}

private struct WelcomeStarter: Equatable {
    let icon: String
    let title: String
    let prompt: String
}

private struct WelcomeStarterChip: View {
    let starter: WelcomeStarter
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: starter.icon)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(ChatPalette.accent)
                    Text(starter.title)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(ChatPalette.mutedText)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
                Text(starter.prompt)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ChatPalette.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovered ? ChatPalette.selectedPanel.opacity(0.8) : ChatPalette.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isHovered ? ChatPalette.accent.opacity(0.6) : ChatPalette.border, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct SlashSuggestionPanel: View {
    let commands: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button {
                    onSelect(command)
                } label: {
                    HStack(spacing: 10) {
                        Text(command.displayName)
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                            .foregroundStyle(ChatPalette.accent)
                            .frame(width: 84, alignment: .leading)
                        Text(command.summary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ChatPalette.secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(command.signature)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(ChatPalette.mutedText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SlashSuggestionRowStyle())
                if index < commands.count - 1 {
                    Rectangle()
                        .fill(ChatPalette.border.opacity(0.5))
                        .frame(height: 0.5)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ChatPalette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(ChatPalette.border, lineWidth: 1)
                )
        )
    }
}

private struct SlashSuggestionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? ChatPalette.selectedPanel.opacity(0.8)
                    : Color.clear
            )
    }
}

private struct SlashCommandPalette: View {
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "slash.circle.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(ChatPalette.accent)
                Text("Slash commands")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(ChatPalette.primaryText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Text("Click a command to insert a ready-to-edit scaffold into the composer. Replace the placeholders (in <angle brackets>) with your values.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChatPalette.mutedText)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            Rectangle()
                .fill(ChatPalette.border.opacity(0.4))
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(SlashCatalog.all.enumerated()), id: \.element.id) { index, command in
                    Button {
                        onSelect(command)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(command.displayName)
                                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(ChatPalette.accent)
                                Text(command.signature)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(ChatPalette.mutedText)
                                Spacer(minLength: 0)
                            }
                            Text(command.summary)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(ChatPalette.secondaryText)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SlashSuggestionRowStyle())

                    if index < SlashCatalog.all.count - 1 {
                        Rectangle()
                            .fill(ChatPalette.border.opacity(0.4))
                            .frame(height: 0.5)
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }
}

private enum ChatClipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private struct MarkdownMessageText: View {
    let markdown: String
    let fontSize: CGFloat
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatMarkdownParser.segments(in: markdown).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let text):
                    Text(attributed(text))
                        .font(.system(size: fontSize, weight: .medium))
                        .foregroundStyle(color)
                        .textSelection(.enabled)
                case .codeBlock(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }

    private func attributed(_ text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            return AttributedString(text)
        }
    }
}

private enum ChatMarkdownSegment: Equatable {
    case prose(String)
    case codeBlock(language: String?, code: String)
}

private enum ChatMarkdownParser {
    static func segments(in markdown: String) -> [ChatMarkdownSegment] {
        var segments: [ChatMarkdownSegment] = []
        var prose: [String] = []
        var iterator = markdown.components(separatedBy: "\n").makeIterator()
        while let line = iterator.next() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !prose.isEmpty {
                    segments.append(.prose(prose.joined(separator: "\n")))
                    prose.removeAll()
                }
                let fence = line.trimmingCharacters(in: .whitespaces)
                let language = String(fence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                var closed = false
                while let codeLine = iterator.next() {
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        closed = true
                        break
                    }
                    codeLines.append(codeLine)
                }
                let code = codeLines.joined(separator: "\n")
                if closed || !code.isEmpty {
                    segments.append(.codeBlock(language: language.isEmpty ? nil : language, code: code))
                }
            } else {
                prose.append(line)
            }
        }
        if !prose.isEmpty {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                segments.append(.prose(joined))
            }
        }
        return segments
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(ChatPalette.mutedText)
                    .tracking(0.6)
                Spacer()
                Button {
                    ChatClipboard.copy(code)
                    flashCopied()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .black))
                        Text(justCopied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .heavy))
                    }
                    .foregroundStyle(justCopied ? ChatPalette.success : ChatPalette.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(ChatPalette.background.opacity(0.5))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(ChatPalette.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .textSelection(.enabled)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ChatPalette.input)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(ChatPalette.border, lineWidth: 0.8)
                )
        )
    }

    private func flashCopied() {
        withAnimation(.easeInOut(duration: 0.12)) {
            justCopied = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                justCopied = false
            }
        }
    }
}

private extension ChatGenerationStats {
    var formattedSummary: String {
        let seconds = duration.formatted(.number.precision(.fractionLength(1)))
        return "\(seconds)s · \(generatedTokens) generated tokens · context \(usedContextTokens)/\(contextSize) · \(contextTokensLeft) left"
    }
}

private struct AssistantErrorBubble: View {
    let message: ChatMessage
    let canRetry: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color.orange)
                    Text("Generation failed")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(ChatPalette.primaryText)
                }
                Text(message.text ?? "Unknown error")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ChatPalette.secondaryText)
                    .textSelection(.enabled)
                if canRetry {
                    Button(action: onRetry) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .black))
                            Text("Retry")
                                .font(.system(size: 12, weight: .heavy))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(ChatPalette.accent.opacity(0.9)))
                    }
                    .buttonStyle(.plain)
                    .help("Re-run the last prompt")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.orange.opacity(0.45), lineWidth: 1)
                    )
            )
            Spacer(minLength: 90)
        }
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
