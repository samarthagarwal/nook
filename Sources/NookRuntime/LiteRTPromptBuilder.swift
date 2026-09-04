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
        // Split evidence into knowledge chunks (SOURCE prefix) and memory blocks (MEMORY prefix)
        // so each gets framing that matches what the model expects from the system prompt.
        let knowledgeBlocks = context.retrievedEvidence.filter { $0.hasPrefix("SOURCE") }
        let memoryBlocks = context.retrievedEvidence.filter { $0.hasPrefix("MEMORY") }

        if !knowledgeBlocks.isEmpty {
            let evidence = knowledgeBlocks.joined(separator: "\n\n")
            instructionParts.append(
                """
                Retrieved knowledge — verbatim passages from the user's scoped collections. \
                Use the best match to answer briefly; do not invent unrelated events:
                \(evidence)
                """
            )
        }
        if !memoryBlocks.isEmpty {
            let memories = memoryBlocks.joined(separator: "\n\n")
            instructionParts.append(
                """
                Past-chat MEMORY — context from previous conversations. \
                Use these to personalise your answer where relevant. \
                Do NOT echo or repeat these blocks in your reply; synthesise naturally.
                \(memories)
                """
            )
        }
        if !context.toolResultSummaries.isEmpty {
            let tools = context.toolResultSummaries.joined(separator: "\n")
            instructionParts.append(
                """
                Context gathered this turn (do not repeat verbatim). \
                Use it to answer the user if relevant. \
                If the user needs something not covered here, call the appropriate listed tool — \
                never say you cannot use a tool that is listed:
                \(tools)
                """
            )
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
        return """
        You can call tools when needed. Available tools:
        \(lines.joined(separator: "\n"))

        Pick the tool whose name/description best matches the user's request. \
        Use an exact name from this list — never a Skill name. \
        Tool names use dot notation: server.tool_name (for example exa.web_search_exa). \
        Do not call a tool that is not in this list. \
        Never invent a datetime — copy yyyy-MM-dd HH:mm from the user or a tool result, \
        or stop and ask.

        To call a tool, reply with ONLY a tool call (no markdown, no prose). Prefer Gemma format:
        <|tool_call>call:TOOL_NAME{query:"..."}<tool_call|>

        JSON is also accepted:
        {"name":"TOOL_NAME","arguments":{"query":"..."}}

        Replace TOOL_NAME with an exact name from the list above (including the server prefix). \
        Keep arguments minimal.

        After tool results are provided, answer normally from those results. Never say you cannot \
        browse the web, search online, or use a tool that is listed above or that just returned results. \
        For follow-up questions that need fresh external data, call the tool again instead of declining.
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
        if description.count > 320 {
            shortDescription = String(description.prefix(317)) + "..."
        } else {
            shortDescription = description
        }

        var paramNames: [String] = []
        if let parameters = function?["parameters"] as? [String: any Sendable],
           let properties = parameters["properties"] as? [String: any Sendable] {
            paramNames = properties.keys.sorted()
        }
        var line = name
        // Show the bare tool name (without server prefix) as a reminder so the model
        // knows what the suffix looks like, which helps when reproducing `server.tool_name`.
        if let dotIndex = name.firstIndex(of: ".") {
            let shortName = String(name[name.index(after: dotIndex)...])
            if !shortName.isEmpty {
                line += " (short: \(shortName))"
            }
        }
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
