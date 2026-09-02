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

    static func removeStoredFile(atPath path: String?) {
        guard let path, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func removeCollectionDirectory(collectionId: String) {
        let directory = rootURL.appendingPathComponent(collectionId, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
