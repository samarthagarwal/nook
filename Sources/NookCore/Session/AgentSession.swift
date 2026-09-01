import Foundation

@MainActor
public final class AgentSession: ObservableObject {
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
    
    private var pendingStreamHandler: (@Sendable (AssembledPromptContext, @escaping @Sendable (String) -> Void) async throws -> String)? = nil
    
    public init(
        conversation: Conversation,
        knowledgeEngine: KnowledgeEngine,
        memoryEngine: MemoryEngine,
        skillManager: SkillManager,
        toolRegistry: ToolRegistry,
        mcpClient: MCPClient,
        contextAssembler: ContextAssembler = ContextAssembler()
    ) {
        self.conversation = conversation
        self.knowledgeEngine = knowledgeEngine
        self.memoryEngine = memoryEngine
        self.skillManager = skillManager
        self.toolRegistry = toolRegistry
        self.mcpClient = mcpClient
        self.contextAssembler = contextAssembler
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
    
    public func sendMessage(
        text: String,
        attachedImageName: String? = nil,
        runtime: any Sendable,
        streamHandler: @escaping @Sendable (AssembledPromptContext, @escaping @Sendable (String) -> Void) async throws -> String
    ) async {
        let userMsg = Message(
            conversationId: conversation.id,
            role: .user,
            content: text,
            attachedImageName: attachedImageName
        )
        messages.append(userMsg)
        
        let lower = text.lowercased()
        
        // Scenario 1: Knowledge RAG inquiry
        if lower.contains("risk") || lower.contains("project") {
            let localPill = Message(
                conversationId: conversation.id,
                role: .localTool,
                content: "",
                localToolText: "documents.search · Project Alpha · 5 passages"
            )
            messages.append(localPill)
            
            let (chunks, citations) = await knowledgeEngine.search(
                query: text,
                scopedToCollections: conversation.activeKnowledgeScope
            )
            
            await performAssistantStream(
                evidenceChunks: chunks,
                citationsToAttachOnCompletion: citations,
                streamHandler: streamHandler
            )
            return
        }
        
        // Scenario 2: Vision inquiry
        if attachedImageName != nil || lower.contains("spec") || lower.contains("match") {
            let localPill = Message(
                conversationId: conversation.id,
                role: .localTool,
                content: "",
                localToolText: "reading image · 1 page of alpha-spec-v4.pdf"
            )
            messages.append(localPill)
            
            await performAssistantStream(
                evidenceChunks: [],
                citationsToAttachOnCompletion: [],
                streamHandler: streamHandler
            )
            return
        }
        
        // Scenario 3: MCP / External GitHub inquiry
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
        
        // Default general query
        await performAssistantStream(
            evidenceChunks: [],
            citationsToAttachOnCompletion: [],
            streamHandler: streamHandler
        )
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
    
    private func executeApprovedMCP(
        streamHandler: @escaping @Sendable (AssembledPromptContext, @escaping @Sendable (String) -> Void) async throws -> String
    ) async {
        let toolMsg = Message(
            conversationId: self.conversation.id,
            role: .externalTool,
            content: "",
            externalToolData: ExternalToolExecution(
                toolName: "github.search_issues",
                lines: [
                    "#418 Identity provider fallback — open, unassigned",
                    "#402 Analytics scope — open, needs-estimate"
                ],
                footer: "mcp.github-bridge.dev · 0.9s"
            )
        )
        self.messages.append(toolMsg)
        
        await self.performAssistantStream(
            evidenceChunks: [],
            citationsToAttachOnCompletion: [],
            toolResults: ["github.search_issues returned #418 (Identity provider fallback) and #402 (Analytics scope)"],
            streamHandler: streamHandler
        )
    }
    
    private func performAssistantStream(
        evidenceChunks: [DocumentChunk] = [],
        citationsToAttachOnCompletion: [Citation] = [],
        toolResults: [String] = [],
        streamHandler: @escaping @Sendable (AssembledPromptContext, @escaping @Sendable (String) -> Void) async throws -> String
    ) async {
        self.isThinking = true
        try? await Task.sleep(nanoseconds: 350_000_000)
        self.isThinking = false
        
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
            baseSystemPrompt: "You are Nook, a private on-device assistant.",
            activeSkill: nil,
            evidenceChunks: evidenceChunks,
            chatHistory: messages,
            toolResults: toolResults
        )
        
        do {
            var fullText = ""
            let stream = AsyncStream<String> { continuation in
                Task.detached(priority: .userInitiated) {
                    do {
                        _ = try await streamHandler(promptContext) { token in
                            continuation.yield(token)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish()
                    }
                }
            }

            for await token in stream {
                fullText += token
                if let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                    self.messages[index].content = fullText
                }
            }

            if let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                self.messages[index].content = fullText
                self.messages[index].citations = citationsToAttachOnCompletion
            }
        } catch {
            if let index = self.messages.firstIndex(where: { $0.id == assistantMsgId }) {
                self.messages[index].content = "An error occurred during local generation."
            }
        }
        
        self.isStreaming = false
    }
}

public enum ApprovalAction: Sendable {
    case sendOnce
    case alwaysAllow
    case dont
}

