import Foundation
import GRDB

public enum ChatStoreError: Error {
    case encodingFailed
}

/// Local SQLite persistence for conversations and messages.
public final class ChatStore: @unchecked Sendable {
    public static let shared: ChatStore = {
        do {
            return try ChatStore()
        } catch {
            fatalError("Failed to open chat database: \(error)")
        }
    }()

    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue? = nil) throws {
        self.dbQueue = try dbQueue ?? NookDatabase.makeQueue()
    }

    // MARK: - Conversations

    public func fetchConversations() throws -> [Conversation] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM conversations
                    WHERE EXISTS (
                        SELECT 1 FROM messages
                        WHERE messages.conversation_id = conversations.id
                    )
                    ORDER BY updated_at DESC
                    """
            )
            return try rows.map { try conversation(from: $0) }
        }
    }

    public func fetchConversation(id: String) throws -> Conversation? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return try conversation(from: row)
        }
    }

    public func saveConversation(_ conversation: Conversation) throws {
        let tagsJSON = try encodeJSON(conversation.tags)
        let scopeJSON = try encodeJSON(conversation.activeKnowledgeScope)
        try dbQueue.write { db in
            try insertOrReplaceConversation(
                conversation,
                tagsJSON: tagsJSON,
                knowledgeScopeJSON: scopeJSON,
                in: db
            )
        }
    }

    public func deleteConversation(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM messages WHERE conversation_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id])
        }
    }

    /// Removes draft conversations that never received a message (legacy leftovers).
    public func deleteEmptyConversations() throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM conversations
                    WHERE NOT EXISTS (
                        SELECT 1 FROM messages
                        WHERE messages.conversation_id = conversations.id
                    )
                    """
            )
        }
    }

    public func messageCount(conversationId: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
                arguments: [conversationId]
            ) ?? 0
        }
    }

    // MARK: - Messages

    public func fetchMessages(conversationId: String) throws -> [Message] {
        try fetchRecentMessages(conversationId: conversationId, limit: nil)
    }

    /// Returns the most recent messages for a conversation, oldest first.
    public func fetchRecentMessages(conversationId: String, limit: Int?) throws -> [Message] {
        try dbQueue.read { db in
            let rows: [Row]
            if let limit {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM messages
                        WHERE conversation_id = ?
                        ORDER BY created_at DESC
                        LIMIT ?
                        """,
                    arguments: [conversationId, limit]
                )
                return try rows.reversed().map { try message(from: $0) }
            }

            rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM messages
                    WHERE conversation_id = ?
                    ORDER BY created_at ASC
                    """,
                arguments: [conversationId]
            )
            return try rows.map { try message(from: $0) }
        }
    }

    /// Full-text search across user and assistant messages.
    /// Returns up to `limit` matching messages, newest first.
    public func searchMessages(query: String, limit: Int = 8) throws -> [Message] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let tokens = trimmed.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
            .prefix(12)
        guard !tokens.isEmpty else { return [] }
        return try dbQueue.read { db in
            let clauses = tokens.map { _ in "lower(content) LIKE ?" }.joined(separator: " OR ")
            var args = StatementArguments()
            for tok in tokens { args += ["%\(tok)%"] }
            args += [limit]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM messages
                    WHERE role IN ('user', 'assistant')
                      AND (\(clauses))
                    ORDER BY created_at DESC
                    LIMIT ?
                    """,
                arguments: args
            )
            return try rows.map { try message(from: $0) }
        }
    }

    public func saveMessage(_ message: Message) throws {
        let citationsJSON = try encodeJSON(message.citations)
        let externalToolJSON = try message.externalToolData.map { try encodeJSON($0) }
        try dbQueue.write { db in
            try insertOrReplaceMessage(
                message,
                citationsJSON: citationsJSON,
                externalToolJSON: externalToolJSON,
                in: db
            )
        }
    }

    public func touchConversation(
        id: String,
        title: String? = nil,
        snippet: String? = nil,
        knowledgeScope: [String]? = nil,
        tags: [String]? = nil
    ) throws {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?", arguments: [id]) else {
                return
            }
            var conversation = try self.conversation(from: row)
            if let title { conversation.title = title }
            if let snippet { conversation.snippet = snippet }
            if let knowledgeScope { conversation.activeKnowledgeScope = knowledgeScope }
            if let tags { conversation.tags = tags }
            conversation.updatedAt = Date()
            conversation.whenString = Self.formatWhenString(conversation.updatedAt)
            try insertOrReplaceConversation(
                conversation,
                tagsJSON: try encodeJSON(conversation.tags),
                knowledgeScopeJSON: try encodeJSON(conversation.activeKnowledgeScope),
                in: db
            )
        }
    }

    // MARK: - Helpers

    public static func formatWhenString(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "now"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    public static func snippet(from text: String, maxLength: Int = 120) -> String {
        let plain = plainText(from: text)
        guard !plain.isEmpty else { return "Ask anything" }
        if plain.count <= maxLength { return plain }
        return String(plain.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Strips common Markdown markers so list/chat previews stay readable plain text.
    public static func plainText(from markdown: String) -> String {
        var s = markdown
        // Fenced / inline code first so markers inside them are not reinterpreted.
        s = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"#{1,6}\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__)(.+?)\1"#, with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*|_)([^*_\n]+?)\1"#, with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^>\s?"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^[\t ]*[-*+]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^[\t ]*\d+\.\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^[-*_]{3,}\s*$"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func insertOrReplaceConversation(
        _ conversation: Conversation,
        tagsJSON: String,
        knowledgeScopeJSON: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO conversations (
                    id, title, when_string, snippet, tags_json, knowledge_scope_json,
                    active_skill_id, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    when_string = excluded.when_string,
                    snippet = excluded.snippet,
                    tags_json = excluded.tags_json,
                    knowledge_scope_json = excluded.knowledge_scope_json,
                    active_skill_id = excluded.active_skill_id,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                conversation.id,
                conversation.title,
                conversation.whenString,
                conversation.snippet,
                tagsJSON,
                knowledgeScopeJSON,
                conversation.activeSkillId,
                conversation.createdAt,
                conversation.updatedAt,
            ]
        )
    }

    private func insertOrReplaceMessage(
        _ message: Message,
        citationsJSON: String,
        externalToolJSON: String?,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO messages (
                    id, conversation_id, role, content, citations_json,
                    attached_image_name, local_tool_text, external_tool_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    content = excluded.content,
                    citations_json = excluded.citations_json,
                    attached_image_name = excluded.attached_image_name,
                    local_tool_text = excluded.local_tool_text,
                    external_tool_json = excluded.external_tool_json
                """,
            arguments: [
                message.id,
                message.conversationId,
                message.role.rawValue,
                message.content,
                citationsJSON,
                message.attachedImageName,
                message.localToolText,
                externalToolJSON,
                message.createdAt,
            ]
        )
    }

    private func conversation(from row: Row) throws -> Conversation {
        Conversation(
            id: row["id"],
            title: row["title"],
            whenString: row["when_string"],
            snippet: row["snippet"],
            tags: try decodeJSON(row["tags_json"] as String, as: [String].self) ?? [],
            activeKnowledgeScope: try decodeJSON(row["knowledge_scope_json"] as String, as: [String].self) ?? [],
            activeSkillId: row["active_skill_id"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private func message(from row: Row) throws -> Message {
        Message(
            id: row["id"],
            conversationId: row["conversation_id"],
            role: MessageRole(rawValue: row["role"]) ?? .user,
            content: row["content"],
            citations: try decodeJSON(row["citations_json"] as String?, as: [Citation].self) ?? [],
            attachedImageName: row["attached_image_name"],
            localToolText: row["local_tool_text"],
            externalToolData: try decodeJSON(row["external_tool_json"] as String?, as: ExternalToolExecution.self),
            createdAt: row["created_at"]
        )
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ChatStoreError.encodingFailed
        }
        return string
    }

    private func decodeJSON<T: Decodable>(_ string: String?, as type: T.Type) throws -> T? {
        guard let string, !string.isEmpty, let data = string.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
