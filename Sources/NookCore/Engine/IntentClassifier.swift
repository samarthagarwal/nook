import Foundation

/// Classifies user voice input into actionable intents using GPT-4o-mini.
public actor IntentClassifier {
    
    // MARK: - Types
    
    public enum Intent: String, Codable, Sendable {
        case question       // User is asking a question to be answered
        case todoCreate     // User wants to create a new task/reminder
        case todoUpdate     // User wants to update/complete/delete a task
        case brainDump      // User is sharing information to remember
    }
    
    public struct ClassificationResult: Codable, Sendable {
        public let intent: Intent
        public let confidence: Double
        public let details: Details
        
        public struct Details: Codable, Sendable {
            // For question intent
            public let query: String?
            
            // For todo intents
            public let title: String?
            public let dueDate: String?
            public let action: String?      // "complete", "delete", "update"
            public let matchText: String?   // Text to match existing todo
            
            // For brain dump
            public let summary: String?
            
            public init(
                query: String? = nil,
                title: String? = nil,
                dueDate: String? = nil,
                action: String? = nil,
                matchText: String? = nil,
                summary: String? = nil
            ) {
                self.query = query
                self.title = title
                self.dueDate = dueDate
                self.action = action
                self.matchText = matchText
                self.summary = summary
            }
        }
        
        public init(intent: Intent, confidence: Double, details: Details) {
            self.intent = intent
            self.confidence = confidence
            self.details = details
        }
    }
    
    public enum ClassificationError: LocalizedError {
        case noAPIKey
        case networkError(Error)
        case invalidResponse
        case lowConfidence(ClassificationResult)
        
        public var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "OpenAI API key not configured"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                return "Could not parse classification response"
            case .lowConfidence(let result):
                return "Low confidence (\(Int(result.confidence * 100))%) for intent: \(result.intent.rawValue)"
            }
        }
    }
    
    // MARK: - Properties
    
    private let confidenceThreshold: Double
    
    public init(confidenceThreshold: Double = 0.6) {
        self.confidenceThreshold = confidenceThreshold
    }
    
    // MARK: - Context for RAG
    
    /// Context from RAG search to help classification.
    public struct Context: Sendable {
        public let matchedTodos: [TodoMatch]
        public let matchedKnowledge: [KnowledgeMatch]
        
        public struct TodoMatch: Sendable {
            public let title: String
            public let isCompleted: Bool
            public let score: Float
            
            public init(title: String, isCompleted: Bool, score: Float) {
                self.title = title
                self.isCompleted = isCompleted
                self.score = score
            }
        }
        
        public struct KnowledgeMatch: Sendable {
            public let text: String
            public let source: String
            public let score: Float
            
            public init(text: String, source: String, score: Float) {
                self.text = text
                self.source = source
                self.score = score
            }
        }
        
        public init(matchedTodos: [TodoMatch] = [], matchedKnowledge: [KnowledgeMatch] = []) {
            self.matchedTodos = matchedTodos
            self.matchedKnowledge = matchedKnowledge
        }
        
        public static let empty = Context()
    }
    
    // MARK: - Public API
    
    /// Classifies the user's voice transcript into an intent.
    /// - Parameters:
    ///   - transcript: The transcribed voice input.
    ///   - context: Optional RAG context with matched todos and knowledge.
    /// - Returns: Classification result with intent, confidence, and extracted details.
    /// - Throws: ClassificationError if classification fails or confidence is too low.
    public func classify(_ transcript: String, context: Context = .empty) async throws -> ClassificationResult {
        let apiKey = AppPreferences.openAIAPIKey
        guard !apiKey.isEmpty else {
            throw ClassificationError.noAPIKey
        }
        
        let result = try await callOpenAI(transcript: transcript, context: context, apiKey: apiKey)
        
        if result.confidence < confidenceThreshold {
            throw ClassificationError.lowConfidence(result)
        }
        
        return result
    }
    
    /// Classifies without throwing on low confidence - returns the result regardless.
    public func classifyWithoutThreshold(_ transcript: String, context: Context = .empty) async throws -> ClassificationResult {
        let apiKey = AppPreferences.openAIAPIKey
        guard !apiKey.isEmpty else {
            throw ClassificationError.noAPIKey
        }
        
        return try await callOpenAI(transcript: transcript, context: context, apiKey: apiKey)
    }
    
    // MARK: - Private
    
    private func callOpenAI(transcript: String, context: Context, apiKey: String) async throws -> ClassificationResult {
        var systemPrompt = """
        You are an intent classifier for a voice assistant. Analyze the user's message and classify it.
        
        Output JSON with this exact structure:
        {
          "intent": "question" | "todoCreate" | "todoUpdate" | "brainDump",
          "confidence": 0.0 to 1.0,
          "details": {
            "query": "for questions - the search query",
            "title": "for todos - the task title",
            "dueDate": "for todos - extracted date/time like 'tomorrow', '3pm', 'next week'",
            "action": "for todoUpdate - 'complete', 'delete', 'update', or 'reopen'",
            "matchText": "for todoUpdate - text to match existing todo",
            "summary": "for brainDump - brief summary of information to remember"
          }
        }
        
        Intent definitions:
        - question: User is asking something they want answered (e.g., "What's the status of X?", "How do I...?")
        - todoCreate: User wants to create a new task/reminder (e.g., "Buy milk tomorrow", "Remind me to call John")
        - todoUpdate: User wants to update/complete/delete existing task, or implies completion (e.g., "Mark groceries as done", "I got my car washed")
        - brainDump: User is sharing information to remember for later (e.g., "I had a meeting with Sarah about Q3 roadmap")
        
        Only include relevant fields in details. Use null for non-applicable fields.
        """
        
        // Append RAG context if available
        if !context.matchedTodos.isEmpty {
            let todoLines = context.matchedTodos.map { match in
                let status = match.isCompleted ? "✓ done" : "○ pending"
                return "- \(match.title) (\(status))"
            }.joined(separator: "\n")
            systemPrompt += """
            
            
            Related todos found:
            \(todoLines)
            
            If the user's message implies completing, reopening, or referencing one of these todos, classify as todoUpdate.
            """
        }
        
        if !context.matchedKnowledge.isEmpty {
            let knowledgeLines = context.matchedKnowledge.prefix(3).map { match in
                "- \(match.text.prefix(150))... (from: \(match.source))"
            }.joined(separator: "\n")
            systemPrompt += """
            
            
            Related knowledge found:
            \(knowledgeLines)
            
            If the user is asking about this information, classify as question.
            """
        }
        
        let requestBody: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.1,
            "max_tokens": 256
        ]
        
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[IntentClassifier] API error: \(errorBody)")
            throw ClassificationError.networkError(NSError(domain: "IntentClassifier", code: -1, userInfo: [NSLocalizedDescriptionKey: errorBody]))
        }
        
        // Parse OpenAI response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8) else {
            throw ClassificationError.invalidResponse
        }
        
        // Parse the JSON content
        let result = try parseClassificationJSON(contentData)
        print("[IntentClassifier] Classified '\(transcript.prefix(50))...' as \(result.intent.rawValue) (confidence: \(result.confidence))")
        
        return result
    }
    
    private func parseClassificationJSON(_ data: Data) throws -> ClassificationResult {
        struct RawResponse: Codable {
            let intent: String
            let confidence: Double
            let details: RawDetails
            
            struct RawDetails: Codable {
                let query: String?
                let title: String?
                let dueDate: String?
                let action: String?
                let matchText: String?
                let summary: String?
            }
        }
        
        let decoder = JSONDecoder()
        let raw = try decoder.decode(RawResponse.self, from: data)
        
        guard let intent = Intent(rawValue: raw.intent) else {
            throw ClassificationError.invalidResponse
        }
        
        return ClassificationResult(
            intent: intent,
            confidence: raw.confidence,
            details: ClassificationResult.Details(
                query: raw.details.query,
                title: raw.details.title,
                dueDate: raw.details.dueDate,
                action: raw.details.action,
                matchText: raw.details.matchText,
                summary: raw.details.summary
            )
        )
    }
}
