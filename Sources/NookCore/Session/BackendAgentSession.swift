import Foundation

/// Agent session that delegates orchestration to the backend.
///
/// Unlike `AgentSession` which runs the agent loop locally, this session:
/// - Sends messages to the backend for reasoning
/// - Receives tool requests from the backend
/// - Executes tools locally
/// - Streams responses to the UI
///
/// Falls back to local processing (via OfflineSession) when backend is unreachable.
@MainActor
public final class BackendAgentSession: ObservableObject, ChatSessionProtocol {
    public static let maxMessagesInMemory = 80

    @Published public var conversation: Conversation
    @Published public var messages: [Message] = []
    @Published public var isStreaming: Bool = false
    @Published public var isThinking: Bool = false
    @Published public var pendingToolConfirmation: ToolConfirmationRequest? = nil
    @Published public var toastMessage: String? = nil
    @Published public var offlineStatus: OfflineStatus = .online

    /// Compatibility with AgentSession - maps tool confirmation to approval payload
    public var pendingApproval: OutgoingApprovalPayload? {
        guard let confirmation = pendingToolConfirmation else { return nil }
        return OutgoingApprovalPayload(
            serverName: "Nook",
            serverUrl: "local",
            toolName: confirmation.toolName,
            formattedPayload: confirmation.message
        )
    }

    public let toolRegistry: ToolRegistry
    public let contextAssembler: ContextAssembler
    public let knowledgeEngine: KnowledgeEngine
    public let skillManager: SkillManager
    public let mcpClient: MCPClient
    public let mcpToolRegistrar: MCPToolRegistrar

    private let apiClient: NookAPIClient
    private let toolHandler: ToolRequestHandler
    private let offlineSession: OfflineSession
    private let chatStore: ChatStore

    private var activeTask: Task<Void, Never>?
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    private var currentTurnState: ClientTurnState?

    public init(
        conversation: Conversation,
        messages: [Message] = [],
        apiClient: NookAPIClient,
        toolRegistry: ToolRegistry,
        chatStore: ChatStore = .shared,
        knowledgeEngine: KnowledgeEngine,
        skillManager: SkillManager,
        mcpClient: MCPClient,
        mcpToolRegistrar: MCPToolRegistrar,
        contextAssembler: ContextAssembler = ContextAssembler()
    ) {
        self.conversation = conversation
        self.messages = messages
        self.apiClient = apiClient
        self.toolRegistry = toolRegistry
        self.chatStore = chatStore
        self.knowledgeEngine = knowledgeEngine
        self.skillManager = skillManager
        self.mcpClient = mcpClient
        self.mcpToolRegistrar = mcpToolRegistrar
        self.contextAssembler = contextAssembler
        self.toolHandler = ToolRequestHandler(toolRegistry: toolRegistry)
        self.offlineSession = OfflineSession(
            toolRegistry: toolRegistry,
            contextAssembler: contextAssembler
        )
    }

    // MARK: - Public API

    /// Send a message and stream the response.
    /// Conforms to ChatSessionProtocol. The `runtime` is only used for offline fallback.
    public func sendMessage(
        text: String,
        attachedImageName: String? = nil,
        wasDictated: Bool = false,
        runtime: any Sendable,
        streamHandler: @escaping AgentSession.AgentStreamHandler
    ) async {
        activeTask?.cancel()

        // Create and persist user message
        let userMsg = Message(
            conversationId: conversation.id,
            role: .user,
            content: text,
            attachedImageName: attachedImageName,
            wasDictated: wasDictated
        )
        messages.append(userMsg)
        trimDisplayedMessages()
        persist(message: userMsg, userTextForMetadata: text)

        isThinking = true
        isStreaming = false

        // Check if we should use offline mode
        if await offlineSession.shouldUseOfflineMode(apiClient: apiClient) {
            offlineStatus = OfflineStatus(
                isOffline: true,
                reason: .backendUnreachable,
                canRetryOnline: true
            )

            await runOffline(message: text, streamHandler: streamHandler)
            return
        }

        offlineStatus = .online
        await runOnline(message: text)
    }

