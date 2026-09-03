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

    /// On-device generation used only for memory card extraction (text in → text out).
    public typealias MemoryExtractHandler = @Sendable (
        _ systemPrompt: String,
        _ userPrompt: String
    ) async throws -> String

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
    public let mcpToolRegistrar: MCPToolRegistrar
    public let contextAssembler: ContextAssembler

    private var activeGenerationTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var approvalContinuationToolName: String?
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
        mcpToolRegistrar: MCPToolRegistrar? = nil,
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
        self.mcpToolRegistrar = mcpToolRegistrar
            ?? MCPToolRegistrar(client: mcpClient, registry: toolRegistry)
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
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
        pendingApproval = nil
        isThinking = false
        isStreaming = false
    }

    public func sendMessage(
        text: String,
        attachedImageName: String? = nil,
        runtime: any Sendable,
        streamHandler: @escaping AgentStreamHandler,
        memoryExtractHandler: MemoryExtractHandler? = nil
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

        isThinking = true
        isStreaming = false

        let memoryHits = await memoryEngine.memoriesForChat(query: text)
        let memoryEvidence = MemoryEngine.evidenceStrings(from: memoryHits)

        let knowledgeScope = conversation.activeKnowledgeScope
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        await toolRegistry.setDocumentsSearchScope(knowledgeScope)
        await mcpToolRegistrar.sync()

        if knowledgeScope.isEmpty {
            #if DEBUG
            print("[AgentSession] No Knowledge scope — chat without documents_search")
            #endif
            await performAssistantStream(
                request: await externalToolsRequest(),
                memoryEvidence: memoryEvidence,
                systemPrompt: NookSystemPrompt.standard,
                streamHandler: streamHandler,
                userMessageForMemory: userMsg,
                memoryExtractHandler: memoryExtractHandler
            )
            return
        }

        let registered = await toolRegistry.allToolNames()
        guard registered.contains(DocumentsSearchTool.toolName) else {
            await performAssistantStream(
                request: await externalToolsRequest(),
                memoryEvidence: memoryEvidence,
                systemPrompt: NookSystemPrompt.standard,
                streamHandler: streamHandler,
                userMessageForMemory: userMsg,
                memoryExtractHandler: memoryExtractHandler
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

            let evidenceNote: String
            if searchResult.chunks.isEmpty {
                evidenceNote = searchResult.textForModel
            } else {
                evidenceNote =
                    "documents_search returned \(searchResult.chunks.count) passage(s). " +
                    "If they answer the user's question about their documents, use only those passages. " +
                    "If the question is general knowledge and the passages are unrelated, answer normally " +
                    "and do not claim the answer came from Knowledge."
            }

            await performAssistantStream(
                request: await externalToolsRequest(),
                evidenceChunks: searchResult.chunks,
                toolResults: [evidenceNote],
                forcedCitations: searchResult.citations,
                memoryEvidence: memoryEvidence,
                systemPrompt: NookSystemPrompt.withRetrievedKnowledge,
                streamHandler: streamHandler,
                userMessageForMemory: userMsg,
                memoryExtractHandler: memoryExtractHandler
            )
        } catch {
            print("[AgentSession] documents_search failed: \(error)")
            isThinking = false
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
        guard pendingApproval != nil else { return }
        pendingApproval = nil
        let toolName = approvalContinuationToolName
        approvalContinuationToolName = nil

        let allowed: Bool
        switch action {
        case .sendOnce:
            allowed = true
        case .alwaysAllow:
            if let toolName {
                Task { await toolRegistry.setAlwaysAllow(toolName: toolName, allowed: true) }
                showToast("\(toolName) is now always allowed.")
            }
            allowed = true
        case .dont:
            allowed = false
        }

        approvalContinuation?.resume(returning: allowed)
        approvalContinuation = nil
        if allowed {
            isThinking = true
        }
    }

    private func externalToolsRequest() async -> AgentGenerationRequest {
        let names = await toolRegistry.allToolNames()
        var allowed = Set<String>()
        for name in names {
            guard let tool = await toolRegistry.getTool(named: name), tool.isExternal else { continue }
            allowed.insert(name)
        }
        guard !allowed.isEmpty else { return .textOnly }
        let schemas = await toolRegistry.schemas(forAllowedNames: allowed)
        return AgentGenerationRequest(toolSchemas: schemas, maxToolRounds: 2)
    }

    private func requestExternalToolApproval(toolName: String, arguments: ToolArguments) async -> Bool {
        let bindings = await mcpClient.enabledToolBindings()
        let match = bindings.first {
            MCPToolRegistrar.registryName(server: $0.server, tool: $0.tool) == toolName
                || $0.tool.name == toolName
        }
        guard let match else {
            // Disabled / unknown — never show an approval sheet for a dead tool.
            print("[AgentSession] Skipping approval; tool not enabled: \(toolName)")
            return false
        }
        let payload = await mcpClient.buildApprovalPayload(
            serverId: match.server.id,
            toolName: match.tool.name,
            arguments: arguments
        )

        return await withCheckedContinuation { continuation in
            self.approvalContinuation?.resume(returning: false)
            self.approvalContinuation = continuation
            self.approvalContinuationToolName = toolName
            self.pendingApproval = payload
            self.isThinking = false
            self.isStreaming = false
        }
    }

    private func performAssistantStream(
        request: AgentGenerationRequest,
        evidenceChunks: [DocumentChunk] = [],
        toolResults: [String] = [],
        forcedCitations: [Citation] = [],
        memoryEvidence: [String] = [],
        systemPrompt: String = NookSystemPrompt.standard,
        streamHandler: @escaping AgentStreamHandler,
        userMessageForMemory: Message? = nil,
        memoryExtractHandler: MemoryExtractHandler? = nil
    ) async {
        isThinking = true

        let assistantMsg = Message(
            conversationId: conversation.id,
            role: .assistant,
            content: "",
            citations: []
        )
        let assistantMsgId = assistantMsg.id
        messages.append(assistantMsg)

        self.isStreaming = true

        let promptContext = contextAssembler.assemble(
            baseSystemPrompt: systemPrompt,
            activeSkill: nil,
            evidenceChunks: evidenceChunks,
            chatHistory: messages.filter { $0.id != assistantMsgId },
            toolResults: toolResults,
            memoryEvidence: memoryEvidence
        )

        let registry = toolRegistry
        let toolExecutor: @Sendable (String, ToolArguments) async throws -> ToolExecutionResult = { name, arguments in
            print("[AgentSession] Tool requested: \(name)")
            guard let resolved = await self.resolveToolName(name) else {
                let available = await self.enabledExternalToolNames()
                let hint = available.isEmpty
                    ? "No external tools are enabled."
                    : "Available tools: \(available.joined(separator: ", "))."
                return ToolExecutionResult(
                    textForModel: "Tool '\(name)' is not enabled or unknown. \(hint)",
                    displayText: "Skipped unavailable tool \(name)",
                    isExternal: true
                )
            }
            if await registry.requiresApproval(toolName: resolved) {
                print("[AgentSession] Waiting for approval: \(resolved)")
                let allowed = await self.requestExternalToolApproval(toolName: resolved, arguments: arguments)
                guard allowed else {
                    print("[AgentSession] Tool denied: \(resolved)")
                    throw CancellationError()
                }
                print("[AgentSession] Tool approved: \(resolved)")
                return try await registry.executeApproved(toolName: resolved, arguments: arguments)
            }
            return try await registry.execute(toolName: resolved, arguments: arguments)
        }

        let task = Task {
            do {
                let result = try await streamHandler(
                    promptContext,
                    request,
                    toolExecutor,
                    { token in
                        guard !Task.isCancelled else { return }
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            guard let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }) else {
                                return
                            }
                            self.isThinking = false
                            var updated = self.messages[index]
                            updated.content += token
                            self.messages[index] = updated
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
                        var updated = self.messages[index]
                        let merged = result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? updated.content
                            : result.text
                        let trimmed = merged.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            updated.content = "I couldn't generate a reply. Please try again."
                        } else if updated.content != merged {
                            updated.content = merged
                        }
                        let citations = result.citations.isEmpty ? forcedCitations : result.citations
                        if !updated.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            updated.citations = citations
                        }
                        self.messages[index] = updated
                        self.persist(message: updated)
                    }
                    self.trimDisplayedMessages()
                    self.isThinking = false
                    self.isStreaming = false
                    self.activeGenerationTask = nil
                }

                if let userMessageForMemory, let memoryExtractHandler {
                    let title = await MainActor.run { self.conversation.title }
                    let engine = memoryEngine
                    Task {
                        await engine.processUserMessage(
                            message: userMessageForMemory,
                            conversationTitle: title,
                            generate: memoryExtractHandler
                        )
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    if let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }),
                       self.messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.messages[index].content = "Cancelled — nothing was sent."
                        self.persist(message: self.messages[index])
                        self.showToast("Cancelled.")
                    } else if let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                        self.persist(message: self.messages[index])
                    }
                    self.isThinking = false
                    self.isStreaming = false
                    self.activeGenerationTask = nil
                }
            } catch {
                await MainActor.run {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? "Something went wrong while generating on device."
                    if let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }),
                       self.messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.messages[index].content = message
                    }
                    if let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                        self.persist(message: self.messages[index])
                    }
                    self.isThinking = false
                    self.isStreaming = false
                    self.activeGenerationTask = nil
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
                    footer: "external"
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

    /// Maps a model-emitted tool name to a registered external tool id.
    private func resolveToolName(_ requested: String) async -> String? {
        if await toolRegistry.getTool(named: requested) != nil {
            return requested
        }
        // Bare MCP name (e.g. tavily_search) → unique namespaced match.
        let suffix = "__\(requested)"
        let matches = await enabledExternalToolNames().filter {
            $0 == requested || $0.hasSuffix(suffix)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func enabledExternalToolNames() async -> [String] {
        var names: [String] = []
        for name in await toolRegistry.allToolNames() {
            if let tool = await toolRegistry.getTool(named: name), tool.isExternal {
                names.append(name)
            }
        }
        return names.sorted()
    }

    public func persistConversationMetadata() {
        // Don't write empty draft chats to disk — they would clutter the list/DB
        // if the user backs out without sending.
        guard !messages.isEmpty else { return }
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
            if let userTextForMetadata {
                let title = conversation.title == "New chat"
                    ? ChatStore.snippet(from: userTextForMetadata, maxLength: 48)
                    : conversation.title
                let snippet = ChatStore.snippet(from: userTextForMetadata)
                conversation.title = title
                conversation.snippet = snippet
                conversation.updatedAt = Date()
                conversation.whenString = ChatStore.formatWhenString(conversation.updatedAt)
            } else if message.role == .assistant {
                let snippet = ChatStore.snippet(from: message.content)
                conversation.snippet = snippet
                conversation.updatedAt = Date()
                conversation.whenString = ChatStore.formatWhenString(conversation.updatedAt)
            }

            // Conversation row must exist before messages (FK). First send creates it.
            try chatStore.saveConversation(conversation)
            try chatStore.saveMessage(message)
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
