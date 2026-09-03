import Foundation
import GRDB

public enum NookDatabase {
    public static let fileName = "nook.sqlite"

    public static var directoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent("Nook", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static var databaseURL: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    /// SQLite file sizes on disk (main DB + WAL sidecars).
    public static func fileBytesOnDisk() -> Int64 {
        let urls = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
        return urls.reduce(Int64(0)) { partial, url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize
            else {
                return partial
            }
            return partial + Int64(size)
        }
    }

    static func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try migrate(queue)
        return queue
    }

    private static func migrate(_ dbQueue: DatabaseQueue) throws {
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
                table.column("conversation_id", .text)
                    .notNull()
                    .references("conversations", onDelete: .cascade)
                table.column("role", .text).notNull()
                table.column("content", .text).notNull().defaults(to: "")
                table.column("citations_json", .text)
                table.column("attached_image_name", .text)
                table.column("local_tool_text", .text)
                table.column("external_tool_json", .text)
                table.column("created_at", .datetime).notNull()
            }

            try db.create(index: "messages_by_conversation", on: "messages", columns: ["conversation_id", "created_at"])
            try db.create(index: "conversations_by_updated_at", on: "conversations", columns: ["updated_at"])
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
                table.column("collection_id", .text)
                    .notNull()
                    .references("knowledge_collections", onDelete: .cascade)
                table.column("name", .text).notNull()
                table.column("meta", .text).notNull().defaults(to: "")
                table.column("status", .text).notNull().defaults(to: "Indexed")
                table.column("created_at", .datetime).notNull()
            }

            try db.create(table: "knowledge_chunks") { table in
                table.column("id", .text).primaryKey()
                table.column("document_id", .text)
                    .notNull()
                    .references("knowledge_documents", onDelete: .cascade)
                table.column("text", .text).notNull()
                table.column("page_or_section", .text).notNull()
                table.column("embedding", .blob)
                table.column("created_at", .datetime).notNull()
            }

            try db.create(index: "knowledge_chunks_by_document", on: "knowledge_chunks", columns: ["document_id"])

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

        migrator.registerMigration("v5_memory") { db in
            try db.create(table: "memory_cards") { table in
                table.column("id", .text).primaryKey()
                table.column("subject", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("quote", .text).notNull()
                table.column("quote_normalized", .text).notNull()
                table.column("conversation_id", .text)
                    .notNull()
                    .references("conversations", onDelete: .cascade)
                table.column("message_id", .text)
                    .notNull()
                    .references("messages", onDelete: .cascade)
                table.column("source_label", .text).notNull()
                table.column("is_forgotten", .boolean).notNull().defaults(to: false)
                table.column("created_at", .datetime).notNull()
                table.uniqueKey(["message_id", "quote_normalized"])
            }

            try db.create(index: "memory_cards_by_conversation", on: "memory_cards", columns: ["conversation_id"])
            try db.create(index: "memory_cards_active", on: "memory_cards", columns: ["is_forgotten", "created_at"])

            try db.create(table: "memory_excerpts") { table in
                table.column("message_id", .text).primaryKey()
                    .references("messages", onDelete: .cascade)
                table.column("conversation_id", .text)
                    .notNull()
                    .references("conversations", onDelete: .cascade)
                table.column("body", .text).notNull()
                table.column("created_at", .datetime).notNull()
            }

            try db.execute(sql: """
                CREATE VIRTUAL TABLE memory_excerpts_fts USING fts5(
                    message_id UNINDEXED,
                    body,
                    tokenize='unicode61'
                )
                """)

            try db.create(table: "memory_extracted_messages") { table in
                table.column("message_id", .text).primaryKey()
                    .references("messages", onDelete: .cascade)
                table.column("extracted_at", .datetime).notNull()
            }
        }

        migrator.registerMigration("v6_memory_provenance") { db in
            try db.alter(table: "memory_cards") { table in
                table.add(column: "provenance", .text).notNull().defaults(to: MemoryProvenance.user.rawValue)
            }
        }

        migrator.registerMigration("v7_conversation_active_skill") { db in
            try db.alter(table: "conversations") { table in
                table.add(column: "active_skill_id", .text)
            }
        }

        try migrator.migrate(dbQueue)
    }

    /// Temp SQLite with full migrations — for unit tests that need chats + memory (+ knowledge schema).
    public static func makeTestQueue() throws -> DatabaseQueue {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nook-test-\(UUID().uuidString).sqlite")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try migrate(queue)
        return queue
    }
}