    /// Cancel the current generation.
    public func cancelGeneration() {
        activeTask?.cancel()
        activeTask = nil
        confirmationContinuation?.resume(returning: false)
        confirmationContinuation = nil
        pendingToolConfirmation = nil
        isThinking = false
        isStreaming = false
    }

    /// Respond to a tool confirmation request.
    public func resolveToolConfirmation(confirmed: Bool) {
        pendingToolConfirmation = nil
        confirmationContinuation?.resume(returning: confirmed)
        confirmationContinuation = nil
        if confirmed {
            isThinking = true
        }
    }

    /// Compatibility with AgentSession approval API.
    public func resolveApproval(action: ApprovalAction) {
        switch action {
        case .sendOnce, .alwaysAllow:
            resolveToolConfirmation(confirmed: true)
        case .dont:
            resolveToolConfirmation(confirmed: false)
        }
    }

    /// Set the active skill for this conversation.
    public func setActiveSkill(_ skill: Skill?) {
        conversation.activeSkillId = skill?.id
        persistConversationMetadata()
    }

    public func persistConversationMetadata() {
        do {
            try chatStore.saveConversation(conversation)
        } catch {
            print("[BackendAgentSession] Failed to persist conversation: \(error)")
        }
    }

    /// Retry with online mode after being offline.
    public func retryOnline() async {
        guard let lastUserMessage = messages.last(where: { $0.role == .user }) else { return }
        // Remove the last assistant message if it was an offline response
        if let lastAssistant = messages.last, lastAssistant.role == .assistant {
            messages.removeLast()
        }
        // Directly run online without needing streamHandler (backend does its own streaming)
        isThinking = true
        isStreaming = false
        offlineStatus = .online
        await runOnline(message: lastUserMessage.content)
    }

    // MARK: - Online Flow

    private func runOnline(message: String) async {
        // Initialize turn state
        currentTurnState = ClientTurnState()

        // Create assistant message placeholder
        let assistantMsg = Message(
            conversationId: conversation.id,
            role: .assistant,
            content: ""
        )
        let assistantMsgId = assistantMsg.id
        messages.append(assistantMsg)
        isStreaming = true

        let task = Task {
            do {
                try await runAgentLoop(
                    message: message,
                    assistantMsgId: assistantMsgId
                )
            } catch is CancellationError {
                await handleCancellation(assistantMsgId: assistantMsgId)
            } catch {
                await handleError(error, assistantMsgId: assistantMsgId)
            }
        }

        activeTask = task
        await task.value
    }

    private func runAgentLoop(
        message: String,
        assistantMsgId: String
    ) async throws {
        var currentMessage = message

        while true {
            // Build request with full state
            let request = await buildChatRequest(message: currentMessage)

            // Stream from backend
            for try await event in apiClient.chat(request: request) {
                if Task.isCancelled { throw CancellationError() }

                switch event {
                case .token(let token):
                    appendToken(token, to: assistantMsgId)

                case .toolRequest(let toolReq):
                    await handleToolRequest(toolReq)

                case .awaitingTools(let turnState):
                    // Backend is waiting for tool results
                    // Update our turn state and continue the loop
                    currentTurnState?.incrementIteration()
                    currentMessage = "" // Not a new message
                    // The loop will continue with updated turn state

                case .done:
                    // Turn complete
                    await finishTurn(assistantMsgId: assistantMsgId)
                    return

                case .error(let errorMessage):
                    throw NookAPIError.serverError(statusCode: 0, message: errorMessage)
                }
            }
        }
    }

