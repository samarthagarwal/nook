import Foundation

/// Handles voice input by classifying intent and executing appropriate actions.
/// Coordinates RAG search, intent classification, and action execution.
public actor VoiceIntentHandler {
    
    // MARK: - Types
    
    public enum Result: Sendable {
        /// User asked a question - should be sent to chat
        case question(text: String, context: [DocumentChunk])
        
        /// Created a new todo
        case todoCreated(TodoItem)
        
        /// Updated an existing todo
        case todoUpdated(TodoItem, action: String)
        
        /// Saved as brain dump / knowledge
        case brainDumpSaved(documentName: String)
        
        /// Classification failed or was ambiguous - fall back to chat
        case fallbackToChat(text: String, reason: String)
    }
    
    // MARK: - Dependencies
    
    private let classifier: IntentClassifier
    private let todoStore: TodoStore
    private let knowledgeStore: KnowledgeStore
    
    public init(
        classifier: IntentClassifier = IntentClassifier(),
        todoStore: TodoStore = .shared,
        knowledgeStore: KnowledgeStore = .shared
    ) {
        self.classifier = classifier
        self.todoStore = todoStore
        self.knowledgeStore = knowledgeStore
    }
    
    // MARK: - Public API
    
    /// Processes voice transcript: classifies intent and executes action.
    /// - Parameters:
    ///   - transcript: The transcribed voice input.
    ///   - conversationId: Optional conversation ID for source linking.
    ///   - messageId: Optional message ID for source linking.
    /// - Returns: The result of processing the voice input.
    public func process(
        transcript: String,
        conversationId: String? = nil,
        messageId: String? = nil
    ) async -> Result {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .fallbackToChat(text: "", reason: "Empty transcript")
        }
        
        // Step 1: RAG search for context
        let context = await gatherContext(for: trimmed)
        
        // Step 2: Classify intent
        let classification: IntentClassifier.ClassificationResult
        do {
            classification = try await classifier.classifyWithoutThreshold(trimmed, context: context)
        } catch {
            print("[VoiceIntentHandler] Classification failed: \(error)")
            return .fallbackToChat(text: trimmed, reason: "Classification error: \(error.localizedDescription)")
        }
        
        print("[VoiceIntentHandler] Intent: \(classification.intent) (confidence: \(classification.confidence))")
        
        // Step 3: Execute action based on intent
        return await executeIntent(
            classification: classification,
            transcript: trimmed,
            conversationId: conversationId,
            messageId: messageId,
            context: context
        )
    }
    
    // MARK: - Private
    
    private func gatherContext(for query: String) async -> IntentClassifier.Context {
        // Search todos semantically
        let todoMatches: [IntentClassifier.Context.TodoMatch]
        do {
            let scored = try todoStore.searchSemantic(query: query, limit: 5, threshold: 0.25)
            todoMatches = scored.map { scored in
                IntentClassifier.Context.TodoMatch(
                    title: scored.todo.title,
                    isCompleted: scored.todo.isCompleted,
                    score: scored.score
                )
            }
        } catch {
            print("[VoiceIntentHandler] Todo search failed: \(error)")
            todoMatches = []
        }
        
        // Search knowledge (all collections for now)
        let knowledgeMatches: [IntentClassifier.Context.KnowledgeMatch]
        if let hits = try? knowledgeStore.search(query: query, scopedToCollections: []) {
            knowledgeMatches = hits.prefix(3).map { hit in
                IntentClassifier.Context.KnowledgeMatch(
                    text: hit.chunk.text,
                    source: hit.documentName,
                    score: Float(hit.score)
                )
            }
        } else {
            knowledgeMatches = []
        }
        
        return IntentClassifier.Context(
            matchedTodos: todoMatches,
            matchedKnowledge: Array(knowledgeMatches)
        )
    }
    
    private func executeIntent(
        classification: IntentClassifier.ClassificationResult,
        transcript: String,
        conversationId: String?,
        messageId: String?,
        context: IntentClassifier.Context
    ) async -> Result {
        switch classification.intent {
        case .question:
            // Return to chat with any retrieved knowledge context
            let query = classification.details.query ?? transcript
            let chunks: [DocumentChunk]
            if let hits = try? knowledgeStore.search(query: query, scopedToCollections: []) {
                chunks = hits.map(\.chunk)
            } else {
                chunks = []
            }
            return .question(text: transcript, context: chunks)
            
        case .todoCreate:
            return await handleTodoCreate(
                classification: classification,
                transcript: transcript,
                conversationId: conversationId,
                messageId: messageId
            )
            
        case .todoUpdate:
            return await handleTodoUpdate(
                classification: classification,
                transcript: transcript
            )
            
        case .brainDump:
            return await handleBrainDump(
                classification: classification,
                transcript: transcript
            )
        }
    }
    
    private func handleTodoCreate(
        classification: IntentClassifier.ClassificationResult,
        transcript: String,
        conversationId: String?,
        messageId: String?
    ) async -> Result {
        let title = classification.details.title ?? transcript
        
        // Parse due date if provided
        let dueDate = classification.details.dueDate.flatMap { parseDueDate($0) }
        
        let todo = TodoItem(
            title: title,
            dueDate: dueDate,
            sourceConversationId: conversationId,
            sourceMessageId: messageId
        )
        
        do {
            try todoStore.create(todo)
            return .todoCreated(todo)
        } catch {
            print("[VoiceIntentHandler] Failed to create todo: \(error)")
            return .fallbackToChat(text: transcript, reason: "Failed to create todo")
        }
    }
    
    private func handleTodoUpdate(
        classification: IntentClassifier.ClassificationResult,
        transcript: String
    ) async -> Result {
        let matchText = classification.details.matchText ?? transcript
        let action = classification.details.action ?? "complete"
        
        // Find matching todo
        guard let todo = try? todoStore.findBestMatch(for: matchText) else {
            // No match found - fall back to chat
            return .fallbackToChat(text: transcript, reason: "No matching todo found")
        }
        
        do {
            var updatedTodo = todo
            switch action {
            case "complete":
                try todoStore.markCompleted(id: todo.id)
                updatedTodo = todo.completed()
            case "reopen":
                try todoStore.markIncomplete(id: todo.id)
                updatedTodo = todo.uncompleted()
            case "delete":
                try todoStore.delete(id: todo.id)
            default:
                // For "update" or unknown actions, fall back to chat
                return .fallbackToChat(text: transcript, reason: "Unsupported todo action: \(action)")
            }
            return .todoUpdated(updatedTodo, action: action)
        } catch {
            print("[VoiceIntentHandler] Failed to update todo: \(error)")
            return .fallbackToChat(text: transcript, reason: "Failed to update todo")
        }
    }
    
    private func handleBrainDump(
        classification: IntentClassifier.ClassificationResult,
        transcript: String
    ) async -> Result {
        // Save as knowledge document in a "Voice Notes" collection
        let summary = classification.details.summary ?? String(transcript.prefix(100))
        let documentName = "Voice Note - \(formatDate(Date()))"
        let collectionName = "Voice Notes"
        
        do {
            // Find or create the Voice Notes collection
            let collections = try knowledgeStore.fetchCollections()
            var collectionId: String
            
            if let existing = collections.first(where: { $0.name == collectionName }) {
                collectionId = existing.id
            } else {
                let newCollection = try knowledgeStore.createCollection(
                    name: collectionName,
                    desc: "Voice notes and brain dumps"
                )
                collectionId = newCollection.id
            }
            
            // Index the document with transcript as content
            try knowledgeStore.indexDocumentText(
                collectionId: collectionId,
                documentName: documentName,
                meta: summary,
                pageOrSection: "Full transcript",
                text: transcript
            )
            
            return .brainDumpSaved(documentName: documentName)
        } catch {
            print("[VoiceIntentHandler] Failed to save brain dump: \(error)")
            return .fallbackToChat(text: transcript, reason: "Failed to save note")
        }
    }
    
    // MARK: - Helpers
    
    private func parseDueDate(_ text: String) -> Date? {
        let lower = text.lowercased()
        let calendar = Calendar.current
        let now = Date()
        
        // Simple parsing for common patterns
        if lower.contains("today") {
            return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now)
        } else if lower.contains("tomorrow") {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        } else if lower.contains("next week") {
            return calendar.date(byAdding: .weekOfYear, value: 1, to: now)
        }
        
        // Try natural language date parsing
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        if let match = detector?.firstMatch(in: text, options: [], range: range),
           let date = match.date {
            return date
        }
        
        return nil
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }
}
