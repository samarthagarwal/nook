import Foundation
import GRDB

/// Wipes chats and knowledge from the local Nook database.
public enum NookLocalDataReset {
    public static func eraseAll() throws {
        try eraseAll(dbQueue: NookDatabase.makeQueue())
    }

    static func eraseAll(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM conversations")
            try db.execute(sql: "DELETE FROM knowledge_chunks_fts")
            try db.execute(sql: "DELETE FROM knowledge_chunks")
            try db.execute(sql: "DELETE FROM knowledge_documents")
            try db.execute(sql: "DELETE FROM knowledge_collections")
        }

        if FileManager.default.fileExists(atPath: KnowledgeFiles.rootURL.path) {
            try FileManager.default.removeItem(at: KnowledgeFiles.rootURL)
        }
    }
}
