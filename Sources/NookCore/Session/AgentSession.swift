import Foundation

@MainActor
public final class AgentSession: ObservableObject {
    public static let maxMessagesInMemory = 80

    public typealias AgentStreamHandler = @Sendable (
        _ promptContext: AssembledPromptContext,
        _ request: AgentGenerationRequest,
        _ toolExecutor: @escaping @Sendable (String, ToolArguments) async throws -> ToolExecutionResult,
        _ onToken: @escaping @Sendable (String) -> Void,
        _ onToolEvent: @escaping @Sendable (AgentToolEvent) -> Void
    ) async throws -> AgentGenerationResult

    @Published public var conversation: Conversation
    @Published public var messages: [Message] = []
    @Published public var isStreaming: Bool = false
    @Published public var isThinking: Bool = false
    @Published public var pendingApproval: OutgoingApprovalPayload? = nil
    @Published public var toastMessage: String? = nil

    public let knowledgeEngine: KnowledgeEngine
    public let memoryEngine: MemoryEngine
    public let skillManager: SkillManager
    public let toolRegistry: ToolRegistry
    public let mcpClient: MCPClient
    public let contextAssembler: ContextAssembler

    private var pendingStreamHandler: AgentStreamHandler?
    private var activeGenerationTask: Task<Void, Never>?
    private let chatStore: ChatStore

    public init(
        conversation: Conversation,
        messages: [Message] = [],
        chatStore: ChatStore = .shared,
        knowledgeEngine: KnowledgeEngine,
        memoryEngine: MemoryEngine,
        skillManager: SkillManager,
        toolRegistry: ToolRegistry,
        mcpClient: MCPClient,
        contextAssembler: ContextAssembler = ContextAssembler()
    ) {
        self.conversation = conversation
        self.messages = messages
        self.chatStore = chatStore
        self.knowledgeEngine = knowledgeEngine
        self.memoryEngine = memoryEngine
        self.skillManager = skillManager
        self.toolRegistry = toolRegistry
        self.mcpClient = mcpClient
        self.contextAssembler = contextAssembler
    }

    /// Drops older in-memory messages to reduce RAM use in long chats. History remains in SQLite.
    public func trimDisplayedMessages(keepingLast count: Int = maxMessagesInMemory) {
        guard messages.count > count else { return }
        messages.removeFirst(messages.count - count)
    }

