import XCTest
@testable import NookCore
@testable import NookRuntime

final class NookEngineTests: XCTestCase {

    func testChatSnippetStripsMarkdownArtifacts() {
        let raw = """
        ### Vendor risks
        **Important:** see [notes](https://example.com) and `code`.
        - first item
        """
        let plain = ChatStore.plainText(from: raw)
        XCTAssertFalse(plain.contains("###"))
        XCTAssertFalse(plain.contains("**"))
        XCTAssertFalse(plain.contains("`"))
        XCTAssertFalse(plain.contains("]("))
        XCTAssertTrue(plain.contains("Vendor risks"))
        XCTAssertTrue(plain.contains("Important:"))
        XCTAssertTrue(plain.contains("notes"))
        XCTAssertEqual(
            ChatStore.snippet(from: "### Hello world", maxLength: 48),
            "Hello world"
        )
    }

    private func makeStoreWithImportedNotes() throws -> KnowledgeStore {
        let store = try KnowledgeStore.makeForTests()
        _ = try store.createCollection(
            id: "project-alpha",
            name: "Project Alpha",
            desc: "Test collection"
        )
        let mdURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString).md")
        let markdown = """
        # Risks

        Risk item #14: Analytics layer scope is unestimated. Vendor delay is the main schedule risk for launch.

        ## Vendor

        Vendor contract section 4.2 limits liability for delayed deliverables and excludes penalty clauses for slips shorter than ten business days.

        ## Mitigation

        Add buffer weeks to the integration timeline.
        """
        try markdown.write(to: mdURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: mdURL) }
        _ = try store.importMarkdownFile(from: mdURL, collectionId: "project-alpha")
        return store
    }
    
    func testKnowledgeHybridSearchReturnsProjectAlphaPassages() throws {
        let store = try makeStoreWithImportedNotes()
        let hits = try store.search(
            query: "What are the biggest risks in this project?",
            scopedToCollections: ["Project Alpha"],
            limit: 5
        )

        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(
            hits.contains { $0.chunk.text.localizedCaseInsensitiveContains("risk") },
            "Expected risk-related passages from imported notes"
        )
    }

    func testKnowledgeSearchOmitsIrrelevantPassages() throws {
        let store = try makeStoreWithImportedNotes()
        let hits = try store.search(
            query: "vendor contract liability penalty clauses",
            scopedToCollections: ["Project Alpha"],
            limit: 5
        )

        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(
            hits.contains { $0.chunk.text.localizedCaseInsensitiveContains("liability") },
            "Vendor liability passage should surface for this query"
        )
    }

    func testMarkdownImportIndexesByHeading() throws {
        let store = try KnowledgeStore.makeForTests()
        _ = try store.createCollection(id: "project-alpha", name: "Project Alpha")
        let mdURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString).md")
        let markdown = """
        # Risks

        Vendor delay is the main schedule risk for launch.

        ## Mitigation

        Add buffer weeks to the integration timeline.
        """
        try markdown.write(to: mdURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: mdURL) }

        let document = try store.importMarkdownFile(from: mdURL, collectionId: "project-alpha")
        XCTAssertTrue(document.name.hasSuffix(".md"))
        XCTAssertEqual(document.status, "Indexed")

        let hits = try store.search(
            query: "vendor delay schedule risk",
            scopedToCollections: ["Project Alpha"],
            limit: 5
        )
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.contains { $0.chunk.pageOrSection == "Risks" })
    }

    /// Section titles must be FTS-indexed — body text alone can omit the heading words.
    func testSearchMatchesSectionTitleWhenBodyOmitsQueryTerms() throws {
        let store = try KnowledgeStore.makeForTests()
        _ = try store.createCollection(id: "rag", name: "RAG")
        let mdURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rag-\(UUID().uuidString).md")
        let markdown = """
        # Overview

        Retrieval-augmented generation overview.

        ## Failure modes to design for

        - Wrong top-k: Irrelevant passages still look confident.
        - Lost in the middle: Very long contexts bury useful chunks.

        ## Long-context vs RAG

        Million-token windows reduce pressure for some desktop workflows.
        """
        try markdown.write(to: mdURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: mdURL) }
        _ = try store.importMarkdownFile(from: mdURL, collectionId: "rag")

        let failureHits = try store.search(
            query: "Failure modes to design for",
            scopedToCollections: ["RAG"],
            limit: 5
        )
        XCTAssertFalse(failureHits.isEmpty, "Expected heading-only FTS hit for Failure modes")
        XCTAssertEqual(failureHits.first?.chunk.pageOrSection, "Failure modes to design for")

        let longHits = try store.search(
            query: "What is long context?",
            scopedToCollections: ["RAG"],
            limit: 5
        )
        XCTAssertFalse(longHits.isEmpty)
        XCTAssertTrue(
            longHits.contains { $0.chunk.pageOrSection == "Long-context vs RAG" },
            "Expected Long-context section among kept hits"
        )
    }

    func testLearneoFAQMidCyclePerformanceReviews() throws {
        let store = try KnowledgeStore.makeForTests()
        _ = try store.createCollection(id: "learneo", name: "Learneo")
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestFixtures/learneo-faq.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path), fixture.path)
        _ = try store.importMarkdownFile(from: fixture, collectionId: "learneo")

        let markdown = try String(contentsOf: fixture, encoding: .utf8)
        let sections = MarkdownSectionParser.sections(from: markdown)
        for section in sections {
            let words = section.text.split(whereSeparator: \.isWhitespace).count
            print("[test] section=\"\(section.pageOrSection)\" words=\(words)")
        }

        let hits = try store.search(
            query: "What about mid-cycle performance reviews",
            scopedToCollections: ["Learneo"],
            limit: 5
        )
        XCTAssertFalse(hits.isEmpty, "Expected mid-cycle performance reviews FAQ hit")
        guard let midCycle = hits.first(where: {
            $0.chunk.text.localizedCaseInsensitiveContains("mid-cycle performance reviews")
        }) else {
            XCTFail("No chunk contained mid-cycle performance reviews")
            return
        }
        // Paragraph packing should isolate FAQ pairs — not bury them in a 450-word window.
        XCTAssertFalse(
            midCycle.chunk.text.localizedCaseInsensitiveContains("What is happening?"),
            "Mid-cycle chunk should not still contain the first FAQ pair"
        )
        let midCycleWords = midCycle.chunk.text.split(whereSeparator: \.isWhitespace).count
        XCTAssertLessThanOrEqual(midCycleWords, MarkdownParagraphChunker.hardWordBudget + 40)
    }

    func testParagraphChunkingPacksBlankLineBlocks() {
        let body = """
        First block with a handful of words about alpha.

        Second block talks about beta exclusively here.

        Third block is gamma content only.
        """
        let passages = MarkdownParagraphChunker.chunk(text: body)
        XCTAssertEqual(passages.count, 1, "Three short paragraphs should pack into one passage")
        XCTAssertTrue(passages[0].contains("alpha"))
        XCTAssertTrue(passages[0].contains("gamma"))

        let longPair = String(repeating: "word ", count: 90)
        let sparse = """
        \(longPair.trimmingCharacters(in: .whitespaces))

        \(longPair.trimmingCharacters(in: .whitespaces))
        """
        let split = MarkdownParagraphChunker.chunk(text: sparse)
        XCTAssertEqual(split.count, 2, "Paragraphs near soft budget should not merge past soft limit")
    }

    func testContextAssemblerTokenBudget() {
        let budget = ContextBudgetConfig(
            totalContextLimit: 8000,
            systemInstructionsCap: 500,
            activeSkillCap: 500,
            recentChatCap: 1000,
            evidenceCap: 1500,
            toolResultsCap: 500,
            outputReserve: 1500
        )
        let assembler = ContextAssembler(config: budget)
        
        let dummyChunk = DocumentChunk(
            documentId: "doc-1",
            text: String(repeating: "Evidence chunk data words. ", count: 200),
            pageOrSection: "p.1"
        )
        
        let dummyMsg = Message(
            conversationId: "c1",
            role: .user,
            content: String(repeating: "User question text. ", count: 100)
        )
        
        let result = assembler.assemble(
            baseSystemPrompt: "You are Nook.",
            activeSkill: nil,
            evidenceChunks: [dummyChunk, dummyChunk, dummyChunk],
            chatHistory: [dummyMsg, dummyMsg, dummyMsg],
            toolResults: []
        )
        
        XCTAssertLessThanOrEqual(result.totalEstimatedTokens, budget.totalContextLimit - budget.outputReserve)
    }
    
    func testSkillCatalogOnlyIncludesWiredSkills() async {
        let skills = await SkillManager().getAllSkills()
        XCTAssertEqual(skills.map(\.id), ["meeting-prep"])
    }
    
    func testDocumentsSearchToolIsRegistered() async throws {
        let store = try makeStoreWithImportedNotes()
        let engine = KnowledgeEngine(store: store)
        let registry = ToolRegistry(knowledgeEngine: engine)

        let names = await registry.allToolNames()
        XCTAssertTrue(names.contains(DocumentsSearchTool.toolName))

        let result = await registry.documentsSearch(
            query: "vendor delay schedule risk",
            scopedToCollections: ["Project Alpha"]
        )
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.chunks.isEmpty ?? true)
    }

    func testDocumentsSearchToolSchemaAndExecute() async throws {
        let store = try makeStoreWithImportedNotes()
        let engine = KnowledgeEngine(store: store)
        let registry = ToolRegistry(knowledgeEngine: engine)
        await registry.setDocumentsSearchScope(["Project Alpha"])

        let schemas = await registry.schemas(forAllowedNames: [DocumentsSearchTool.toolName])
        XCTAssertEqual(schemas.count, 1)
        let function = schemas[0]["function"] as? [String: any Sendable]
        XCTAssertEqual(function?["name"] as? String, DocumentsSearchTool.toolName)

        let result = try await registry.execute(
            toolName: DocumentsSearchTool.toolName,
            arguments: ["query": .string("vendor delay schedule risk")]
        )
        XCTAssertFalse(result.chunks.isEmpty)
        XCTAssertTrue(result.displayText.contains(DocumentsSearchTool.toolName))
        XCTAssertTrue(result.textForModel.contains("passage"))
    }

    func testToolRegistryPrivacyBoundary() async {
        let registry = ToolRegistry(knowledgeEngine: KnowledgeEngine())
        
        struct DummyLocalTool: AgentTool {
            let name = "calendar.search"
            let description = "Search calendar"
            let isExternal = false
            let requiresApprovalByDefault = false
            let parameters: [AgentToolParameterSchema] = []
            func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
                ToolExecutionResult(textForModel: "[]", displayText: name)
            }
        }
        
        struct DummyExternalTool: AgentTool {
            let name = "github.search_issues"
            let description = "Search github"
            let isExternal = true
            let requiresApprovalByDefault = true
            let parameters: [AgentToolParameterSchema] = []
            func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
                ToolExecutionResult(textForModel: "[]", displayText: name)
            }
        }
        
        await registry.register(tool: DummyLocalTool())
        await registry.register(tool: DummyExternalTool())
        
        let localReq = await registry.requiresApproval(toolName: "calendar.search")
        XCTAssertFalse(localReq, "Local tools should not require outgoing network approval")
        
        let extReq = await registry.requiresApproval(toolName: "github.search_issues")
        XCTAssertTrue(extReq, "External MCP tools must require approval by default")
        
        await registry.setAlwaysAllow(toolName: "github.search_issues", allowed: true)
        let extAllowedReq = await registry.requiresApproval(toolName: "github.search_issues")
        XCTAssertFalse(extAllowedReq, "Once always-allowed, explicit modal approval is bypassed")
    }
    
    func testMemoryProvenanceAndForget() async throws {
        let queue = try NookDatabase.makeTestQueue()
        let chatStore = try ChatStore(dbQueue: queue)
        let memoryStore = try MemoryStore(dbQueue: queue)
        let conversation = Conversation(
            id: "c-mem",
            title: "Test",
            whenString: "now",
            snippet: "",
            tags: [],
            activeKnowledgeScope: []
        )
        try chatStore.saveConversation(conversation)
        let message = Message(
            id: "m-mem",
            conversationId: conversation.id,
            role: .user,
            content: "Sarah recommended DuckDB"
        )
        try chatStore.saveMessage(message)
        XCTAssertTrue(try memoryStore.insertCard(MemoryItem(
            subject: "DuckDB",
            kind: "technology",
            quote: "Sarah recommended DuckDB",
            source: "“Test” · 3 Sep",
            conversationId: conversation.id,
            messageId: message.id
        )))

        let memoryEngine = MemoryEngine(store: memoryStore)
        let initial = await memoryEngine.getAllMemories()
        XCTAssertEqual(initial.count, 1)

        let first = initial[0]
        await memoryEngine.forget(memoryId: first.id)

        let remaining = await memoryEngine.getAllMemories()
        XCTAssertFalse(remaining.contains(where: { $0.id == first.id }))
    }

    func testDeleteDocumentAndCollection() throws {
        let store = try makeStoreWithImportedNotes()
        let docs = try store.fetchDocuments(collectionId: "project-alpha")
        XCTAssertFalse(docs.isEmpty)

        try store.deleteDocument(id: docs[0].id)
        XCTAssertTrue(try store.fetchDocuments(collectionId: "project-alpha").isEmpty)

        try store.deleteCollection(id: "project-alpha")
        XCTAssertFalse(try store.fetchCollections().contains(where: { $0.id == "project-alpha" }))
    }

    func testCreateCollectionStoresSubtitle() throws {
        let store = try KnowledgeStore.makeForTests()
        let created = try store.createCollection(
            name: "Research",
            desc: "Papers and lab notes"
        )
        let fetched = try store.fetchCollections().first { $0.id == created.id }
        XCTAssertEqual(fetched?.desc, "Papers and lab notes")
    }
}
