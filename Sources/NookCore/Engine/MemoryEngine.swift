import Foundation

public actor MemoryEngine {
    public static let chatInjectMaxCards = 3
    public static let chatInjectMaxTokens = 200

    private let store: MemoryStore

    public init(store: MemoryStore = .shared) {
        self.store = store
    }

    public func getAllMemories() -> [MemoryItem] {
        (try? store.fetchActiveCards()) ?? []
    }

    public func searchMemories(query: String) -> [MemoryItem] {
        (try? store.searchCards(query: query)) ?? []
    }

    /// Top memories for injecting into the next assistant turn.
    public func memoriesForChat(query: String) -> [MemoryItem] {
        let hits = (try? store.retrieveForQuery(query, maxCards: Self.chatInjectMaxCards)) ?? []
        var fitted: [MemoryItem] = []
        var tokens = 0
        for item in hits {
            let block = Self.formatEvidence(item)
            let cost = ContextAssembler.estimateTokens(for: block)
            if tokens + cost > Self.chatInjectMaxTokens { break }
            fitted.append(item)
            tokens += cost
        }
        return fitted
    }

    public func forget(memoryId: String) {
        try? store.forget(memoryId: memoryId)
    }

    /// Indexes the user message excerpt and runs LLM extraction if not already done.
    /// `generate` should return model text for the given system+user extract prompts.
    public func processUserMessage(
        message: Message,
        conversationTitle: String,
        generate: @Sendable (_ systemPrompt: String, _ userPrompt: String) async throws -> String
    ) async {
        guard message.role == .user else { return }
        let body = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        do {
            try store.upsertExcerpt(
                messageId: message.id,
                conversationId: message.conversationId,
                body: body,
                createdAt: message.createdAt
            )
        } catch {
            print("[MemoryEngine] Failed to upsert excerpt: \(error)")
        }

        do {
            if try store.hasExtracted(messageId: message.id) {
                return
            }
        } catch {
            print("[MemoryEngine] Watermark read failed: \(error)")
            return
        }

        let raw: String
        do {
            raw = try await generate(
                MemoryExtractor.systemPrompt,
                MemoryExtractor.userPrompt(for: body)
            )
        } catch {
            print("[MemoryEngine] Extract generation failed: \(error)")
            return
        }

        let validated = MemoryExtractor.validated(
            candidates: MemoryExtractor.parseCandidates(from: raw),
            againstUserMessage: body
        )

        let source = MemoryStore.sourceLabel(
            conversationTitle: conversationTitle,
            date: message.createdAt
        )

        for candidate in validated.prefix(3) {
            let item = MemoryItem(
                subject: candidate.subject,
                kind: candidate.kind,
                quote: candidate.quote,
                source: source,
                conversationId: message.conversationId,
                messageId: message.id,
                createdAt: message.createdAt
            )
            do {
                _ = try store.insertCard(item)
            } catch {
                print("[MemoryEngine] Failed to insert card: \(error)")
            }
        }

        do {
            try store.markExtracted(messageId: message.id)
        } catch {
            print("[MemoryEngine] Failed to mark extracted: \(error)")
        }
    }

    public static func formatEvidence(_ item: MemoryItem) -> String {
        """
        MEMORY \(item.source):
        \"\"\"
        \(item.quote)
        \"\"\"
        """
    }

    public static func evidenceStrings(from items: [MemoryItem]) -> [String] {
        items.map(formatEvidence)
    }
}
