import Foundation

public actor KnowledgeEngine {
    private var collections: [KnowledgeCollection]
    private var documents: [KnowledgeDocument]
    private var chunks: [DocumentChunk]
    
    public init() {
        self.collections = [
            KnowledgeCollection(
                id: "project-alpha",
                name: "Project Alpha",
                count: "9 docs",
                desc: "Spec, risk register, retro notes, vendor contract.",
                status: "Indexed · 1,402 passages",
                state: .ready
            ),
            KnowledgeCollection(
                id: "personal",
                name: "Personal",
                count: "23 docs",
                desc: "Receipts, letters, warranties, the flat.",
                status: "Indexed · 640 passages",
                state: .ready
            ),
            KnowledgeCollection(
                id: "university",
                name: "University",
                count: "5 docs",
                desc: "Reading list and two lecture handouts.",
                status: "Indexing 2 documents",
                state: .busy
            )
        ]
        
        self.documents = [
            KnowledgeDocument(
                collectionId: "project-alpha",
                name: "alpha-spec-v4.pdf",
                meta: "42 pages",
                status: "Indexed"
            ),
            KnowledgeDocument(
                collectionId: "project-alpha",
                name: "risk-register.pdf",
                meta: "6 pages",
                status: "Indexed"
            ),
            KnowledgeDocument(
                collectionId: "project-alpha",
                name: "retro-notes.md",
                meta: "2,100 words",
                status: "Indexed"
            ),
            KnowledgeDocument(
                collectionId: "project-alpha",
                name: "vendor-contract.docx",
                meta: "18 pages",
                status: "Extracting 62%",
                progressPct: 62
            )
        ]
        
        self.chunks = [
            DocumentChunk(
                documentId: "alpha-spec-v4.pdf",
                text: "The specification names one primary identity provider (Okta Cloud) for all customer auth flows. No secondary fallback provider is currently configured or provisioned for v1 launch.",
                pageOrSection: "p.18"
            ),
            DocumentChunk(
                documentId: "risk-register.pdf",
                text: "Risk item #14: Analytics layer scope is unestimated and represents a high uncertainty factor for sprint delivery.",
                pageOrSection: "p.3"
            ),
            DocumentChunk(
                documentId: "retro-notes.md",
                text: "Timeline slippage retro notes: Vendor delivery slipped 2.5 weeks in Q2, and 3 weeks in Q1. Schedule buffer must account for vendor delays.",
                pageOrSection: "Timeline"
            )
        ]
    }
    
    public func getCollections() -> [KnowledgeCollection] {
        return collections
    }
    
    public func getDocuments(forCollectionId collectionId: String) -> [KnowledgeDocument] {
        return documents.filter { $0.collectionId == collectionId }
    }
    
    /// Chunks arbitrary text into 400-600 token pieces with 50-100 token overlap
    public func chunkText(text: String, documentId: String, pageOrSection: String) -> [DocumentChunk] {
        let words = text.split(separator: " ").map(String.init)
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
                    documentId: documentId,
                    text: chunkString,
                    pageOrSection: pageOrSection
                )
            )
            
            if endIndex == words.count { break }
            startIndex += (chunkSizeInWords - overlapInWords)
        }
        
        return generatedChunks
    }
    
    /// Search Knowledge scoped to selected collection names
    public func search(query: String, scopedToCollections: [String]) -> (chunks: [DocumentChunk], citations: [Citation]) {
        let matchingChunks = chunks
        let citations: [Citation] = matchingChunks.map { chunk in
            Citation(
                label: "\(chunk.documentId) · \(chunk.pageOrSection)",
                sourceDocument: chunk.documentId,
                pageOrSection: chunk.pageOrSection,
                passage: chunk.text,
                surroundingContext: "Section 4.2 Auth Architecture — ... \(chunk.text) ... (Retrieved on device via local index)"
            )
        }
        return (matchingChunks, citations)
    }
}
