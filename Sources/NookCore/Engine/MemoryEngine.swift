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

    /// Raw message excerpts relevant to `query`, for use by ConversationSearchTool.
    /// Returns at most `limit` entries; each entry is (body, conversationId, createdAt).
    public func searchExcerpts(query: String, limit: Int = 6) -> [(body: String, conversationId: String, createdAt: Date)] {
        (try? store.fetchExcerpts(query: query, limit: limit)) ?? []
    }

    public func forget(memoryId: String) {
        try? store.forget(memoryId: memoryId)
    }

    /// Indexes both sides of a turn and extracts cards (user + assistant) in one model call.
    public func processExchange(
        userMessage: Message,
        assistantMessage: Message,
        conversationTitle: String,
        generate: @Sendable (_ systemPrompt: String, _ userPrompt: String) async throws -> String
    ) async {
        guard userMessage.role == .user else { return }
        let userBody = userMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistantBody = assistantMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userBody.isEmpty else { return }

        do {
            try store.upsertExcerpt(
                messageId: userMessage.id,
                conversationId: userMessage.conversationId,
                body: userBody,
                createdAt: userMessage.createdAt
            )
            if !assistantBody.isEmpty {
                try store.upsertExcerpt(
                    messageId: assistantMessage.id,
                    conversationId: assistantMessage.conversationId,
                    body: assistantBody,
                    createdAt: assistantMessage.createdAt
                )
            }
        } catch {
            print("[MemoryEngine] Failed to upsert excerpts: \(error)")
        }

        let userDone = (try? store.hasExtracted(messageId: userMessage.id)) ?? false
        let assistantDone = assistantBody.isEmpty
            || ((try? store.hasExtracted(messageId: assistantMessage.id)) ?? false)
        if userDone && assistantDone {
            return
        }

        let raw: String
        do {
            print("[MemoryExtract] Running exchange extract for message \(userMessage.id)")
            raw = try await generate(
                MemoryExtractor.systemPrompt,
                MemoryExtractor.exchangePrompt(
                    userMessage: userBody,
                    assistantMessage: assistantBody.isEmpty ? "(no reply)" : assistantBody
                )
            )
        } catch {
            print("[MemoryEngine] Extract generation failed: \(error)")
            return
        }

        let validated = MemoryExtractor.validated(
            candidates: MemoryExtractor.parseCandidates(from: raw),
            userMessage: userBody,
            assistantMessage: assistantBody
        ).filter { candidate in
            // Don't memorize "I don't know" / ungrounded world-news refusals from weak replies.
            if candidate.provenance == .assistant,
               Self.looksLikeLowValueAssistantReply(candidate.quote) || Self.looksLikeLowValueAssistantReply(assistantBody) {
                return false
            }
            return true
        }

        for candidate in validated.prefix(4) {
            let sourceMessage = candidate.provenance == .assistant ? assistantMessage : userMessage
            let source = MemoryStore.sourceLabel(
                conversationTitle: conversationTitle,
                date: sourceMessage.createdAt,
                provenance: candidate.provenance
            )
            let item = MemoryItem(
                subject: candidate.subject,
                kind: candidate.kind,
                quote: candidate.quote,
                source: source,
                conversationId: sourceMessage.conversationId,
                messageId: sourceMessage.id,
                provenance: candidate.provenance,
                createdAt: sourceMessage.createdAt
            )
            // Embed the quote so we can later filter cards by topical distance from
            // retrieved knowledge passages, rather than suppressing all memory in scoped chats.
            let embedding = KnowledgeEmbedder.embed(candidate.quote)
            do {
                _ = try store.insertCard(item, embedding: embedding)
            } catch {
                print("[MemoryEngine] Failed to insert card: \(error)")
            }
        }

        do {
            try store.markExtracted(messageId: userMessage.id)
            if !assistantBody.isEmpty {
                try store.markExtracted(messageId: assistantMessage.id)
            }
        } catch {
            print("[MemoryEngine] Failed to mark extracted: \(error)")
        }
    }

    /// Filters memory cards by topical distance from retrieved knowledge passages.
    ///
    /// Cards whose embedding is too similar to the top retrieved chunk are dropped —
    /// they cover the same topic and would compete with the passage for the model's
    /// attention. Cards on unrelated topics (preferences, names, projects, etc.) are kept.
    ///
    /// Cards without a stored embedding (pre-v8 or NLEmbedding unavailable) are kept
    /// unconditionally so old memory is never silently discarded.
    ///
    /// - Parameters:
    ///   - cards: The candidate memory items fetched for this query.
    ///   - retrievedChunks: Knowledge passages retrieved this turn (top chunk used for scoring).
    ///   - conflictThreshold: Cosine similarity above which a card is considered conflicting (default 0.35).
    public func memoriesRelevantTo(
        cards: [MemoryItem],
        retrievedChunks: [DocumentChunk],
        conflictThreshold: Float = 0.35
    ) -> [MemoryItem] {
        guard !cards.isEmpty, !retrievedChunks.isEmpty else { return cards }

        // Embed only the top chunk — it's the one the model will weight most heavily.
        guard let chunkVector = KnowledgeEmbedder.embed(retrievedChunks[0].text) else {
            // NLEmbedding unavailable — keep all cards rather than silently dropping them.
            return cards
        }

        return cards.filter { card in
            guard let cardVector = store.fetchEmbedding(memoryId: card.id) else {
                // No stored embedding (card predates v8 migration) → keep it.
                return true
            }
            let similarity = KnowledgeEmbedder.cosineSimilarity(cardVector, chunkVector)
            let keep = similarity < conflictThreshold
            if !keep {
                print("[MemoryEngine] Suppressing card '\(card.subject)' (similarity=\(String(format: "%.2f", similarity)) ≥ \(conflictThreshold))")
            }
            return keep
        }
    }

    /// Processes all unextracted user+assistant exchange pairs in a message list.
    /// Call this on chat open to catch any exchanges that were missed (e.g. app was
    /// force-quit before the background extraction task fired).
    public func processUnextractedExchanges(
        in messages: [Message],
        conversationTitle: String,
        generate: @Sendable (_ systemPrompt: String, _ userPrompt: String) async throws -> String
    ) async {
        // Walk pairs: for each user message not yet extracted, find the immediately
        // following assistant reply and process the exchange.
        for (index, message) in messages.enumerated() {
            guard message.role == .user else { continue }
            let done = (try? store.hasExtracted(messageId: message.id)) ?? false
            if done { continue }
            // Find the assistant reply that directly follows this user turn.
            let nextIndex = index + 1
            guard nextIndex < messages.count, messages[nextIndex].role == .assistant else { continue }
            let assistantMessage = messages[nextIndex]
            await processExchange(
                userMessage: message,
                assistantMessage: assistantMessage,
                conversationTitle: conversationTitle,
                generate: generate
            )
        }
    }

    public static func formatEvidence(_ item: MemoryItem) -> String {
        let tag = item.provenance == .assistant ? "MEMORY (from a reply)" : "MEMORY"
        return """
        \(tag) \(item.source):
        \"\"\"
        \(item.quote)
        \"\"\"
        """
    }

    public static func evidenceStrings(from items: [MemoryItem]) -> [String] {
        items.map(formatEvidence)
    }

    private static func looksLikeLowValueAssistantReply(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "i do not have",
            "i don't have",
            "i'm not sure",
            "i am not sure",
            "no specific information",
            "complex geopolitical",
            "as an ai",
        ]
        return markers.contains { lower.contains($0) }
    }
}
