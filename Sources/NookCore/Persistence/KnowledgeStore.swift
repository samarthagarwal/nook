import Foundation
import GRDB

public struct KnowledgeSearchHit: Sendable {
    public let chunk: DocumentChunk
    public let documentName: String
    public let collectionName: String
    public let score: Double
}

private struct RankedKnowledgeHit {
    let chunk: DocumentChunk
    let documentName: String
    let collectionName: String
    let combined: Double
    let normalizedLexical: Double
    let semanticScore: Double
}

/// Local SQLite store for Knowledge collections, documents, chunks, and hybrid search.
public final class KnowledgeStore: @unchecked Sendable {
    public static let shared: KnowledgeStore = {
        do {
            return try KnowledgeStore()
        } catch {
            fatalError("Failed to open knowledge database: \(error)")
        }
    }()

    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue? = nil) throws {
        self.dbQueue = try dbQueue ?? NookDatabase.makeQueue()
    }

    // MARK: - Collections

    public func createCollection(
        id: String = UUID().uuidString,
        name: String,
        desc: String = ""
    ) throws -> KnowledgeCollection {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw KnowledgeImportError.emptyDocument
        }
        let now = Date()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO knowledge_collections (id, name, desc, state, created_at)
                    VALUES (?, ?, ?, 'ready', ?)
                    """,
                arguments: [id, trimmedName, trimmedDesc, now]
            )
        }
        return KnowledgeCollection(
            id: id,
            name: trimmedName,
            count: "0 docs",
            desc: trimmedDesc,
            status: "Indexed · 0 passages",
            state: .ready
        )
    }

    public func deleteCollection(id: String) throws {
        try dbQueue.write { db in
            let documentIds = try String.fetchAll(
                db,
                sql: "SELECT id FROM knowledge_documents WHERE collection_id = ?",
                arguments: [id]
            )
            for documentId in documentIds {
                try deleteChunks(forDocumentId: documentId, in: db)
            }
            try db.execute(
                sql: "DELETE FROM knowledge_documents WHERE collection_id = ?",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM knowledge_collections WHERE id = ?",
                arguments: [id]
            )
        }
        KnowledgeFiles.removeCollectionDirectory(collectionId: id)
    }

    public func deleteDocument(id: String) throws {
        let filePath: String? = try dbQueue.write { db in
            let path = try String.fetchOne(
                db,
                sql: "SELECT file_path FROM knowledge_documents WHERE id = ?",
                arguments: [id]
            )
            try deleteChunks(forDocumentId: id, in: db)
            try db.execute(
                sql: "DELETE FROM knowledge_documents WHERE id = ?",
                arguments: [id]
            )
            return path
        }
        KnowledgeFiles.removeStoredFile(atPath: filePath)
    }

    public func fetchCollections() throws -> [KnowledgeCollection] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.*,
                        (SELECT COUNT(*) FROM knowledge_documents d WHERE d.collection_id = c.id) AS doc_count,
                        (SELECT COUNT(*) FROM knowledge_chunks ch
                            JOIN knowledge_documents d ON d.id = ch.document_id
                            WHERE d.collection_id = c.id) AS chunk_count
                    FROM knowledge_collections c
                    ORDER BY c.name COLLATE NOCASE ASC
                    """
            )
            return rows.map { row in
                let docCount = row["doc_count"] as Int? ?? 0
                let chunkCount = row["chunk_count"] as Int? ?? 0
                let state = CollectionState(rawValue: row["state"] as String? ?? "ready") ?? .ready
                return KnowledgeCollection(
                    id: row["id"],
                    name: row["name"],
                    count: docCount == 1 ? "1 doc" : "\(docCount) docs",
                    desc: row["desc"],
                    status: "Indexed · \(chunkCount) passages",
                    state: state
                )
            }
        }
    }

    public func fetchDocuments(collectionId: String) throws -> [KnowledgeDocument] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM knowledge_documents
                    WHERE collection_id = ?
                    ORDER BY name COLLATE NOCASE ASC
                    """,
                arguments: [collectionId]
            )
            return rows.map { row in
                KnowledgeDocument(
                    id: row["id"],
                    collectionId: row["collection_id"],
                    name: row["name"],
                    meta: row["meta"],
                    status: row["status"]
                )
            }
        }
    }

    public func indexDocumentText(
        collectionId: String,
        documentName: String,
        meta: String,
        pageOrSection: String,
        text: String
    ) throws {
        _ = try indexDocument(
            collectionId: collectionId,
            documentName: documentName,
            meta: meta,
            filePath: nil,
            sections: [(pageOrSection: pageOrSection, text: text)]
        )
    }

    public func indexDocument(
        collectionId: String,
        documentName: String,
        meta: String,
        filePath: String?,
        sections: [(pageOrSection: String, text: String)]
    ) throws -> String {
        guard !sections.isEmpty else { throw KnowledgeImportError.emptyDocument }

        return try dbQueue.write { db in
            let documentId = try upsertDocument(
                collectionId: collectionId,
                name: documentName,
                meta: meta,
                filePath: filePath,
                in: db
            )
            try deleteChunks(forDocumentId: documentId, in: db)
            for section in sections {
                let chunks = chunkText(
                    text: section.text,
                    documentName: documentName,
                    pageOrSection: section.pageOrSection
                )
                for chunk in chunks {
                    try insertChunk(chunk, documentId: documentId, in: db)
                }
            }
            return documentId
        }
    }

    /// Copies a Markdown file into app storage, splits on headings, chunks, and indexes.
    public func importMarkdownFile(from sourceURL: URL, collectionId: String) throws -> KnowledgeDocument {
        guard sourceURL.pathExtension.lowercased() == "md" else {
            throw KnowledgeImportError.unsupportedType
        }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileName = sourceURL.lastPathComponent
        let destURL = try KnowledgeFiles.copyImportedFile(
            from: sourceURL,
            collectionId: collectionId,
            fileName: fileName
        )

        let markdown: String
        do {
            markdown = try String(contentsOf: destURL, encoding: .utf8)
        } catch {
            throw KnowledgeImportError.unreadableFile
        }

        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KnowledgeImportError.emptyDocument }

        let sections = MarkdownSectionParser.sections(from: trimmed)
        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        let meta = wordCount == 1 ? "1 word" : "\(wordCount) words"

        let documentId = try indexDocument(
            collectionId: collectionId,
            documentName: fileName,
            meta: meta,
            filePath: destURL.path,
            sections: sections
        )

        return KnowledgeDocument(
            id: documentId,
            collectionId: collectionId,
            name: fileName,
            meta: meta,
            status: "Indexed"
        )
    }

    /// Hybrid lexical + embedding retrieval scoped to collection display names.
    public func search(
        query: String,
        scopedToCollections collectionNames: [String],
        limit: Int = 5
    ) throws -> [KnowledgeSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let scope = collectionNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !scope.isEmpty else { return [] }

        let queryEmbedding = KnowledgeEmbedder.embed(trimmed)
        let ftsQuery = ftsMatchQuery(from: trimmed)
        #if DEBUG
        print(
            "[KnowledgeStore] search query=\"\(trimmed)\" scope=\(scope) " +
            "fts=\(ftsQuery ?? "nil") embed=\(queryEmbedding == nil ? "nil" : "ok")"
        )
        #endif

        return try dbQueue.read { db in
            let placeholders = Array(repeating: "?", count: scope.count).joined(separator: ", ")
            let scopeArgs = StatementArguments(scope)

            let candidateRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT ch.id AS chunk_id,
                           ch.text,
                           ch.page_or_section,
                           ch.embedding,
                           d.name AS document_name,
                           c.name AS collection_name
                    FROM knowledge_chunks ch
                    JOIN knowledge_documents d ON d.id = ch.document_id
                    JOIN knowledge_collections c ON c.id = d.collection_id
                    WHERE c.name IN (\(placeholders))
                    """,
                arguments: scopeArgs
            )
            #if DEBUG
            print("[KnowledgeStore] candidates in scope: \(candidateRows.count)")
            #endif

            var lexicalScores: [String: Double] = [:]
            if let ftsQuery {
                let ftsRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT chunk_id, bm25(knowledge_chunks_fts) AS rank
                        FROM knowledge_chunks_fts
                        WHERE knowledge_chunks_fts MATCH ?
                        ORDER BY rank
                        LIMIT 40
                        """,
                    arguments: [ftsQuery]
                )
                for row in ftsRows {
                    let chunkId: String = row["chunk_id"]
                    let rank: Double = row["rank"]
                    lexicalScores[chunkId] = max(0, -rank)
                }
                #if DEBUG
                print("[KnowledgeStore] FTS hits: \(ftsRows.count) (raw bm25→score on \(lexicalScores.count) chunks)")
                #endif
            } else {
                #if DEBUG
                print("[KnowledgeStore] FTS skipped (no usable tokens)")
                #endif
            }

            let maxLexical = lexicalScores.values.max() ?? 0
            let contentTokens = Self.contentTokens(from: trimmed)

            var ranked: [RankedKnowledgeHit] = []
            for row in candidateRows {
                let chunkId: String = row["chunk_id"]
                let text: String = row["text"]
                let pageOrSection: String = row["page_or_section"]
                let documentName: String = row["document_name"]
                let collectionName: String = row["collection_name"]
                let embeddingData: Data? = row["embedding"]

                var semanticScore: Double = 0
                if let queryEmbedding,
                   let embeddingData,
                   let vector = KnowledgeEmbedder.vector(from: embeddingData) {
                    semanticScore = Double(KnowledgeEmbedder.cosineSimilarity(queryEmbedding, vector))
                }

                let lexicalScore = lexicalScores[chunkId] ?? 0
                let normalizedLexical = maxLexical > 0 ? lexicalScore / maxLexical : 0
                let titleScore = Self.titleMatchScore(section: pageOrSection, tokens: contentTokens)
                // Title overlap pulls exact-heading hits above body-only BM25 noise.
                let combined =
                    (0.30 * normalizedLexical) +
                    (0.55 * max(0, semanticScore)) +
                    (0.30 * titleScore)

                ranked.append(
                    RankedKnowledgeHit(
                        chunk: DocumentChunk(
                            id: chunkId,
                            documentId: documentName,
                            text: text,
                            pageOrSection: pageOrSection
                        ),
                        documentName: documentName,
                        collectionName: collectionName,
                        combined: combined,
                        normalizedLexical: max(normalizedLexical, titleScore),
                        semanticScore: semanticScore
                    )
                )
            }

            #if DEBUG
            let sortedPreview = ranked.sorted { $0.combined > $1.combined }.prefix(8)
            for (index, hit) in sortedPreview.enumerated() {
                let preview = hit.chunk.text
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(80)
                print(
                    String(
                        format: "[KnowledgeStore] pre-filter #%d comb=%.3f lex=%.3f sem=%.3f %@ · %@ | %@…",
                        index + 1,
                        hit.combined,
                        hit.normalizedLexical,
                        hit.semanticScore,
                        hit.documentName,
                        hit.chunk.pageOrSection,
                        String(preview)
                    )
                )
            }
            #endif

            let kept = filterRelevantHits(ranked, limit: limit)
            #if DEBUG
            print("[KnowledgeStore] post-filter kept \(kept.count)/\(min(limit, ranked.count)) (of \(ranked.count) ranked)")
            for (index, hit) in kept.enumerated() {
                print(
                    String(
                        format: "[KnowledgeStore] kept #%d score=%.3f %@ · %@",
                        index + 1,
                        hit.score,
                        hit.documentName,
                        hit.chunk.pageOrSection
                    )
                )
            }
            #endif
            return kept
        }
    }

    /// Keeps only passages with a real lexical or semantic match — avoids showing every
    /// chunk in a small collection as a citation pill (e.g. "capital of France" vs project docs).
    private func filterRelevantHits(_ ranked: [RankedKnowledgeHit], limit: Int) -> [KnowledgeSearchHit] {
        let sorted = ranked.sorted { $0.combined > $1.combined }
        guard let top = sorted.first else { return [] }

        // Require a clear match. Pure embedding noise on short general-knowledge queries
        // often lands ~0.2–0.35 against unrelated project text.
        let minAbsoluteScore = 0.28
        let relativeToTopScore = 0.55
        let minSemanticWhenNoLexical = 0.55
        // Strong FTS alone is enough — NLEmbedding often underscores exact section matches
        // (e.g. "long context" → "Long-context vs RAG" with sem≈0).
        let minLexicalKeep = 0.45

        let filtered = sorted.filter { hit in
            let strongLexical = hit.normalizedLexical >= minLexicalKeep
            if strongLexical {
                return true
            }

            let passAbsolute = hit.combined >= minAbsoluteScore
            let passRelative = hit.combined >= top.combined * relativeToTopScore
            let passMixed = hit.normalizedLexical > 0.15 && hit.semanticScore >= 0.30
            let passSemantic = hit.semanticScore >= minSemanticWhenNoLexical
            let keep = passAbsolute && passRelative && (passMixed || passSemantic)
            #if DEBUG
            if !keep, hit.combined >= top.combined * 0.4 || hit.normalizedLexical >= 0.3 {
                print(
                    String(
                        format: "[KnowledgeStore] drop %@ · %@ comb=%.3f lex=%.3f (abs:%@ rel:%@ mix:%@ sem:%@)",
                        hit.documentName,
                        hit.chunk.pageOrSection,
                        hit.combined,
                        hit.normalizedLexical,
                        passAbsolute ? "y" : "n",
                        passRelative ? "y" : "n",
                        passMixed ? "y" : "n",
                        passSemantic ? "y" : "n"
                    )
                )
            }
            #endif
            return keep
        }

        // Prefer lexical-strong hits when re-sorting for the prompt (exact section titles).
        let ordered = filtered.sorted { lhs, rhs in
            if abs(lhs.normalizedLexical - rhs.normalizedLexical) > 0.08 {
                return lhs.normalizedLexical > rhs.normalizedLexical
            }
            return lhs.combined > rhs.combined
        }

        return Array(ordered.prefix(limit)).map { hit in
            KnowledgeSearchHit(
                chunk: hit.chunk,
                documentName: hit.documentName,
                collectionName: hit.collectionName,
                score: hit.combined
            )
        }
    }

    // MARK: - Indexing helpers

    /// Heading sections are split by the Markdown parser; within each section we pack
    /// blank-line paragraphs up to an embedding-friendly word budget (not fixed word windows).
    func chunkText(text: String, documentName: String, pageOrSection: String) -> [DocumentChunk] {
        let passages = MarkdownParagraphChunker.chunk(text: text)
        if passages.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [
                DocumentChunk(documentId: documentName, text: text, pageOrSection: pageOrSection)
            ]
        }
        return passages.map { passage in
            DocumentChunk(
                documentId: documentName,
                text: passage,
                pageOrSection: pageOrSection
            )
        }
    }

    private func upsertDocument(
        collectionId: String,
        name: String,
        meta: String,
        filePath: String?,
        in db: Database
    ) throws -> String {
        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id FROM knowledge_documents
                WHERE collection_id = ? AND name = ?
                """,
            arguments: [collectionId, name]
        ) {
            let documentId: String = row["id"]
            try db.execute(
                sql: """
                    UPDATE knowledge_documents
                    SET meta = ?, status = 'Indexed', file_path = COALESCE(?, file_path)
                    WHERE id = ?
                    """,
                arguments: [meta, filePath, documentId]
            )
            return documentId
        }

        let documentId = UUID().uuidString
        try db.execute(
            sql: """
                INSERT INTO knowledge_documents (id, collection_id, name, meta, status, file_path, created_at)
                VALUES (?, ?, ?, ?, 'Indexed', ?, ?)
                """,
            arguments: [documentId, collectionId, name, meta, filePath, Date()]
        )
        return documentId
    }

    private func deleteChunks(forDocumentId documentId: String, in db: Database) throws {
        let chunkIds = try String.fetchAll(
            db,
            sql: "SELECT id FROM knowledge_chunks WHERE document_id = ?",
            arguments: [documentId]
        )
        for chunkId in chunkIds {
            try db.execute(
                sql: "DELETE FROM knowledge_chunks_fts WHERE chunk_id = ?",
                arguments: [chunkId]
            )
        }
        try db.execute(
            sql: "DELETE FROM knowledge_chunks WHERE document_id = ?",
            arguments: [documentId]
        )
    }

    private func insertChunk(_ chunk: DocumentChunk, documentId: String, in db: Database) throws {
        let indexedText = Self.ftsDocument(text: chunk.text, pageOrSection: chunk.pageOrSection)
        let embedding = KnowledgeEmbedder.embed(indexedText)
        let embeddingData = embedding.map(KnowledgeEmbedder.embeddingData(from:))
        try db.execute(
            sql: """
                INSERT INTO knowledge_chunks (id, document_id, text, page_or_section, embedding, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [chunk.id, documentId, chunk.text, chunk.pageOrSection, embeddingData, Date()]
        )
        try db.execute(
            sql: """
                INSERT INTO knowledge_chunks_fts (chunk_id, text, page_or_section)
                VALUES (?, ?, ?)
                """,
            arguments: [chunk.id, indexedText, chunk.pageOrSection]
        )
    }

    private func ftsMatchQuery(from query: String) -> String? {
        let tokens = Self.contentTokens(from: query)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\($0)*" }.joined(separator: " OR ")
    }

    private static let ftsStopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "in", "on", "at", "to", "for",
        "of", "as", "is", "are", "was", "were", "be", "been", "being",
        "what", "which", "who", "whom", "this", "that", "these", "those",
        "how", "why", "when", "where", "do", "does", "did", "can", "could",
        "would", "should", "with", "from", "about",
    ]

    static func contentTokens(from query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 && !ftsStopwords.contains($0) }
    }

    static func titleMatchScore(section: String, tokens: [String]) -> Double {
        guard !tokens.isEmpty else { return 0 }
        let lower = section.lowercased()
        let sectionTokens = lower
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let hits = tokens.filter { token in
            lower.contains(token)
                || sectionTokens.contains { $0.hasPrefix(token) || token.hasPrefix($0) }
        }.count
        return Double(hits) / Double(tokens.count)
    }
}

extension KnowledgeStore {
    public static func makeForTests() throws -> KnowledgeStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nook-knowledge-test-\(UUID().uuidString).sqlite")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_chats") { db in
            try db.create(table: "conversations") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("when_string", .text).notNull()
                table.column("snippet", .text).notNull()
                table.column("tags_json", .text).notNull().defaults(to: "[]")
                table.column("knowledge_scope_json", .text).notNull().defaults(to: "[]")
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(table: "messages") { table in
                table.column("id", .text).primaryKey()
                table.column("conversation_id", .text).notNull().references("conversations", onDelete: .cascade)
                table.column("role", .text).notNull()
                table.column("content", .text).notNull().defaults(to: "")
                table.column("citations_json", .text)
                table.column("attached_image_name", .text)
                table.column("local_tool_text", .text)
                table.column("external_tool_json", .text)
                table.column("created_at", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2_knowledge") { db in
            try db.create(table: "knowledge_collections") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("desc", .text).notNull().defaults(to: "")
                table.column("state", .text).notNull().defaults(to: "ready")
                table.column("created_at", .datetime).notNull()
            }
            try db.create(table: "knowledge_documents") { table in
                table.column("id", .text).primaryKey()
                table.column("collection_id", .text).notNull().references("knowledge_collections", onDelete: .cascade)
                table.column("name", .text).notNull()
                table.column("meta", .text).notNull().defaults(to: "")
                table.column("status", .text).notNull().defaults(to: "Indexed")
                table.column("created_at", .datetime).notNull()
            }
            try db.create(table: "knowledge_chunks") { table in
                table.column("id", .text).primaryKey()
                table.column("document_id", .text).notNull().references("knowledge_documents", onDelete: .cascade)
                table.column("text", .text).notNull()
                table.column("page_or_section", .text).notNull()
                table.column("embedding", .blob)
                table.column("created_at", .datetime).notNull()
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE knowledge_chunks_fts USING fts5(
                    chunk_id UNINDEXED,
                    text,
                    page_or_section,
                    tokenize='unicode61'
                )
                """)
        }
        migrator.registerMigration("v3_knowledge_file_path") { db in
            try db.alter(table: "knowledge_documents") { table in
                table.add(column: "file_path", .text)
            }
        }
        migrator.registerMigration("v4_knowledge_fts_index_sections") { db in
            try KnowledgeStore.rebuildFTSIndexingSectionTitles(in: db)
        }
        try migrator.migrate(queue)
        return try KnowledgeStore(dbQueue: queue)
    }

    /// Recreate FTS so section titles are searchable (headings were previously UNINDEXED).
    static func rebuildFTSIndexingSectionTitles(in db: Database) throws {
        try db.execute(sql: "DROP TABLE IF EXISTS knowledge_chunks_fts")
        try db.execute(sql: """
            CREATE VIRTUAL TABLE knowledge_chunks_fts USING fts5(
                chunk_id UNINDEXED,
                text,
                page_or_section,
                tokenize='unicode61'
            )
            """)
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, text, page_or_section FROM knowledge_chunks"
        )
        for row in rows {
            let id: String = row["id"]
            let text: String = row["text"]
            let section: String = row["page_or_section"]
            let ftsText = Self.ftsDocument(text: text, pageOrSection: section)
            try db.execute(
                sql: """
                    INSERT INTO knowledge_chunks_fts (chunk_id, text, page_or_section)
                    VALUES (?, ?, ?)
                    """,
                arguments: [id, ftsText, section]
            )
        }
        #if DEBUG
        print("[KnowledgeStore] Rebuilt FTS with indexed section titles (\(rows.count) chunks)")
        #endif
    }

    static func ftsDocument(text: String, pageOrSection: String) -> String {
        let section = pageOrSection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !section.isEmpty else { return text }
        return section + "\n" + text
    }
}
