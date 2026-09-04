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

    public func insertCard(_ item: MemoryItem, embedding: [Float]? = nil) throws -> Bool {
        let normalizedQuote = Self.normalizeQuote(item.quote)
        let normalizedSubject = Self.normalizeSubject(item.subject)
        guard !normalizedQuote.isEmpty, !normalizedSubject.isEmpty else { return false }
        let embeddingData: Data? = embedding.map { vector in
            vector.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        return try dbQueue.write { db in
            // Exact message+quote (including forgotten) — never recreate that pair.
            if try Row.fetchOne(
                db,
                sql: """
                    SELECT id FROM memory_cards
                    WHERE message_id = ? AND quote_normalized = ?
                    """,
                arguments: [item.messageId, normalizedQuote]
            ) != nil {
                return false
            }

            // Active card with same subject across chats — keep the first, don't fork.
            if try Row.fetchOne(
                db,
                sql: """
                    SELECT id FROM memory_cards
                    WHERE is_forgotten = 0
                      AND lower(trim(subject)) = ?
                    """,
                arguments: [normalizedSubject]
            ) != nil {
                return false
            }

            try db.execute(
                sql: """
                    INSERT INTO memory_cards (
                        id, subject, kind, quote, quote_normalized,
                        conversation_id, message_id, source_label, is_forgotten, created_at, provenance,
                        embedding
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    item.id,
                    item.subject,
                    item.kind,
                    item.quote,
                    normalizedQuote,
                    item.conversationId,
                    item.messageId,
                    item.source,
                    item.isForgotten,
                    item.createdAt,
                    item.provenance.rawValue,
                    embeddingData,
                ]
            )
            return true
        }
    }

    /// Returns the stored NLEmbedding vector for a memory card, or nil if not yet embedded
    /// (cards created before v8 migration, or when NLEmbedding was unavailable).
    public func fetchEmbedding(memoryId: String) -> [Float]? {
        let data: Data?
        do {
            data = try dbQueue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT embedding FROM memory_cards WHERE id = ?",
                    arguments: [memoryId]
                ) else {
                    return nil
                }
                return row["embedding"] as Data?
            }
        } catch {
            return nil
        }
        guard let data, !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else {
            return nil
        }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
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

    /// Returns raw message excerpt bodies matching a query, ordered by FTS rank.
    ///
    /// Resolution order:
    /// 1. FTS match on `memory_excerpts_fts` (fastest, rank-ordered).
    /// 2. Excerpts whose `message_id` belongs to a card that LIKE-matches the query
    ///    (handles conversations extracted before the current session, where cards exist
    ///    but the FTS index was seeded from a different code path).
    /// 3. LIKE search directly on excerpt bodies.
    public func fetchExcerpts(query: String, limit: Int = 6) throws -> [(body: String, conversationId: String, createdAt: Date)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. FTS
        if !trimmed.isEmpty, let ftsQuery = Self.ftsMatchQuery(from: trimmed) {
            let rows: [(body: String, conversationId: String, createdAt: Date)] = try dbQueue.read { db in
                let sql = """
                    SELECT e.body, e.conversation_id, e.created_at
                    FROM memory_excerpts_fts f
                    JOIN memory_excerpts e ON e.message_id = f.message_id
                    WHERE f MATCH ?
                    ORDER BY bm25(memory_excerpts_fts)
                    LIMIT ?
                    """
                return try Row.fetchAll(db, sql: sql, arguments: [ftsQuery, limit]).map {
                    (body: $0["body"] as String,
                     conversationId: $0["conversation_id"] as String,
                     createdAt: $0["created_at"] as Date)
                }
            }
            if !rows.isEmpty { return rows }
        }

        // 2. Token LIKE on excerpt bodies — OR across tokens so a partial match surfaces results.
        if !trimmed.isEmpty {
            let tokens = Self.contentTokens(from: trimmed)
            if !tokens.isEmpty {
                let rows: [(body: String, conversationId: String, createdAt: Date)] = try dbQueue.read { db in
                    let clauses = tokens.map { _ in "lower(body) LIKE ?" }.joined(separator: " OR ")
                    var args = StatementArguments()
                    for tok in tokens { args += ["%\(tok)%"] }
                    args += [limit]
                    let sql = """
                        SELECT body, conversation_id, created_at
                        FROM memory_excerpts
                        WHERE \(clauses)
                        ORDER BY created_at DESC
                        LIMIT ?
                        """
                    return try Row.fetchAll(db, sql: sql, arguments: args).map {
                        (body: $0["body"] as String,
                         conversationId: $0["conversation_id"] as String,
                         createdAt: $0["created_at"] as Date)
                    }
                }
                if !rows.isEmpty { return rows }
            }
        }

        return []
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

    public static func normalizeSubject(_ subject: String) -> String {
        subject
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

    public static func sourceLabel(
        conversationTitle: String,
        date: Date,
        provenance: MemoryProvenance = .user
    ) -> String {
        let title = conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.isEmpty ? "Chat" : title
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        let when = formatter.string(from: date)
        switch provenance {
        case .user:
            return "“\(displayTitle)” · \(when)"
        case .assistant:
            return "From a reply · “\(displayTitle)” · \(when)"
        }
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
        let provenanceRaw: String = (row["provenance"] as String?) ?? MemoryProvenance.user.rawValue
        return MemoryItem(
            id: row["id"],
            subject: row["subject"],
            kind: row["kind"],
            quote: row["quote"],
            source: row["source_label"],
            conversationId: row["conversation_id"],
            messageId: row["message_id"],
            provenance: MemoryProvenance(rawValue: provenanceRaw) ?? .user,
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
