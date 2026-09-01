import Foundation

public actor MemoryEngine {
    private var memoryItems: [MemoryItem]
    
    public init() {
        self.memoryItems = [
            MemoryItem(
                id: "mem-1",
                subject: "Bánh Mì on Exmouth Market",
                kind: "place",
                quote: "Sarah said the bánh mì place on Exmouth Market was the best she had had in London — worth the queue.",
                source: "“Dinner planning” · 24 Aug · message 14"
            ),
            MemoryItem(
                id: "mem-2",
                subject: "DuckDB",
                kind: "technology",
                quote: "Sarah recommended DuckDB for the local analytics layer instead of shipping a second service.",
                source: "“London trip debrief” · 25 Aug · message 6"
            )
        ]
    }
    
    public func getAllMemories() -> [MemoryItem] {
        return memoryItems.filter { !$0.isForgotten }
    }
    
    public func searchMemories(query: String) -> [MemoryItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return getAllMemories()
        }
        let lower = query.lowercased()
        return memoryItems.filter { item in
            !item.isForgotten && (
                item.subject.lowercased().contains(lower) ||
                item.quote.lowercased().contains(lower) ||
                item.kind.lowercased().contains(lower)
            )
        }
    }
    
    /// Forgets a derived memory item. Note: Raw conversation is left untouched per product rules.
    public func forget(memoryId: String) {
        if let index = memoryItems.firstIndex(where: { $0.id == memoryId }) {
            memoryItems[index].isForgotten = true
        }
    }
    
    /// Rebuilds derived memory index from chat history
    public func rebuildIndex() {
        // Reset forgotten flags or re-extract from chats
        for i in 0..<memoryItems.count {
            memoryItems[i].isForgotten = false
        }
    }
}
