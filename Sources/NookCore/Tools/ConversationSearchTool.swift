import Foundation

/// Searches the raw text of past conversation messages.
///
/// Queries the `messages` table directly — no memory extraction pipeline required.
/// Returns the closest matching user and assistant messages so the model can answer
/// follow-up questions that need the actual wording from a previous chat.
public final class ConversationSearchTool: @unchecked Sendable, AgentTool {
    public static let toolName = "conversation.search"

    /// Hard cap on characters returned per message so we don't blow the context window.
    private static let maxMessageChars = 500
    /// Max messages to return in one call.
    private static let maxMessages = 6

    public var name: String { Self.toolName }
    public let description = """
        Search the text of past conversations to find what was actually said about a topic. \
        Use this when the user wants to recall details, exact wording, or context from a previous chat. \
        Returns the closest matching messages.
        """
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "query",
            type: "string",
            description: "Key words or topic to search for in past conversations, e.g. \"monetisation plan mix Shubh\".",
            required: true
        ),
    ]

    private let chatStore: ChatStore

    public init(chatStore: ChatStore) {
        self.chatStore = chatStore
    }

    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        let query = (arguments["query"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ToolExecutionResult(
                textForModel: "conversation.search requires a non-empty query.",
                displayText: "Conversation · missing query",
                disposition: .completed
            )
        }

        let hits = (try? chatStore.searchMessages(query: query, limit: Self.maxMessages)) ?? []
        #if DEBUG
        print("[NookDiag] conversation.search query='\(query)' results=\(hits.count)")
        #endif

        guard !hits.isEmpty else {
            return ToolExecutionResult(
                textForModel: "No past conversation messages found for: \(query). Answer from what you know or ask the user to clarify.",
                displayText: "Conversation · no results",
                disposition: .completed
            )
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        let blocks = hits.map { msg -> String in
            let date = formatter.string(from: msg.createdAt)
            let role = msg.role == .user ? "User" : "Assistant"
            let body = msg.content.count > Self.maxMessageChars
                ? String(msg.content.prefix(Self.maxMessageChars)) + "…"
                : msg.content
            return "[\(date) · \(role)] \(body)"
        }

        let count = hits.count
        return ToolExecutionResult(
            textForModel: "Found \(count) past message(s) — use these to answer the user now:\n\n" + blocks.joined(separator: "\n\n"),
            displayText: "Conversation · \(count) message\(count == 1 ? "" : "s")",
            disposition: .completed
        )
    }
}
