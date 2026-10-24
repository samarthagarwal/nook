import Foundation
import Combine

/// Protocol defining the interface that ChatView needs from a session.
/// Both AgentSession and BackendAgentSession conform to this.
@MainActor
public protocol ChatSessionProtocol: ObservableObject {
    var conversation: Conversation { get set }
    var messages: [Message] { get set }
    var isStreaming: Bool { get }
    var isThinking: Bool { get }
    var pendingApproval: OutgoingApprovalPayload? { get }
    var toastMessage: String? { get set }

    var knowledgeEngine: KnowledgeEngine { get }
    var skillManager: SkillManager { get }
    var toolRegistry: ToolRegistry { get }
    var mcpClient: MCPClient { get }
    var mcpToolRegistrar: MCPToolRegistrar { get }

    func sendMessage(
        text: String,
        attachedImageName: String?,
        wasDictated: Bool,
        runtime: any Sendable,
        streamHandler: @escaping AgentSession.AgentStreamHandler
    ) async

    func cancelGeneration()
    func resolveApproval(action: ApprovalAction)
    func setActiveSkill(_ skill: Skill?)
    func trimDisplayedMessages(keepingLast count: Int)
    func showToast(_ text: String)
    func persistConversationMetadata()
}

// Default implementation for trimDisplayedMessages
public extension ChatSessionProtocol {
    func trimDisplayedMessages(keepingLast count: Int) {
        // Default implementation - subclasses can override
    }
}
