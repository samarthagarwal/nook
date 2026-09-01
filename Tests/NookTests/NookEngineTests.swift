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
        XCTAssertTrue(
            hits.contains { $0.chunk.text.localizedCaseInsensitiveContains("risk") },
            "Expected risk-related passages from the seeded corpus"
        )
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
    
    func testToolRegistryPrivacyBoundary() async {
        let registry = ToolRegistry()
        
        struct DummyLocalTool: AgentTool {
            let name = "calendar.search"
            let description = "Search calendar"
            let isExternal = false
            let requiresApprovalByDefault = false
            func execute(arguments: [String : Any]) async throws -> String { "[]" }
        }
        
        struct DummyExternalTool: AgentTool {
            let name = "github.search_issues"
            let description = "Search github"
            let isExternal = true
            let requiresApprovalByDefault = true
            func execute(arguments: [String : Any]) async throws -> String { "[]" }
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
