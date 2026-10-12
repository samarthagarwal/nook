import Foundation
import GRDB

/// SQLite persistence for todo items.
public final class TodoStore: @unchecked Sendable {
    public static let shared: TodoStore = {
        do {
            return try TodoStore()
        } catch {
            fatalError("Failed to open todo database: \(error)")
        }
    }()
    
    private let dbQueue: DatabaseQueue
    
    public init(dbQueue: DatabaseQueue? = nil) throws {
        self.dbQueue = try dbQueue ?? NookDatabase.makeQueue()
    }
    
    // MARK: - CRUD Operations
    
    /// Creates a new todo item with automatic embedding.
    public func create(_ todo: TodoItem) throws {
        // Compute embedding from title (+ notes if present)
        let textToEmbed = [todo.title, todo.notes].compactMap { $0 }.joined(separator: " ")
        let embeddingData = KnowledgeEmbedder.embed(textToEmbed).map { KnowledgeEmbedder.embeddingData(from: $0) }
        
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO todos (
                        id, title, notes, due_date, is_completed, completed_at,
                        priority, source_conversation_id, source_message_id, created_at, updated_at, embedding
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    todo.id,
                    todo.title,
                    todo.notes,
                    todo.dueDate,
                    todo.isCompleted,
                    todo.completedAt,
                    todo.priority.rawValue,
                    todo.sourceConversationId,
                    todo.sourceMessageId,
                    todo.createdAt,
                    todo.updatedAt,
                    embeddingData
                ]
            )
        }
    }
    
    /// Updates an existing todo item.
    public func update(_ todo: TodoItem) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE todos SET
                        title = ?, notes = ?, due_date = ?, is_completed = ?, completed_at = ?,
                        priority = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    todo.title,
                    todo.notes,
                    todo.dueDate,
                    todo.isCompleted,
                    todo.completedAt,
                    todo.priority.rawValue,
                    Date(),
                    todo.id
                ]
            )
        }
    }
    
    /// Deletes a todo by ID.
    public func delete(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM todos WHERE id = ?", arguments: [id])
        }
    }
    
    /// Marks a todo as completed.
    public func markCompleted(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE todos SET is_completed = 1, completed_at = ?, updated_at = ? WHERE id = ?",
                arguments: [Date(), Date(), id]
            )
        }
    }
    
    /// Marks a todo as not completed.
    public func markIncomplete(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE todos SET is_completed = 0, completed_at = NULL, updated_at = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }
    
    // MARK: - Queries
    
    /// Fetches all incomplete todos, ordered by due date (nulls last) then created date.
    public func fetchIncomplete() throws -> [TodoItem] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM todos
                    WHERE is_completed = 0
                    ORDER BY
                        CASE WHEN due_date IS NULL THEN 1 ELSE 0 END,
                        due_date ASC,
                        created_at DESC
                    """
            )
            return rows.map(todoItem(from:))
        }
    }
    
    /// Fetches all completed todos, ordered by completion date descending.
    public func fetchCompleted(limit: Int = 50) throws -> [TodoItem] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM todos
                    WHERE is_completed = 1
                    ORDER BY completed_at DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            return rows.map(todoItem(from:))
        }
    }
    
    /// Fetches all todos (incomplete first, then completed).
    public func fetchAll() throws -> [TodoItem] {
        let incomplete = try fetchIncomplete()
        let completed = try fetchCompleted()
        return incomplete + completed
    }
    
    /// Fetches a single todo by ID.
    public func fetch(id: String) throws -> TodoItem? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM todos WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return todoItem(from: row)
        }
    }
    
    /// Searches todos by title (fuzzy match).
    public func search(query: String) throws -> [TodoItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return try fetchAll() }
        
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM todos
                    WHERE lower(title) LIKE ?
                    ORDER BY is_completed ASC, created_at DESC
                    """,
                arguments: ["%\(trimmed)%"]
            )
            return rows.map(todoItem(from:))
        }
    }
    
    /// Finds a todo that best matches the given text (for "mark X as done" commands).
    public func findBestMatch(for text: String) throws -> TodoItem? {
        let incomplete = try fetchIncomplete()
        let normalized = text.lowercased()
        
        // Exact title match first
        if let exact = incomplete.first(where: { $0.title.lowercased() == normalized }) {
            return exact
        }
        
        // Contains match
        if let contains = incomplete.first(where: { $0.title.lowercased().contains(normalized) }) {
            return contains
        }
        
        // Token overlap
        let queryTokens = Set(normalized.split(separator: " ").map(String.init))
        var bestMatch: (todo: TodoItem, score: Int)?
        
        for todo in incomplete {
            let titleTokens = Set(todo.title.lowercased().split(separator: " ").map(String.init))
            let overlap = queryTokens.intersection(titleTokens).count
            if overlap > 0, bestMatch == nil || overlap > bestMatch!.score {
                bestMatch = (todo, overlap)
            }
        }
        
        return bestMatch?.todo
    }
    
    /// Counts incomplete todos.
    public func incompleteCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM todos WHERE is_completed = 0") ?? 0
        }
    }
    
    // MARK: - Semantic Search
    
    /// Represents a todo with its similarity score for RAG results.
    public struct ScoredTodo: Sendable {
        public let todo: TodoItem
        public let score: Float
    }
    
    /// Searches todos by semantic similarity to the query text.
    /// Returns top matches sorted by similarity score (highest first).
    public func searchSemantic(query: String, limit: Int = 5, threshold: Float = 0.3) throws -> [ScoredTodo] {
        guard let queryVector = KnowledgeEmbedder.embed(query) else {
            return []
        }
        return try searchSemantic(queryVector: queryVector, limit: limit, threshold: threshold)
    }
    
    /// Searches todos by semantic similarity using a pre-computed query vector.
    public func searchSemantic(queryVector: [Float], limit: Int = 5, threshold: Float = 0.3) throws -> [ScoredTodo] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM todos WHERE embedding IS NOT NULL")
            
            var scored: [ScoredTodo] = []
            for row in rows {
                guard let embeddingData: Data = row["embedding"],
                      let todoVector = KnowledgeEmbedder.vector(from: embeddingData) else {
                    continue
                }
                
                let similarity = KnowledgeEmbedder.cosineSimilarity(queryVector, todoVector)
                if similarity >= threshold {
                    scored.append(ScoredTodo(todo: todoItem(from: row), score: similarity))
                }
            }
            
            return scored
                .sorted { $0.score > $1.score }
                .prefix(limit)
                .map { $0 }
        }
    }
    
    // MARK: - Private
    
    private func todoItem(from row: Row) -> TodoItem {
        TodoItem(
            id: row["id"],
            title: row["title"],
            notes: row["notes"],
            dueDate: row["due_date"],
            isCompleted: row["is_completed"],
            completedAt: row["completed_at"],
            priority: TodoItem.Priority(rawValue: row["priority"] ?? 0) ?? .none,
            sourceConversationId: row["source_conversation_id"],
            sourceMessageId: row["source_message_id"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }
}