    private func handleToolRequest(_ request: ToolRequestPayload) async {
        // Show tool chip before execution
        let toolChip = Message(
            conversationId: conversation.id,
            role: .localTool,
            content: "",
            localToolText: "\(request.toolName) · running"
        )
        messages.append(toolChip)

        // Execute tool
        let result = await toolHandler.handle(
            request: request,
            onConfirmationNeeded: { [weak self] req in
                await self?.requestToolConfirmation(req) ?? false
            }
        )

        // Update tool chip with result
        if let chipIndex = messages.lastIndex(where: { $0.localToolText?.contains(request.toolName) == true }) {
            messages[chipIndex].localToolText = result.displayText
            persist(message: messages[chipIndex])
        }

        // Add to turn state
        let turnStateEntry = toolHandler.resultToTurnStateEntry(result, toolName: request.toolName)
        currentTurnState?.addCompletedResult(turnStateEntry.toDictionary())
        currentTurnState?.markExecuted(toolId: request.requestId)

        // Submit result to backend
        do {
            try await apiClient.submitToolResult(
                conversationId: conversation.id,
                result: result
            )
        } catch {
            print("[BackendAgentSession] Failed to submit tool result: \(error)")
        }
    }

    private func requestToolConfirmation(_ request: ToolRequestPayload) async -> Bool {
        pendingToolConfirmation = ToolConfirmationRequest(
            toolName: request.toolName,
            message: request.confirmationMessage ?? "Confirm \(request.toolName)?",
            arguments: request.arguments
        )
        isThinking = false

        return await withCheckedContinuation { continuation in
            self.confirmationContinuation = continuation
        }
    }

    // MARK: - Offline Flow

    private func runOffline(
        message: String,
        streamHandler: @escaping AgentSession.AgentStreamHandler
    ) async {
        let assistantMsg = Message(
            conversationId: conversation.id,
            role: .assistant,
            content: ""
        )
        let assistantMsgId = assistantMsg.id
        messages.append(assistantMsg)
        isStreaming = true

        do {
            let filteredMessages = messages.filter { $0.id != assistantMsgId }
            let output = try await offlineSession.processMessage(
                message: message,
                conversation: conversation,
                messages: filteredMessages,
                generateStep: { [weak self] context, request in
                    guard let self else { throw CancellationError() }
                    var result: AgentGenerationResult?
                    result = try await streamHandler(
                        context,
                        request,
                        { _, _ in ToolExecutionResult(textForModel: "", displayText: "") },
                        { token in
                            Task { @MainActor [weak self] in
                                self?.appendToken(token, to: assistantMsgId)
                            }
                        },
                        { _ in }
                    )
                    return result!
                },
                onToolEvent: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleLocalToolEvent(event, beforeId: assistantMsgId)
                    }
                }
            )

