import Foundation
import MLXLMCommon
import NookCore

enum MLXPromptBuilder {
    struct BuiltPrompt {
        let instructions: String
        let messages: [Chat.Message]
    }

    /// Builds chat turns for native tool calling. System text becomes ChatSession `instructions`
    /// so the tokenizer can place tools in the developer/system turn correctly.
    static func build(from context: AssembledPromptContext) -> BuiltPrompt {
        var instructionParts: [String] = [context.systemPrompt]
        if let skill = context.activeSkillInstructions, !skill.isEmpty {
            instructionParts.append("Active skill instructions:\n\(skill)")
        }
        if !context.retrievedEvidence.isEmpty {
            let evidence = context.retrievedEvidence.joined(separator: "\n\n")
            instructionParts.append("Retrieved knowledge (cite sources when you use them):\n\(evidence)")
        }
        if !context.toolResultSummaries.isEmpty {
            let tools = context.toolResultSummaries.joined(separator: "\n")
            instructionParts.append("Tool results:\n\(tools)")
        }

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

        if turns.isEmpty {
            turns.append(Turn(role: .user, content: "Hello", images: []))
        }

        return BuiltPrompt(
            instructions: instructionParts.joined(separator: "\n\n"),
            messages: turns.map { Chat.Message(role: $0.role, content: $0.content, images: $0.images) }
        )
    }

    /// Legacy helper used by tests / call sites that still want a flat message list.
    static func chatMessages(from context: AssembledPromptContext) -> [Chat.Message] {
        let built = build(from: context)
        guard var first = built.messages.first else {
            return [.user(built.instructions)]
        }
        if first.role == .user {
            first = .user(built.instructions + "\n\n" + first.content, images: first.images)
            var rest = built.messages
            rest[0] = first
            return rest
        }
        return [.user(built.instructions)] + built.messages
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
