import Foundation

public struct ContextBudgetConfig: Sendable {
    public let totalContextLimit: Int
    public let systemInstructionsCap: Int
    public let activeSkillCap: Int
    public let recentChatCap: Int
    public let evidenceCap: Int
    public let toolResultsCap: Int
    public let outputReserve: Int
    
    public init(
        totalContextLimit: Int = 8192,
        systemInstructionsCap: Int = 1000,
        activeSkillCap: Int = 1000,
        recentChatCap: Int = 2000,
        evidenceCap: Int = 2500,
        toolResultsCap: Int = 1000,
        outputReserve: Int = 1692
    ) {
        self.totalContextLimit = totalContextLimit
        self.systemInstructionsCap = systemInstructionsCap
        self.activeSkillCap = activeSkillCap
        self.recentChatCap = recentChatCap
        self.evidenceCap = evidenceCap
        self.toolResultsCap = toolResultsCap
        self.outputReserve = outputReserve
    }
}

public struct AssembledPromptContext: Sendable {
    public let systemPrompt: String
    public let activeSkillInstructions: String?
    public let retrievedEvidence: [String]
    public let recentMessages: [Message]
    public let toolResultSummaries: [String]
    public let totalEstimatedTokens: Int

    public init(
        systemPrompt: String,
        activeSkillInstructions: String?,
        retrievedEvidence: [String],
        recentMessages: [Message],
        toolResultSummaries: [String],
        totalEstimatedTokens: Int
    ) {
        self.systemPrompt = systemPrompt
        self.activeSkillInstructions = activeSkillInstructions
        self.retrievedEvidence = retrievedEvidence
        self.recentMessages = recentMessages
        self.toolResultSummaries = toolResultSummaries
        self.totalEstimatedTokens = totalEstimatedTokens
    }
}

public struct ContextAssembler: Sendable {
    private let config: ContextBudgetConfig
    
    public init(config: ContextBudgetConfig = ContextBudgetConfig()) {
        self.config = config
    }
    
    /// Approximate token estimator (4 characters ~= 1 token)
    public static func estimateTokens(for text: String) -> Int {
        return max(1, text.count / 4)
    }
    
    public func assemble(
        baseSystemPrompt: String,
        activeSkill: Skill?,
        evidenceChunks: [DocumentChunk],
        chatHistory: [Message],
        toolResults: [String],
        memoryEvidence: [String] = []
    ) -> AssembledPromptContext {
        // 1. Truncate / fit System prompt
        let fittedSystem = truncate(text: baseSystemPrompt, maxTokens: config.systemInstructionsCap)
        
        // 2. Inject SKILL.md only when this chat has an explicit Skill.
        var fittedSkill: String? = nil
        if let skill = activeSkill {
            let body = skill.skillMdContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                fittedSkill = truncate(text: body, maxTokens: config.activeSkillCap)
            }
        }
        
        // 3. Fit Evidence — Knowledge first, then Memory (Knowledge must win when both present)
        var fittedEvidence: [String] = []
        var evidenceTokens = 0
        for chunk in evidenceChunks {
            let chunkTokens = ContextAssembler.estimateTokens(for: chunk.text)
            if evidenceTokens + chunkTokens <= config.evidenceCap {
                fittedEvidence.append(
                    "SOURCE \(chunk.documentId) · \(chunk.pageOrSection):\n\"\"\"\n\(chunk.text)\n\"\"\""
                )
                evidenceTokens += chunkTokens
            } else {
                break
            }
        }
        let memoryBudget = min(MemoryEngine.chatInjectMaxTokens, max(0, config.evidenceCap - evidenceTokens))
        var memoryTokens = 0
        for block in memoryEvidence {
            let cost = ContextAssembler.estimateTokens(for: block)
            if memoryTokens + cost > memoryBudget { break }
            fittedEvidence.append(block)
            memoryTokens += cost
            evidenceTokens += cost
        }
        
        // 4. Fit Tool Results
        var fittedTools: [String] = []
        var toolTokens = 0
        for result in toolResults {
            let resTokens = ContextAssembler.estimateTokens(for: result)
            if toolTokens + resTokens <= config.toolResultsCap {
                fittedTools.append(result)
                toolTokens += resTokens
            } else {
                break
            }
        }
        
        // 5. Fit Recent Chat from newest backwards
        var fittedMessages: [Message] = []
        var chatTokens = 0
        for message in chatHistory.reversed() {
            let msgTokens = ContextAssembler.estimateTokens(for: message.content)
            if chatTokens + msgTokens <= config.recentChatCap {
                fittedMessages.insert(message, at: 0)
                chatTokens += msgTokens
            } else {
                break
            }
        }
        
        let totalEstimatedTokens = ContextAssembler.estimateTokens(for: fittedSystem)
            + (fittedSkill.map { ContextAssembler.estimateTokens(for: $0) } ?? 0)
            + evidenceTokens
            + toolTokens
            + chatTokens
        
        return AssembledPromptContext(
            systemPrompt: fittedSystem,
            activeSkillInstructions: fittedSkill,
            retrievedEvidence: fittedEvidence,
            recentMessages: fittedMessages,
            toolResultSummaries: fittedTools,
            totalEstimatedTokens: totalEstimatedTokens
        )
    }
    
    private func truncate(text: String, maxTokens: Int) -> String {
        let maxChars = maxTokens * 4
        if text.count <= maxChars {
            return text
        }
        let index = text.index(text.startIndex, offsetBy: maxChars)
        return String(text[..<index]) + "\n[Truncated to fit context budget]"
    }
}
