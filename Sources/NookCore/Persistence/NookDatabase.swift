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

        try migrator.migrate(dbQueue)
    }
}
