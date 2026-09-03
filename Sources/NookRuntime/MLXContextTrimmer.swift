import Foundation
import NookCore

/// Shrinks assembled prompts for memory-heavy VLM inference.
enum MLXContextTrimmer {
    static func trimmed(_ context: AssembledPromptContext, for backend: ModelCatalog.Backend) -> AssembledPromptContext {
        guard backend == .vlm else { return context }

        let evidence = context.retrievedEvidence.prefix(2).map {
            truncate($0, maxTokens: 180)
        }
        let tools = context.toolResultSummaries.prefix(1).map {
            truncate($0, maxTokens: 120)
        }
        let messages = Array(context.recentMessages.suffix(3))

        return AssembledPromptContext(
            systemPrompt: truncate(context.systemPrompt, maxTokens: 400),
            activeSkillInstructions: nil,
            retrievedEvidence: evidence,
            recentMessages: messages,
            toolResultSummaries: tools,
            totalEstimatedTokens: context.totalEstimatedTokens
        )
    }

    private static func truncate(_ text: String, maxTokens: Int) -> String {
        let maxChars = maxTokens * 4
        guard text.count > maxChars else { return text }
        let index = text.index(text.startIndex, offsetBy: maxChars)
        return String(text[..<index]) + "…"
    }
}
