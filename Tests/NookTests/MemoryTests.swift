import XCTest
@testable import NookCore

final class MemoryTests: XCTestCase {

    private func seedChat(store: ChatStore) throws -> (Conversation, Message) {
        let conversation = Conversation(
            id: "c1",
            title: "Dinner planning",
            whenString: "now",
            snippet: "banh mi",
            tags: [],
            activeKnowledgeScope: []
        )
        try store.saveConversation(conversation)
        let message = Message(
            id: "m1",
            conversationId: conversation.id,
            role: .user,
            content: "Sarah said the bánh mì place on Exmouth Market was the best she had had in London."
        )
        try store.saveMessage(message)
        return (conversation, message)
    }

    func testVerbatimQuoteRequired() throws {
        let message = "Sarah said the bánh mì place on Exmouth Market was the best."
        XCTAssertTrue(MemoryStore.quoteIsVerbatim(
            quote: "bánh mì place on Exmouth Market",
            in: message
        ))
        XCTAssertFalse(MemoryStore.quoteIsVerbatim(
            quote: "Sarah loves ramen in Shoreditch",
            in: message
        ))
    }

    func testParseAndValidateCandidates() {
        let user = "Sarah recommended DuckDB for the local analytics layer."
        let raw = """
        [
          {"subject":"DuckDB","kind":"technology","quote":"Sarah recommended DuckDB for the local analytics layer."},
          {"subject":"Fake","kind":"place","quote":"This quote is not in the message"}
        ]
        """
        let parsed = MemoryExtractor.parseCandidates(from: raw)
        XCTAssertEqual(parsed.count, 2)
        let validated = MemoryExtractor.validated(candidates: parsed, againstUserMessage: user)
        XCTAssertEqual(validated.count, 1)
        XCTAssertEqual(validated[0].subject, "DuckDB")
    }

    func testInsertDedupeAndForget() throws {
        let queue = try NookDatabase.makeTestQueue()
        let chatStore = try ChatStore(dbQueue: queue)
        let memoryStore = try MemoryStore(dbQueue: queue)
        let (_, message) = try seedChat(store: chatStore)

        let item = MemoryItem(
            id: "mem-1",
            subject: "Bánh Mì",
            kind: "place",
            quote: "bánh mì place on Exmouth Market",
            source: "“Dinner planning” · 3 Sep",
            conversationId: message.conversationId,
            messageId: message.id
        )
        XCTAssertTrue(try memoryStore.insertCard(item))
        XCTAssertFalse(try memoryStore.insertCard(item), "Exact message+quote should skip")

        try memoryStore.forget(memoryId: item.id)
        XCTAssertTrue(try memoryStore.fetchActiveCards().isEmpty)
        XCTAssertFalse(try memoryStore.insertCard(item), "Forgotten row still blocks re-insert")
    }

    func testCascadeDeletesMemoryWithChat() throws {
        let queue = try NookDatabase.makeTestQueue()
        let chatStore = try ChatStore(dbQueue: queue)
        let memoryStore = try MemoryStore(dbQueue: queue)
        let (conversation, message) = try seedChat(store: chatStore)

        let item = MemoryItem(
            subject: "Exmouth",
            kind: "place",
            quote: "Exmouth Market",
            source: "“Dinner planning” · 3 Sep",
            conversationId: conversation.id,
            messageId: message.id
        )
        XCTAssertTrue(try memoryStore.insertCard(item))
        try memoryStore.upsertExcerpt(
            messageId: message.id,
            conversationId: conversation.id,
            body: message.content
        )

        try chatStore.deleteConversation(id: conversation.id)
        XCTAssertTrue(try memoryStore.fetchActiveCards().isEmpty)
    }

    func testChatInjectCap() async throws {
        let queue = try NookDatabase.makeTestQueue()
        let chatStore = try ChatStore(dbQueue: queue)
        let memoryStore = try MemoryStore(dbQueue: queue)
        let engine = MemoryEngine(store: memoryStore)
        let (conversation, _) = try seedChat(store: chatStore)

        for i in 0..<5 {
            let msg = Message(
                id: "m-extra-\(i)",
                conversationId: conversation.id,
                role: .user,
                content: "Note \(i): DuckDB analytics layer preference \(i)"
            )
            try chatStore.saveMessage(msg)
            _ = try memoryStore.insertCard(
                MemoryItem(
                    subject: "DuckDB \(i)",
                    kind: "technology",
                    quote: "DuckDB analytics layer preference \(i)",
                    source: "“Dinner planning” · 3 Sep",
                    conversationId: conversation.id,
                    messageId: msg.id
                )
            )
        }

        let hits = await engine.memoriesForChat(query: "DuckDB analytics")
        XCTAssertLessThanOrEqual(hits.count, MemoryEngine.chatInjectMaxCards)
        let tokens = hits
            .map { ContextAssembler.estimateTokens(for: MemoryEngine.formatEvidence($0)) }
            .reduce(0, +)
        XCTAssertLessThanOrEqual(tokens, MemoryEngine.chatInjectMaxTokens)
    }
}