            // Update final message
            if let index = messages.firstIndex(where: { $0.id == assistantMsgId }) {
                messages[index].content = output.text
                messages[index].citations = output.citations
                persist(message: messages[index])
            }
        } catch {
            if let index = messages.firstIndex(where: { $0.id == assistantMsgId }) {
                messages[index].content = "Offline processing failed: \(error.localizedDescription)"
                persist(message: messages[index])
            }
        }

        isThinking = false
        isStreaming = false
    }

    private func handleLocalToolEvent(_ event: AgentToolEvent, beforeId: String) {
        let insertIndex = messages.firstIndex(where: { $0.id == beforeId }) ?? messages.endIndex
        let toolMsg = Message(
            conversationId: conversation.id,
            role: .localTool,
            content: "",
            localToolText: event.displayText
        )
        messages.insert(toolMsg, at: insertIndex)
        persist(message: toolMsg)
    }

    // MARK: - Helpers

    private func buildChatRequest(message: String) async -> ChatRequestPayload {
        // Build conversation history
        let history = messages
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(20) // Keep recent history
            .map { msg -> [String: Any] in
                [
                    "role": msg.role == .user ? "user" : "assistant",
                    "content": msg.content,
                ]
            }

        // Get tool schemas from registry (OpenAI-compatible format)
        let toolSpecs = await toolRegistry.schemas()
        let tools: [[String: Any]] = toolSpecs.map { spec in
            // Convert [String: any Sendable] to [String: Any]
            var dict: [String: Any] = [:]
            for (key, value) in spec {
                dict[key] = value
            }
            return dict
        }

        return ChatRequestPayload(
            conversationId: conversation.id,
            message: message,
            conversationHistory: history,
            availableTools: tools,
            turnState: currentTurnState?.toPayload(),
            maxIterations: 10,
            maxDurationSeconds: 120
        )
    }

    private func appendToken(_ token: String, to messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        isThinking = false
        messages[index].content += token
    }

    private func finishTurn(assistantMsgId: String) async {
        if let index = messages.firstIndex(where: { $0.id == assistantMsgId }) {
            let content = messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty {
                messages[index].content = "I couldn't generate a response. Please try again."
            }
            persist(message: messages[index])
        }

        currentTurnState = nil
        isThinking = false
        isStreaming = false
        activeTask = nil
    }

    private func handleCancellation(assistantMsgId: String) async {
        if let index = messages.firstIndex(where: { $0.id == assistantMsgId }),
           messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages[index].content = "Cancelled."
            persist(message: messages[index])
        }
        isThinking = false
        isStreaming = false
        activeTask = nil
    }

    private func handleError(_ error: Error, assistantMsgId: String) async {
        // Show user-friendly message, not raw API errors
        let userMessage = userFriendlyErrorMessage(for: error)

        if let index = messages.firstIndex(where: { $0.id == assistantMsgId }),
           messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages[index].content = userMessage
            persist(message: messages[index])
        }

        showToast(userMessage)
        isThinking = false
        
        // Log the actual error for debugging
        print("[BackendAgentSession] Error: \(error)")
    }
    
    private func userFriendlyErrorMessage(for error: Error) -> String {
        // Check for specific error types
        if let apiError = error as? NookAPIError {
            switch apiError {
            case .rateLimitExceeded:
                return "You've sent too many messages. Please wait a moment and try again."
            case .unauthorized:
                return "Your session has expired. Please sign in again."
            case .serverError:
                return "Something went wrong on our end. Please try again."
            case .networkError:
                return "Unable to connect. Please check your internet connection."
            default:
                return "Something went wrong. Please try again."
            }
        }
        
        // Generic fallback
        return "Something went wrong. Please try again."
        isStreaming = false
        activeTask = nil
    }

    // MARK: - Persistence

    public func trimDisplayedMessages(keepingLast count: Int = maxMessagesInMemory) {
        guard messages.count > count else { return }
        messages.removeFirst(messages.count - count)
    }

    public func showToast(_ text: String) {
        toastMessage = text
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toastMessage == text {
                toastMessage = nil
            }
        }
    }

    private func persist(message: Message, userTextForMetadata: String? = nil) {
        do {
            if let userText = userTextForMetadata {
                let title = conversation.title == "New chat"
                    ? ChatStore.snippet(from: userText, maxLength: 48)
                    : conversation.title
                conversation.title = title
                conversation.snippet = ChatStore.snippet(from: userText)
                conversation.updatedAt = Date()
                conversation.whenString = ChatStore.formatWhenString(conversation.updatedAt)
            } else if message.role == .assistant {
                conversation.snippet = ChatStore.snippet(from: message.content)
                conversation.updatedAt = Date()
                conversation.whenString = ChatStore.formatWhenString(conversation.updatedAt)
            }

            try chatStore.saveConversation(conversation)
            try chatStore.saveMessage(message)
        } catch {
            print("[BackendAgentSession] Persist failed: \(error)")
        }
    }
}

// MARK: - Supporting Types

/// Request for user to confirm a tool action.
public struct ToolConfirmationRequest: Sendable, Equatable {
    public let toolName: String
    public let message: String
    public let arguments: [String: ToolJSONValue]

    public init(toolName: String, message: String, arguments: [String: ToolJSONValue]) {
        self.toolName = toolName
        self.message = message
        self.arguments = arguments
    }
}
