import Foundation
import LiteRTLM
import NookCore

/// Maps Nook prompt context into LiteRT-LM conversation inputs.
enum LiteRTPromptBuilder {
    struct BuiltPrompt {
        let systemText: String
        let history: [LiteRTLM.Message]
        let latestUser: LiteRTLM.Message
    }

    static func build(from context: AssembledPromptContext) -> BuiltPrompt {
        var instructionParts: [String] = [context.systemPrompt]
        if let skill = context.activeSkillInstructions, !skill.isEmpty {
            instructionParts.append("Active skill instructions:\n\(skill)")
        }
        if !context.retrievedEvidence.isEmpty {
            let evidence = context.retrievedEvidence.joined(separator: "\n\n")
            instructionParts.append(
                """
                Retrieved knowledge — verbatim passages from the user's scoped collections. \
                Use only these facts; do not invent document content:
                \(evidence)
                """
            )
        }
        if !context.toolResultSummaries.isEmpty {
            let tools = context.toolResultSummaries.joined(separator: "\n")
            instructionParts.append("Tool results:\n\(tools)")
        }

        var history: [LiteRTLM.Message] = []
        var latestUser: LiteRTLM.Message?
        var pendingToolNotes: [String] = []

        for message in context.recentMessages {
            switch message.role {
            case .user:
                flushToolNotes(&pendingToolNotes, into: &history)
                let litert = makeUserMessage(from: message)
                if let previous = latestUser {
                    history.append(previous)
                }
                latestUser = litert
            case .assistant:
                flushToolNotes(&pendingToolNotes, into: &history)
                guard !message.content.isEmpty else { continue }
                if let previous = latestUser {
                    history.append(previous)
                    latestUser = nil
                }
                history.append(LiteRTLM.Message(message.content, role: .model))
            case .localTool, .externalTool:
                if let note = toolNote(for: message) {
                    pendingToolNotes.append(note)
                }
            }
        }
        flushToolNotes(&pendingToolNotes, into: &history)

        let userMessage = latestUser ?? LiteRTLM.Message("Hello")
        return BuiltPrompt(
            systemText: instructionParts.joined(separator: "\n\n"),
            history: history,
            latestUser: userMessage
        )
    }

    private static func makeUserMessage(from message: NookCore.Message) -> LiteRTLM.Message {
        var contents: [LiteRTLM.Content] = []
        if let imageName = message.attachedImageName, !imageName.isEmpty {
            let url = imageURL(named: imageName)
            if FileManager.default.fileExists(atPath: url.path) {
                contents.append(.imageFile(url.path))
            }
        }
        if !message.content.isEmpty {
            contents.append(.text(message.content))
        }
        if contents.isEmpty {
            contents.append(.text("Hello"))
        }
        return LiteRTLM.Message(contents: contents, role: .user)
    }

    private static func imageURL(named name: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("Nook", isDirectory: true)
            .appendingPathComponent("ChatImages", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func toolNote(for message: NookCore.Message) -> String? {
        if let local = message.localToolText, !local.isEmpty {
            return local
        }
        if let external = message.externalToolData {
            let body = external.lines.joined(separator: "\n")
            return "\(external.toolName):\n\(body)\n\(external.footer)"
        }
        return message.content.isEmpty ? nil : message.content
    }

    private static func flushToolNotes(
        _ notes: inout [String],
        into history: inout [LiteRTLM.Message]
    ) {
        guard !notes.isEmpty else { return }
        let text = "Tool results:\n" + notes.joined(separator: "\n\n")
        history.append(LiteRTLM.Message(text, role: .user))
        notes.removeAll()
    }
}
