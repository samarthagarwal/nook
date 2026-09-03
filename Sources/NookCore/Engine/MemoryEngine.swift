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
            do {
                _ = try store.insertCard(item)
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
