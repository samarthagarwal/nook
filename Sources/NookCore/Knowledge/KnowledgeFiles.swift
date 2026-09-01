import Foundation

enum KnowledgeFiles {
    static var rootURL: URL {
        let directory = NookDatabase.directoryURL.appendingPathComponent("Knowledge", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func collectionDirectory(collectionId: String) throws -> URL {
        let directory = rootURL.appendingPathComponent(collectionId, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func storedFileURL(collectionId: String, fileName: String) throws -> URL {
        try collectionDirectory(collectionId: collectionId).appendingPathComponent(fileName)
    }

    static func copyImportedFile(from sourceURL: URL, collectionId: String, fileName: String) throws -> URL {
        let destinationURL = try storedFileURL(collectionId: collectionId, fileName: fileName)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }
}