    public func showToast(_ text: String) {
        self.toastMessage = text
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.toastMessage == text {
                self.toastMessage = nil
            }
        }
    }

    public func cancelGeneration() {
        activeGenerationTask?.cancel()
        activeGenerationTask = nil
        isThinking = false
        isStreaming = false
    }

    public func sendMessage(
        text: String,
        attachedImageName: String? = nil,
        runtime: any Sendable,
        streamHandler: @escaping AgentStreamHandler
    ) async {
        activeGenerationTask?.cancel()

        let userMsg = Message(
            conversationId: conversation.id,
            role: .user,
            content: text,
            attachedImageName: attachedImageName
        )
        messages.append(userMsg)
        trimDisplayedMessages()
        persist(message: userMsg, userTextForMetadata: text)

        let lower = text.lowercased()
        let knowledgeScope = conversation.activeKnowledgeScope
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        await toolRegistry.setDocumentsSearchScope(knowledgeScope)

        // Temporary MCP path until external tools are registered in ToolRegistry.
        if lower.contains("github") || lower.contains("issue") {
            let isAlwaysAllowed = await toolRegistry.isAlwaysAllowed(toolName: "github.search_issues")

            if !isAlwaysAllowed {
                let payload = await mcpClient.buildApprovalPayload(toolName: "github.search_issues", parameters: [:])
                self.pendingApproval = payload
                self.pendingStreamHandler = streamHandler
                return
            } else {
                await executeApprovedMCP(streamHandler: streamHandler)
                return
            }
        }

        // Knowledge policy:
        // - Scoped → app always runs documents_search (deterministic; not left to the model).
        // - Unscoped → normal chat; prompt may ask user to scope or try Balanced.
        if knowledgeScope.isEmpty {
            print("[AgentSession] No Knowledge scope — chat without documents_search")
            await performAssistantStream(
                request: .textOnly,
                systemPrompt: NookSystemPrompt.standard,
                streamHandler: streamHandler
            )
            return
        }

        let registered = await toolRegistry.allToolNames()
        guard registered.contains(DocumentsSearchTool.toolName) else {
            await performAssistantStream(
                request: .textOnly,
                systemPrompt: NookSystemPrompt.standard,
                streamHandler: streamHandler
            )
            return
        }

        do {
            let searchResult = try await toolRegistry.execute(
                toolName: DocumentsSearchTool.toolName,
                arguments: ["query": .string(text)]
            )
            let toolChip = Message(
                conversationId: conversation.id,
                role: .localTool,
                content: "",
                localToolText: searchResult.displayText
            )
            messages.append(toolChip)
            persist(message: toolChip)
            print("[AgentSession] Scoped search \(DocumentsSearchTool.toolName) · \(searchResult.displayText)")

            let evidenceNote: String
            if searchResult.chunks.isEmpty {
                evidenceNote = searchResult.textForModel
            } else {
                evidenceNote =
                    "documents_search returned \(searchResult.chunks.count) passage(s). " +
                    "Use only the retrieved knowledge passages below."
            }

            await performAssistantStream(
                request: .textOnly,
                evidenceChunks: searchResult.chunks,
                toolResults: [evidenceNote],
                forcedCitations: searchResult.citations,
                systemPrompt: NookSystemPrompt.withRetrievedKnowledge,
                streamHandler: streamHandler
            )
        } catch {
            print("[AgentSession] documents_search failed: \(error)")
            showToast("Couldn’t search Knowledge. Try again.")
            let reply = Message(
                conversationId: conversation.id,
                role: .assistant,
                content: "I couldn’t search your Knowledge collections. Try again in a moment."
            )
            messages.append(reply)
            persist(message: reply)
        }
    }

    public func resolveApproval(action: ApprovalAction) {
        guard let payload = pendingApproval else { return }
        self.pendingApproval = nil
        guard let streamHandler = self.pendingStreamHandler else { return }
        self.pendingStreamHandler = nil

        Task { @MainActor in
            switch action {
            case .sendOnce:
                await self.executeApprovedMCP(streamHandler: streamHandler)
            case .alwaysAllow:
                await self.toolRegistry.setAlwaysAllow(toolName: payload.toolName, allowed: true)
                self.showToast("\(payload.toolName) is now always allowed.")
                await self.executeApprovedMCP(streamHandler: streamHandler)
            case .dont:
                break
            }
        }
    }

    private func executeApprovedMCP(streamHandler: @escaping AgentStreamHandler) async {
        let toolMsg = Message(
            conversationId: self.conversation.id,
            role: .externalTool,
            content: "",
            externalToolData: ExternalToolExecution(
                toolName: "github.search_issues",
                lines: [
                    "#418 Identity provider fallback — open, unassigned",
                    "#402 Analytics scope — open, needs-estimate",
                ],
                footer: "mcp.github-bridge.dev · 0.9s"
            )
        )
        self.messages.append(toolMsg)
        persist(message: toolMsg)

        await self.performAssistantStream(
            request: AgentGenerationRequest.textOnly,
            toolResults: ["github.search_issues returned #418 (Identity provider fallback) and #402 (Analytics scope)"],
            streamHandler: streamHandler
        )
    }

    private func performAssistantStream(
        request: AgentGenerationRequest,
        evidenceChunks: [DocumentChunk] = [],
        toolResults: [String] = [],
        forcedCitations: [Citation] = [],
        systemPrompt: String = NookSystemPrompt.standard,
        streamHandler: @escaping AgentStreamHandler
    ) async {
        self.isThinking = true
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled {
            self.isThinking = false
            return
        }
        self.isThinking = false

        let assistantMsg = Message(
            conversationId: conversation.id,
            role: .assistant,
            content: "",
            citations: forcedCitations
        )
        let assistantMsgId = assistantMsg.id
        messages.append(assistantMsg)

        self.isStreaming = true

        let promptContext = contextAssembler.assemble(
            baseSystemPrompt: systemPrompt,
            activeSkill: nil,
            evidenceChunks: evidenceChunks,
            chatHistory: messages.filter { $0.id != assistantMsgId },
            toolResults: toolResults
        )

        let registry = toolRegistry
        let toolExecutor: @Sendable (String, ToolArguments) async throws -> ToolExecutionResult = { name, arguments in
            try await registry.execute(toolName: name, arguments: arguments)
        }

        let task = Task {
            do {
                let result = try await streamHandler(
                    promptContext,
                    request,
                    toolExecutor,
                    { token in
                        guard !Task.isCancelled else { return }
                        Task { @MainActor in
                            if let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                                self.messages[index].content += token
                            }
                        }
                    },
                    { event in
                        Task { @MainActor in
                            self.handleToolEvent(event, beforeAssistantId: assistantMsgId)
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    if let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                        if !result.citations.isEmpty {
                            self.messages[index].citations = result.citations
                        }
                        NookTextDebug.log(
                            "AgentSession final assistant",
                            text: self.messages[index].content
                        )
                        self.persist(message: self.messages[index])
                    }
                    self.trimDisplayedMessages()
                    self.isStreaming = false
                    self.activeGenerationTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    if let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }),
                       self.messages[index].content.isEmpty {
                        self.showToast("Generation was interrupted. Try sending again.")
                    }
                    if let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                        self.persist(message: self.messages[index])
                    }
                    self.isStreaming = false
                    self.activeGenerationTask = nil
                }
            } catch {
                await MainActor.run {
                    if let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }),
                       self.messages[index].content.isEmpty {
                        self.messages[index].content = "An error occurred during local generation."
                    }
                    if let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                        self.persist(message: self.messages[index])
                    }
                    self.isStreaming = false
                    self.activeGenerationTask = nil
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? "Something went wrong while generating on device."
                    self.showToast(message)
                    print("[AgentSession] Generation failed: \(error)")
                }
            }
        }

        activeGenerationTask = task
        await task.value
    }

    private func handleToolEvent(_ event: AgentToolEvent, beforeAssistantId: String) {
        let insertIndex = messages.firstIndex(where: { $0.id == beforeAssistantId }) ?? messages.endIndex

        if event.isExternal {
            let toolMsg = Message(
                conversationId: conversation.id,
                role: .externalTool,
                content: "",
                externalToolData: ExternalToolExecution(
                    toolName: event.toolName,
                    lines: event.displayText.components(separatedBy: "\n"),
                    footer: "on device"
                )
            )
            messages.insert(toolMsg, at: insertIndex)
            persist(message: toolMsg)
        } else {
            let localPill = Message(
                conversationId: conversation.id,
                role: .localTool,
                content: "",
                localToolText: event.displayText
            )
            messages.insert(localPill, at: insertIndex)
            persist(message: localPill)
        }

        if !event.citations.isEmpty,
           let index = messages.firstIndex(where: { $0.id == beforeAssistantId }) {
            messages[index].citations = event.citations
        }
    }

    public func persistConversationMetadata() {
        conversation.updatedAt = Date()
        conversation.whenString = ChatStore.formatWhenString(conversation.updatedAt)
        do {
            try chatStore.saveConversation(conversation)
        } catch {
            print("[AgentSession] Failed to save conversation: \(error)")
        }
    }

    private func persist(message: Message, userTextForMetadata: String? = nil) {
        do {
            try chatStore.saveMessage(message)

            if let userTextForMetadata {
                let title = conversation.title == "New chat"
                    ? ChatStore.snippet(from: userTextForMetadata, maxLength: 48)
                    : conversation.title
                let snippet = ChatStore.snippet(from: userTextForMetadata)
                try chatStore.touchConversation(
                    id: conversation.id,
                    title: title,
                    snippet: snippet,
                    knowledgeScope: conversation.activeKnowledgeScope,
                    tags: conversation.tags
                )
                conversation.title = title
                conversation.snippet = snippet
                conversation.updatedAt = Date()
                conversation.whenString = ChatStore.formatWhenString(conversation.updatedAt)
            } else if message.role == .assistant {
                let snippet = ChatStore.snippet(from: message.content)
                try chatStore.touchConversation(id: conversation.id, snippet: snippet)
                conversation.snippet = snippet
                conversation.updatedAt = Date()
                conversation.whenString = ChatStore.formatWhenString(conversation.updatedAt)
            }
        } catch {
            print("[AgentSession] Failed to persist message: \(error)")
        }
    }
}

public enum ApprovalAction: Sendable {
    case sendOnce
    case alwaysAllow
    case dont
}
