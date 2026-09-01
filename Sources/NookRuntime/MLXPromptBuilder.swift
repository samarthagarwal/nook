import Foundation
import MLXLMCommon
import NookCore

enum MLXPromptBuilder {
    static func chatMessages(from context: AssembledPromptContext) -> [Chat.Message] {
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
        let systemText = systemParts.joined(separator: "\n\n")

        var pendingToolNotes: [String] = []
        var turns: [Turn] = []

        for message in context.recentMessages {
            switch message.role {
            case .user:
                flushPendingToolNotes(into: &pendingToolNotes, turns: &turns)
                appendTurn(
                    role: .user,
                    content: message.content,
                    images: imageInputs(for: message),
                    to: &turns
                )
            case .assistant:
                flushPendingToolNotes(into: &pendingToolNotes, turns: &turns)
                guard !message.content.isEmpty else { continue }
                appendTurn(role: .assistant, content: message.content, images: [], to: &turns)
            case .localTool, .externalTool:
                if let note = toolNote(for: message) {
                    pendingToolNotes.append(note)
                }
            }
        }
        flushPendingToolNotes(into: &pendingToolNotes, turns: &turns)

        if turns.first?.role == .assistant {
            turns.insert(Turn(role: .user, content: "Continue from here.", images: []), at: 0)
        }

        guard !turns.isEmpty else {
            return [.init(role: .user, content: systemText)]
        }

        if turns[0].role == .user {
            turns[0].content = systemText + "\n\n" + turns[0].content
        } else {
            turns.insert(Turn(role: .user, content: systemText, images: []), at: 0)
        }

        return turns.map { Chat.Message(role: $0.role, content: $0.content, images: $0.images) }
    }

    private struct Turn {
        var role: Chat.Message.Role
        var content: String
        var images: [UserInput.Image]
    }

    private static func appendTurn(
        role: Chat.Message.Role,
        content: String,
        images: [UserInput.Image],
        to turns: inout [Turn]
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }

        if let last = turns.last, last.role == role {
            turns[turns.count - 1].content = [last.content, trimmed]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            if role == .user, !images.isEmpty {
                turns[turns.count - 1].images.append(contentsOf: images)
            }
            return
        }

        turns.append(Turn(role: role, content: trimmed, images: images))
    }

    private static func flushPendingToolNotes(into pending: inout [String], turns: inout [Turn]) {
        guard !pending.isEmpty else { return }
        let noteBlock = pending.joined(separator: "\n")
        pending.removeAll()
        if turns.last?.role == .user {
            turns[turns.count - 1].content += "\n\n" + noteBlock
        } else {
            appendTurn(role: .user, content: noteBlock, images: [], to: &turns)
        }
    }

    private static func toolNote(for message: NookCore.Message) -> String? {
        if let text = message.localToolText, !text.isEmpty {
            return text
        }
        if let external = message.externalToolData {
            let body = external.lines.joined(separator: "\n")
            return "\(external.toolName)\n\(body)"
        }
        return nil
    }

    private static func imageInputs(for message: NookCore.Message) -> [UserInput.Image] {
        guard let path = message.attachedImageName else {
            return []
        }

        let url: URL?
        if path.hasPrefix("file://"), let parsed = URL(string: path) {
            url = parsed
        } else if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let candidate = documents.appendingPathComponent("Attachments").appendingPathComponent(path)
            url = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        } else {
            url = nil
        }

        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        return [.url(url)]
    }
}
