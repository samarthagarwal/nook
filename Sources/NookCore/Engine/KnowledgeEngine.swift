import Foundation

public actor KnowledgeEngine {
    private let store: KnowledgeStore

    public init(store: KnowledgeStore = .shared) {
        self.store = store
    }

    public func getCollections() -> [KnowledgeCollection] {
        (try? store.fetchCollections()) ?? []
    }

    public func getDocuments(forCollectionId collectionId: String) -> [KnowledgeDocument] {
        (try? store.fetchDocuments(collectionId: collectionId)) ?? []
    }

    public func importMarkdown(from url: URL, collectionId: String) throws -> KnowledgeDocument {
        try store.importMarkdownFile(from: url, collectionId: collectionId)
    }

    /// Chunks arbitrary text into 400-600 token pieces with 50-100 token overlap.
    public func chunkText(text: String, documentId: String, pageOrSection: String) -> [DocumentChunk] {
        store.chunkText(text: text, documentName: documentId, pageOrSection: pageOrSection)
    }

    /// Search Knowledge scoped to selected collection names (hybrid FTS + embeddings).
    public func search(
        query: String,
        scopedToCollections: [String]
    ) -> (chunks: [DocumentChunk], citations: [Citation]) {
        guard let hits = try? store.search(query: query, scopedToCollections: scopedToCollections),
              !hits.isEmpty else {
            return ([], [])
        }

        let chunks = hits.map(\.chunk)
        let citations = hits.enumerated().map { index, hit in
            Citation(
                label: "\(hit.documentName) · \(hit.chunk.pageOrSection)",
                sourceDocument: hit.documentName,
                pageOrSection: hit.chunk.pageOrSection,
                passage: hit.chunk.text,
                surroundingContext: "Retrieved from \(hit.collectionName) on device (passage \(index + 1))."
            )
        }
        return (chunks, citations)
    }
}
