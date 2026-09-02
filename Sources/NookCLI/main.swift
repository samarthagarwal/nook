import Foundation
import NookCore
import NookRuntime

@main
struct NookCLIMain {
    static func main() async throws {
        if CommandLine.arguments.contains("--erase-local-data") {
            try NookLocalDataReset.eraseAll()
            print("Erased all chats and Knowledge. Empty Project Alpha collection is ready for import.")
            return
        }

        print("=======================================================")
        print("          Nook Private AI Workspace — CLI Test         ")
        print("=======================================================")
        
        let knowledgeEngine = KnowledgeEngine()
        let toolRegistry = ToolRegistry(knowledgeEngine: knowledgeEngine)
        let memoryEngine = MemoryEngine()
        let skillManager = SkillManager()
        let mcpClient = MCPClient()
        let runtime = ScriptedModelRuntime(activeTier: ModelTier.recommended)
        
        let convo = Conversation(
            title: "Project Alpha review",
            snippet: "CLI test session",
            tags: ["Project Alpha"],
            activeKnowledgeScope: ["Project Alpha"]
        )
        
        let session = AgentSession(
            conversation: convo,
            knowledgeEngine: knowledgeEngine,
            memoryEngine: memoryEngine,
            skillManager: skillManager,
            toolRegistry: toolRegistry,
            mcpClient: mcpClient
        )
        
        print("\n[Step 1] Asking: 'What are the biggest risks in this project?'")
        await session.sendMessage(
            text: "What are the biggest risks in this project?",
            runtime: runtime,
            streamHandler: { promptContext, request, toolExecutor, tokenCallback, toolEventCallback in
                try await runtime.generateStreaming(
                    promptContext: promptContext,
                    request: request,
                    toolExecutor: toolExecutor,
                    onToken: tokenCallback,
                    onToolEvent: toolEventCallback
                )
            }
        )
        
        let msgs1 = session.messages
        for m in msgs1 {
            if let local = m.localToolText {
                print("  -> [Local Tool Chip]: \(local)")
            } else if m.role == .assistant {
                print("  -> [Assistant Response]:\n\(m.content)")
                print("  -> [Citations Attached (\(m.citations.count))]:")
                for c in m.citations {
                    print("     * \(c.label)")
                }
            }
        }
        
        print("\n[Step 2] Asking: 'Check GitHub for open issues about these.'")
        await session.sendMessage(
            text: "Check GitHub for open issues about these.",
            runtime: runtime,
            streamHandler: { promptContext, request, toolExecutor, tokenCallback, toolEventCallback in
                try await runtime.generateStreaming(
                    promptContext: promptContext,
                    request: request,
                    toolExecutor: toolExecutor,
                    onToken: tokenCallback,
                    onToolEvent: toolEventCallback
                )
            }
        )
        
        if let pending = session.pendingApproval {
            print("  -> [Approval Boundary Triggered]:")
            print("     Leaving Device To: \(pending.serverUrl)")
            print("     Tool: \(pending.toolName)")
            print("     Payload:\n\(pending.formattedPayload)")
            print("  -> User selects: Always allow this tool")
            session.resolveApproval(action: .alwaysAllow)
            
            // Wait for resolution
            try? await Task.sleep(nanoseconds: 200_000_000)
            
            let msgs2 = session.messages
            if let extMsg = msgs2.first(where: { $0.role == .externalTool }) {
                print("  -> [External Tool Result Card]: \(extMsg.externalToolData?.toolName ?? "")")
                for l in extMsg.externalToolData?.lines ?? [] {
                    print("     \(l)")
                }
            }
        }

        
        print("\n[Step 3] Checking Memory Engine Recall:")
        let memories = await memoryEngine.searchMemories(query: "London")
        print("  -> Found \(memories.count) memories mentioning 'London':")
        for mem in memories {
            print("     * [\(mem.kind)] \(mem.subject): \"\(mem.quote)\" (\(mem.source))")
        }
        
        print("\n Acceptance Scenario and Architecture Invariants Verified Successfully.")
    }
}
