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
        try seedDemoCorpusIfNeeded()
    }

    // MARK: - Collections

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
            }

            let maxLexical = lexicalScores.values.max() ?? 0

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
                let combined = (0.35 * normalizedLexical) + (0.65 * max(0, semanticScore))

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
                        normalizedLexical: normalizedLexical,
                        semanticScore: semanticScore
                    )
                )
            }

            return filterRelevantHits(ranked, limit: limit)
        }
    }

    /// Keeps only passages with a real lexical or semantic match — avoids showing every
    /// chunk in a small collection as a citation pill.
    private func filterRelevantHits(_ ranked: [RankedKnowledgeHit], limit: Int) -> [KnowledgeSearchHit] {
        let sorted = ranked.sorted { $0.combined > $1.combined }
        guard let top = sorted.first else { return [] }

        let minAbsoluteScore = 0.20
        let relativeToTopScore = 0.55
        let minSemanticWhenNoLexical = 0.42

        let filtered = sorted.filter { hit in
            guard hit.combined >= minAbsoluteScore else { return false }
            guard hit.combined >= top.combined * relativeToTopScore else { return false }
            if hit.normalizedLexical > 0 { return true }
            return hit.semanticScore >= minSemanticWhenNoLexical
        }

        return Array(filtered.prefix(limit)).map { hit in
            KnowledgeSearchHit(
                chunk: hit.chunk,
                documentName: hit.documentName,
                collectionName: hit.collectionName,
                score: hit.combined
            )
        }
    }

    // MARK: - Indexing helpers

    func chunkText(text: String, documentName: String, pageOrSection: String) -> [DocumentChunk] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let chunkSizeInWords = 450
        let overlapInWords = 60

        var generatedChunks: [DocumentChunk] = []
        var startIndex = 0

        while startIndex < words.count {
            let endIndex = min(startIndex + chunkSizeInWords, words.count)
            let chunkWords = words[startIndex..<endIndex]
            let chunkString = chunkWords.joined(separator: " ")

            generatedChunks.append(
                DocumentChunk(
                    documentId: documentName,
                    text: chunkString,
                    pageOrSection: pageOrSection
                )
            )

            if endIndex == words.count { break }
            startIndex += (chunkSizeInWords - overlapInWords)
        }

        if generatedChunks.isEmpty, !text.isEmpty {
            generatedChunks.append(
                DocumentChunk(documentId: documentName, text: text, pageOrSection: pageOrSection)
            )
        }

        return generatedChunks
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
        let embedding = KnowledgeEmbedder.embed(chunk.text)
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
            arguments: [chunk.id, chunk.text, chunk.pageOrSection]
        )
    }

    private func ftsMatchQuery(from query: String) -> String? {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\($0)*" }.joined(separator: " OR ")
    }

    private func seedDemoCorpusIfNeeded() throws {
        guard !AppPreferences.skipDemoKnowledgeSeed else { return }

        try dbQueue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM knowledge_collections") ?? 0
            guard count == 0 else { return }

            let now = Date()
            let projectAlphaId = "project-alpha"
            try db.execute(
                sql: """
                    INSERT INTO knowledge_collections (id, name, desc, state, created_at)
                    VALUES (?, 'Project Alpha', 'Spec, risk register, retro notes, vendor contract.', 'ready', ?)
                    """,
                arguments: [projectAlphaId, now]
            )

            let corpus: [(String, String, String, String)] = [
                (
                    "alpha-spec-v4.pdf",
                    "42 pages",
                    "p.18 Auth",
                    """
                    The specification names one primary identity provider (Okta Cloud) for all customer \
                    authentication flows. No secondary fallback provider is currently configured or provisioned \
                    for v1 launch. Review happens before submission in the spec workflow, not after.
                    """
                ),
                (
                    "risk-register.pdf",
                    "6 pages",
                    "p.3 Analytics",
                    """
                    Risk item #14: Analytics layer scope is unestimated and represents a high uncertainty \
                    factor for sprint delivery. Risk item #7: Single identity provider dependency with no \
                    documented fallback path for v1 launch.
                    """
                ),
                (
                    "risk-register.pdf",
                    "6 pages",
                    "p.5 Timeline",
                    """
                    Timeline risk: Integration milestone assumes vendor delivery in week six, but prior slips \
                    of two to three weeks have occurred in Q1 and Q2. Mitigation owner is unassigned for \
                    the identity provider fallback workstream.
                    """
                ),
                (
                    "retro-notes.md",
                    "2,100 words",
                    "Timeline",
                    """
                    Timeline slippage retro notes: Vendor delivery slipped 2.5 weeks in Q2, and 3 weeks in Q1. \
                    Schedule buffer must account for vendor delays. Team flagged analytics scope as still \
                    unestimated while remaining on the v1 milestone list.
                    """
                ),
                (
                    "vendor-contract.docx",
                    "18 pages",
                    "Section 4.2",
                    """
                    Vendor contract section 4.2 limits liability for delayed deliverables and excludes \
                    penalty clauses for slips shorter than ten business days. The integration dependency \
                    remains on a single approved vendor for authentication middleware.
                    """
                ),
            ]

            for entry in corpus {
                let chunks = chunkText(
                    text: entry.3,
                    documentName: entry.0,
                    pageOrSection: entry.2
                )
                let documentId = try upsertDocument(
                    collectionId: projectAlphaId,
                    name: entry.0,
                    meta: entry.1,
                    filePath: nil,
                    in: db
                )
                for chunk in chunks {
                    try insertChunk(chunk, documentId: documentId, in: db)
                }
            }
        }
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
                    page_or_section UNINDEXED,
                    tokenize='unicode61'
                )
                """)
        }
        migrator.registerMigration("v3_knowledge_file_path") { db in
            try db.alter(table: "knowledge_documents") { table in
                table.add(column: "file_path", .text)
            }
        }
        try migrator.migrate(queue)
        return try KnowledgeStore(dbQueue: queue)
    }
}
