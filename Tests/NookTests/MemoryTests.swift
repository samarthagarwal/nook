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
        let user = "Who led the Delhi protests?"
        let assistant = "Abhijeet Dipke was associated with the Delhi protests according to reports."
        let raw = """
        [
          {"from":"user","subject":"Delhi protests","kind":"other","quote":"Who led the Delhi protests?"},
          {"from":"assistant","subject":"Abhijeet Dipke","kind":"person","quote":"Abhijeet Dipke was associated with the Delhi protests according to reports."},
          {"from":"assistant","subject":"Fake","kind":"person","quote":"This quote is not in the reply"}
        ]
        """
        let parsed = MemoryExtractor.parseCandidates(from: raw)
        XCTAssertEqual(parsed.count, 3)
        let validated = MemoryExtractor.validated(
            candidates: parsed,
            userMessage: user,
            assistantMessage: assistant
        )
        XCTAssertEqual(validated.count, 2)
        XCTAssertEqual(validated[1].subject, "Abhijeet Dipke")
        XCTAssertEqual(validated[1].provenance, .assistant)
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

    func testSubjectDedupeAcrossChats() throws {
        let queue = try NookDatabase.makeTestQueue()
        let chatStore = try ChatStore(dbQueue: queue)
        let memoryStore = try MemoryStore(dbQueue: queue)

        let c1 = Conversation(id: "c1", title: "Chat 1", whenString: "now", snippet: "", tags: [], activeKnowledgeScope: [])
        let c2 = Conversation(id: "c2", title: "Chat 2", whenString: "now", snippet: "", tags: [], activeKnowledgeScope: [])
        try chatStore.saveConversation(c1)
        try chatStore.saveConversation(c2)
        let m1 = Message(id: "m1", conversationId: c1.id, role: .user, content: "Tell me about Abhijeet Dipke")
        let m2 = Message(id: "m2", conversationId: c2.id, role: .user, content: "What did we say about Abhijeet Dipke earlier?")
        try chatStore.saveMessage(m1)
        try chatStore.saveMessage(m2)

        XCTAssertTrue(try memoryStore.insertCard(MemoryItem(
            subject: "Abhijeet Dipke",
            kind: "person",
            quote: "Abhijeet Dipke",
            source: "“Chat 1” · 3 Sep",
            conversationId: c1.id,
            messageId: m1.id,
            provenance: .assistant
        )))
        XCTAssertFalse(try memoryStore.insertCard(MemoryItem(
            subject: "abhijeet dipke",
            kind: "person",
            quote: "What did we say about Abhijeet Dipke earlier?",
            source: "“Chat 2” · 3 Sep",
            conversationId: c2.id,
            messageId: m2.id,
            provenance: .user
        )), "Same subject should not create a second active card")
        XCTAssertEqual(try memoryStore.fetchActiveCards().count, 1)
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
