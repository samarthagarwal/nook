import Foundation
import GRDB

public enum MemoryStoreError: Error {
    case encodingFailed
}

/// Persists derived memory cards and searchable user-message excerpts.
public final class MemoryStore: @unchecked Sendable {
    public static let shared: MemoryStore = {
        do {
            return try MemoryStore()
        } catch {
            fatalError("Failed to open memory database: \(error)")
        }
    }()

    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue? = nil) throws {
        self.dbQueue = try dbQueue ?? NookDatabase.makeQueue()
    }

    public static func makeForTests() throws -> MemoryStore {
        try MemoryStore(dbQueue: NookDatabase.makeTestQueue())
    }

    // MARK: - Cards

    public func fetchActiveCards(limit: Int? = nil) throws -> [MemoryItem] {
        try dbQueue.read { db in
            let sql: String
            let arguments: StatementArguments
            if let limit {
                sql = """
                    SELECT * FROM memory_cards
                    WHERE is_forgotten = 0
                    ORDER BY created_at DESC
                    LIMIT ?
                    """
                arguments = [limit]
            } else {
                sql = """
                    SELECT * FROM memory_cards
                    WHERE is_forgotten = 0
                    ORDER BY created_at DESC
                    """
                arguments = []
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map { card(from: $0) }
        }
    }

    public func searchCards(query: String, limit: Int = 40) throws -> [MemoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try fetchActiveCards(limit: limit)
        }
        let lower = trimmed.lowercased()
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM memory_cards
                    WHERE is_forgotten = 0
                      AND (
                        lower(subject) LIKE ? OR
                        lower(kind) LIKE ? OR
                        lower(quote) LIKE ? OR
                        lower(source_label) LIKE ?
                      )
                    ORDER BY created_at DESC
                    LIMIT ?
                    """,
                arguments: ["%\(lower)%", "%\(lower)%", "%\(lower)%", "%\(lower)%", limit]
            )
            return rows.map { card(from: $0) }
        }
    }

    /// Lexical retrieval for chat injection: cards first, then excerpt-backed cards.
    public func retrieveForQuery(_ query: String, maxCards: Int = 3) throws -> [MemoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var ranked: [String: (item: MemoryItem, score: Double)] = [:]

        let cardHits = try searchCards(query: trimmed, limit: 20)
        for (index, item) in cardHits.enumerated() {
            let score = 100.0 - Double(index)
            ranked[item.id] = (item, score)
        }

        if let ftsQuery = Self.ftsMatchQuery(from: trimmed) {
            let excerptMessageIds: [String] = try dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT message_id, bm25(memory_excerpts_fts) AS rank
                        FROM memory_excerpts_fts
                        WHERE memory_excerpts_fts MATCH ?
                        ORDER BY rank
                        LIMIT 20
                        """,
                    arguments: [ftsQuery]
                )
                return rows.map { $0["message_id"] as String }
            }
            if !excerptMessageIds.isEmpty {
                let cards = try cardsForMessageIds(excerptMessageIds)
                for (index, item) in cards.enumerated() {
                    let score = 50.0 - Double(index)
                    if let existing = ranked[item.id] {
                        ranked[item.id] = (item, max(existing.score, score))
                    } else {
                        ranked[item.id] = (item, score)
                    }
                }
            }
        }

        return ranked.values
            .sorted { $0.score > $1.score }
            .prefix(maxCards)
            .map(\.item)
    }

    public func insertCard(_ item: MemoryItem) throws -> Bool {
        let normalized = Self.normalizeQuote(item.quote)
        guard !normalized.isEmpty else { return false }
        return try dbQueue.write { db in
            // Respect soft-forget: existing row (forgotten or not) blocks insert.
            if try Row.fetchOne(
                db,
                sql: """
                    SELECT id FROM memory_cards
                    WHERE message_id = ? AND quote_normalized = ?
                    """,
                arguments: [item.messageId, normalized]
            ) != nil {
                return false
            }
            try db.execute(
                sql: """
                    INSERT INTO memory_cards (
                        id, subject, kind, quote, quote_normalized,
                        conversation_id, message_id, source_label, is_forgotten, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    item.id,
                    item.subject,
                    item.kind,
                    item.quote,
                    normalized,
                    item.conversationId,
                    item.messageId,
                    item.source,
                    item.isForgotten,
                    item.createdAt,
                ]
            )
            return true
        }
    }

    public func forget(memoryId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE memory_cards SET is_forgotten = 1 WHERE id = ?",
                arguments: [memoryId]
            )
        }
    }

    // MARK: - Excerpts + watermark

    public func upsertExcerpt(messageId: String, conversationId: String, body: String, createdAt: Date = Date()) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO memory_excerpts (message_id, conversation_id, body, created_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(message_id) DO UPDATE SET
                        body = excluded.body,
                        conversation_id = excluded.conversation_id
                    """,
                arguments: [messageId, conversationId, trimmed, createdAt]
            )
            try db.execute(
                sql: "DELETE FROM memory_excerpts_fts WHERE message_id = ?",
                arguments: [messageId]
            )
            try db.execute(
                sql: """
                    INSERT INTO memory_excerpts_fts (message_id, body)
                    VALUES (?, ?)
                    """,
                arguments: [messageId, trimmed]
            )
        }
    }

    public func hasExtracted(messageId: String) throws -> Bool {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM memory_extracted_messages WHERE message_id = ?",
                arguments: [messageId]
            ) != nil
        }
    }

    public func markExtracted(messageId: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO memory_extracted_messages (message_id, extracted_at)
                    VALUES (?, ?)
                    ON CONFLICT(message_id) DO UPDATE SET extracted_at = excluded.extracted_at
                    """,
                arguments: [messageId, date]
            )
        }
    }

    // MARK: - Helpers

    public static func normalizeQuote(_ quote: String) -> String {
        quote
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `quote` appears in `message` after whitespace/case normalization.
    public static func quoteIsVerbatim(quote: String, in message: String) -> Bool {
        let q = normalizeQuote(quote)
        let m = normalizeQuote(message)
        guard !q.isEmpty, !m.isEmpty else { return false }
        return m.contains(q)
    }

    public static func sourceLabel(conversationTitle: String, date: Date) -> String {
        let title = conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.isEmpty ? "Chat" : title
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return "“\(displayTitle)” · \(formatter.string(from: date))"
    }

    private func cardsForMessageIds(_ messageIds: [String]) throws -> [MemoryItem] {
        guard !messageIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            var items: [MemoryItem] = []
            for id in messageIds {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM memory_cards
                        WHERE message_id = ? AND is_forgotten = 0
                        """,
                    arguments: [id]
                )
                items.append(contentsOf: rows.map { card(from: $0) })
            }
            return items
        }
    }

    private func card(from row: Row) -> MemoryItem {
        MemoryItem(
            id: row["id"],
            subject: row["subject"],
            kind: row["kind"],
            quote: row["quote"],
            source: row["source_label"],
            conversationId: row["conversation_id"],
            messageId: row["message_id"],
            isForgotten: row["is_forgotten"],
            createdAt: row["created_at"]
        )
    }

    private static func ftsMatchQuery(from query: String) -> String? {
        let tokens = contentTokens(from: query)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\($0)*" }.joined(separator: " OR ")
    }

    private static func contentTokens(from text: String) -> [String] {
        let folded = text.lowercased()
        let parts = folded.split { !$0.isLetter && !$0.isNumber }
        return parts
            .map(String.init)
            .filter { $0.count >= 2 }
            .prefix(12)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
    }
}
