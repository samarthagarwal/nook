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

    static func build(
        from context: AssembledPromptContext,
        toolSchemas: [AgentToolSpec] = []
    ) -> BuiltPrompt {
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
        if let toolsBlock = toolsInstruction(from: toolSchemas) {
            instructionParts.append(toolsBlock)
        }

        var history: [LiteRTLM.Message] = []
        var latestUser: LiteRTLM.Message?

        for message in context.recentMessages {
            switch message.role {
            case .user:
                let litert = makeUserMessage(from: message)
                if let previous = latestUser {
                    history.append(previous)
                }
                latestUser = litert
            case .assistant:
                guard !message.content.isEmpty else { continue }
                if let previous = latestUser {
                    history.append(previous)
                    latestUser = nil
                }
                history.append(LiteRTLM.Message(message.content, role: .model))
            case .localTool, .externalTool:
                // Prior-turn tool payloads are shown in the UI but omitted from model
                // context — they blow the on-device window, and the assistant reply
                // already summarized what mattered. Current-turn results still arrive
                // via `toolResultSummaries`.
                break
            }
        }

        let userMessage = latestUser ?? LiteRTLM.Message("Hello")
        return BuiltPrompt(
            systemText: instructionParts.joined(separator: "\n\n"),
            history: history,
            latestUser: userMessage
        )
    }

    private static func toolsInstruction(from schemas: [AgentToolSpec]) -> String? {
        guard !schemas.isEmpty else { return nil }
        var lines: [String] = []
        for schema in schemas {
            guard let summary = compactToolSummary(schema) else { continue }
            lines.append("- \(summary)")
        }
        guard !lines.isEmpty else { return nil }
        let exampleName = compactToolSummary(schemas[0])?.split(separator: ":").first.map(String.init)
            ?? "TOOL_NAME"
        return """
        You can call tools when needed. Available tools:
        \(lines.joined(separator: "\n"))

        To call a tool, reply with ONLY a tool call (no markdown, no prose). Prefer Gemma format:
        <|tool_call>call:\(exampleName){query:"..."}<tool_call|>

        JSON is also accepted:
        {"name":"\(exampleName)","arguments":{"query":"..."}}

        Use the exact tool name from the list. Keep arguments minimal. After tool results are provided, answer normally.
        """
    }

    /// Short, model-friendly tool line: `name: description. Params: a, b`
    private static func compactToolSummary(_ schema: AgentToolSpec) -> String? {
        let function = schema["function"] as? [String: any Sendable]
        let name = (function?["name"] as? String) ?? (schema["name"] as? String)
        guard let name, !name.isEmpty else { return nil }

        let description = ((function?["description"] as? String) ?? (schema["description"] as? String) ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shortDescription: String
        if description.count > 140 {
            shortDescription = String(description.prefix(137)) + "..."
        } else {
            shortDescription = description
        }

        var paramNames: [String] = []
        if let parameters = function?["parameters"] as? [String: any Sendable],
           let properties = parameters["properties"] as? [String: any Sendable] {
            paramNames = properties.keys.sorted()
        }
        var line = name
        if !shortDescription.isEmpty {
            line += ": \(shortDescription)"
        }
        if !paramNames.isEmpty {
            line += " Params: \(paramNames.joined(separator: ", "))"
        }
        return line
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
}
