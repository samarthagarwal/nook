import Foundation

public enum KnowledgeImportError: LocalizedError {
    case emptyDocument
    case unreadableFile
    case unsupportedType

    public var errorDescription: String? {
        switch self {
        case .emptyDocument:
            return "The file has no text to index."
        case .unreadableFile:
            return "Could not read the file."
        case .unsupportedType:
            return "Only Markdown (.md) files are supported for now."
        }
    }
}
