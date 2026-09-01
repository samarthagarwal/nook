import Foundation
import MLXLMCommon
import NookCore

enum MLXPromptBuilder {
    static func chatMessages(from context: AssembledPromptContext) -> [Chat.Message] {
        var messages: [Chat.Message] = []

        var systemParts: [String] = [context.systemPrompt]
        if let skill = context.activeSkillInstructions, !skill.isEmpty {
            systemParts.append("Active skill instructions:\n\(skill)")
        }
        if !context.retrievedEvidence.isEmpty {
            let evidence = context.retrievedEvidence.joined(separator: "\n\n")
            systemParts.append("Retrieved knowledge (cite sources when you use them):\n\(evidence)")
        }
        if !context.toolResultSummaries.isEmpty {
            let tools = context.toolResultSummaries.joined(separator: "\n")
            systemParts.append("Tool results:\n\(tools)")
        }

        messages.append(.init(role: .system, content: systemParts.joined(separator: "\n\n")))

        for message in context.recentMessages {
            switch message.role {
            case .user:
                messages.append(.init(role: .user, content: message.content))
            case .assistant:
                if !message.content.isEmpty {
                    messages.append(.init(role: .assistant, content: message.content))
                }
            case .localTool, .externalTool:
                continue
            }
        }

        return messages
    }
}
