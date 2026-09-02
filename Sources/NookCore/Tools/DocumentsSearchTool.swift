import Foundation

public struct DocumentsSearchOutput: Sendable {
    public let chunks: [DocumentChunk]
    public let citations: [Citation]
    public let scopeLabel: String

    public init(chunks: [DocumentChunk], citations: [Citation], scopeLabel: String) {
        self.chunks = chunks
        self.citations = citations
        self.scopeLabel = scopeLabel
    }
}

/// Local Knowledge retrieval — registered as `documents_search`.
/// Underscore name keeps tool ids simple for native tool-call parsers.
public final class DocumentsSearchTool: @unchecked Sendable, AgentTool {
    public static let toolName = "documents_search"

    public var name: String { Self.toolName }
    public let description = """
        Search scoped Knowledge collections for passages matching a query. \
        Call this when the answer may be in the user's documents.
        """
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "query",
            type: "string",
            description: "Natural-language search query for relevant passages.",
            required: true
        ),
    ]

    /// Conversation Knowledge scope, enforced by the app (not chosen freely by the model).
    public var boundScope: [String] = []

    private let knowledgeEngine: KnowledgeEngine

    public init(knowledgeEngine: KnowledgeEngine) {
        self.knowledgeEngine = knowledgeEngine
    }

    public func search(query: String, scopedToCollections: [String]) async -> DocumentsSearchOutput {
        let scope = scopedToCollections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let (chunks, citations) = await knowledgeEngine.search(
            query: query,
            scopedToCollections: scope
        )
        return DocumentsSearchOutput(
            chunks: chunks,
            citations: citations,
            scopeLabel: scope.joined(separator: ", ")
        )
    }

    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        guard let rawQuery = arguments["query"]?.stringValue else {
            throw DocumentsSearchToolError.missingQuery
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw DocumentsSearchToolError.missingQuery
        }

        let scope = boundScope
        guard !scope.isEmpty else {
            return ToolExecutionResult(
                textForModel: "No Knowledge collections are scoped to this chat. Ask the user to enable a collection.",
                displayText: "\(Self.toolName) · no scope"
            )
        }

        let result = await search(query: query, scopedToCollections: scope)
        if result.chunks.isEmpty {
            return ToolExecutionResult(
                textForModel: "No matching passages found in \(result.scopeLabel) for query: \(query)",
                displayText: "\(Self.toolName) · \(result.scopeLabel) · 0 passages"
            )
        }

        var lines: [String] = [
            "Verbatim passages from \(result.scopeLabel) (use only these; do not invent):"
        ]
        for (index, chunk) in result.chunks.enumerated() {
            let citation = result.citations[safe: index]
            let label = citation?.label ?? "\(chunk.documentId) · \(chunk.pageOrSection)"
            lines.append("SOURCE [\(index + 1)] \(label)\n\"\"\"\n\(chunk.text)\n\"\"\"")
        }

        return ToolExecutionResult(
            textForModel: lines.joined(separator: "\n\n"),
            displayText: "\(Self.toolName) · \(result.scopeLabel) · \(result.chunks.count) passages",
            citations: result.citations,
            chunks: result.chunks
        )
    }
}

enum DocumentsSearchToolError: LocalizedError {
    case missingQuery

    var errorDescription: String? {
        switch self {
        case .missingQuery:
            return "documents_search requires a query argument."
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
