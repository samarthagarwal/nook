import Foundation

/// Saves information to Knowledge for later retrieval.
public final class NotesSaveTool: @unchecked Sendable, AgentTool {
    public static let toolName = "notes_save"
    
    public var name: String { Self.toolName }
    public let description = """
        Save a piece of information to the user's knowledge base for later retrieval. \
        Use when the user wants to remember a fact, store information, or save a note. \
        Do NOT use for tasks/todos - use todos.create for those. \
        Use for facts like birthdays, passwords, preferences, meeting notes, ideas.
        """
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "title",
            type: "string",
            description: "A short title for the note (e.g., 'Sarah's Birthday', 'WiFi Password')",
            required: true
        ),
        AgentToolParameterSchema(
            name: "content",
            type: "string",
            description: "The information to save",
            required: true
        )
    ]
    
    private let store: KnowledgeStore
    
    public init(store: KnowledgeStore = .shared) {
        self.store = store
    }
    
    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            return ToolExecutionResult(
                textForModel: "Error: title is required",
                displayText: "\(Self.toolName) · missing title",
                disposition: .failed
            )
        }
        
        guard let content = arguments["content"]?.stringValue, !content.isEmpty else {
            return ToolExecutionResult(
                textForModel: "Error: content is required",
                displayText: "\(Self.toolName) · missing content",
                disposition: .failed
            )
        }
        
        let collectionName = "Quick Notes"
        
        do {
            // Find or create the Quick Notes collection
            let collections = try store.fetchCollections()
            var collectionId: String
            
            if let existing = collections.first(where: { $0.name == collectionName }) {
                collectionId = existing.id
            } else {
                let newCollection = try store.createCollection(
                    name: collectionName,
                    desc: "Notes saved from conversations"
                )
                collectionId = newCollection.id
            }
            
            // Save the note as a document
            try store.indexDocumentText(
                collectionId: collectionId,
                documentName: title,
                meta: String(content.prefix(100)),
                pageOrSection: "Note",
                text: content
            )
            
            return ToolExecutionResult(
                textForModel: "Saved note '\(title)' to Quick Notes. The information has been stored.",
                displayText: "\(Self.toolName) · saved",
                disposition: .finished
            )
        } catch {
            return ToolExecutionResult(
                textForModel: "Failed to save note: \(error.localizedDescription)",
                displayText: "\(Self.toolName) · failed",
                disposition: .failed
            )
        }
    }
}
