import XCTest
@testable import NookCore
@testable import NookRuntime

final class NookEngineTests: XCTestCase {
    
    func testKnowledgeHybridSearchReturnsProjectAlphaPassages() throws {
        let store = try KnowledgeStore.makeForTests()
        let hits = try store.search(
            query: "What are the biggest risks in this project?",
            scopedToCollections: ["Project Alpha"],
            limit: 5
        )

        XCTAssertFalse(hits.isEmpty)
        XCTAssertLessThan(hits.count, 5, "Should not return every seeded chunk as a hit")
        XCTAssertTrue(
            hits.contains { $0.chunk.text.localizedCaseInsensitiveContains("risk") },
            "Expected risk-related passages from the seeded corpus"
        )
    }

    func testKnowledgeSearchOmitsIrrelevantPassages() throws {
        let store = try KnowledgeStore.makeForTests()
        let hits = try store.search(
            query: "vendor contract liability penalty clauses",
            scopedToCollections: ["Project Alpha"],
            limit: 5
        )

        XCTAssertFalse(hits.isEmpty)
        XCTAssertLessThanOrEqual(hits.count, 2)
        XCTAssertTrue(
            hits.allSatisfy { $0.documentName == "vendor-contract.docx" },
            "Only vendor-contract passages should surface for this query"
        )
    }

    func testMarkdownImportIndexesByHeading() throws {
        let store = try KnowledgeStore.makeForTests()
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
    
    func testSkillPermissionIsolation() async {
        let skillManager = SkillManager()
        let skills = await skillManager.getAllSkills()
        
        // Ensure imported skills default to NO permissions granted
        if let compSkill = skills.first(where: { $0.id == "competitive-teardown" }) {
            for perm in compSkill.permissions {
                XCTAssertFalse(perm.isGranted, "Permission \(perm.tool) must default to off")
            }
        }
    }
    
    func testDocumentsSearchToolIsRegistered() async throws {
        let store = try KnowledgeStore.makeForTests()
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
        let store = try KnowledgeStore.makeForTests()
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
    
    func testMemoryProvenanceAndForget() async {
        let memoryEngine = MemoryEngine()
        let initial = await memoryEngine.getAllMemories()
        XCTAssertFalse(initial.isEmpty)
        
        let first = initial[0]
        await memoryEngine.forget(memoryId: first.id)
        
        let remaining = await memoryEngine.getAllMemories()
        XCTAssertFalse(remaining.contains(where: { $0.id == first.id }), "Forgotten item must be excluded from memory search")
    }
}
