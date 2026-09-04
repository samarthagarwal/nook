import Foundation

/// On-device tool that searches past-conversation memory cards.
/// Registered as `memory.search` so the model can explicitly retrieve memory
/// context, producing a UI chip just like `documents_search` and MCP tools.
public final class MemorySearchTool: @unchecked Sendable, AgentTool {
    public static let toolName = "memory.search"

    public var name: String { Self.toolName }
    public let description = """
        Search past-conversation memory for context the user has shared before. \
        Call this when you need to recall a preference, name, project, or fact \
        that the user mentioned in a previous chat session.
        """
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "query",
            type: "string",
            description: "What to look for in past-conversation memory, e.g. \"user's job\" or \"project name\".",
            required: true
        ),
    ]

    private let memoryEngine: MemoryEngine

    public init(memoryEngine: MemoryEngine) {
        self.memoryEngine = memoryEngine
    }

    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        let query = (arguments["query"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ToolExecutionResult(
                textForModel: "memory.search requires a non-empty query.",
                displayText: "Memory · missing query",
                disposition: .completed
            )
        }

        let results = await memoryEngine.memoriesForChat(query: query)
        #if DEBUG
        print("[NookDiag] memory.search query='\(query)' results=\(results.count)")
        #endif
        guard !results.isEmpty else {
            return ToolExecutionResult(
                textForModel: "No relevant memory found for: \(query). Answer the user from what you know, or ask them to clarify — do not call memory.search again with a similar query.",
                displayText: "Memory · no results",
                disposition: .completed
            )
        }

        let formatted = results
            .map { MemoryEngine.formatEvidence($0) }
            .joined(separator: "\n\n")
        let count = results.count
        return ToolExecutionResult(
            textForModel: """
                Found \(count) memory card(s) — use these to answer the user now, do not call memory.search again:

                \(formatted)
                """,
            displayText: "Memory · \(count) result\(count == 1 ? "" : "s")",
            disposition: .completed
        )
    }
}
