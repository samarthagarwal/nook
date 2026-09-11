import Foundation
import NookCore

/// OpenAI-compatible cloud runtime for testing the agentic loop with a capable model.
/// Implements the same `ModelRuntime` protocol as `LiteRTModelRuntime` — swap it in
/// via `NookInferenceConfig.backend = .cloud` without touching any session logic.
///
/// Streaming: uses `/v1/chat/completions` with `stream: true` and parses SSE lines.
/// Tool calls: accumulates per-index argument fragments, returns `AgentToolCall` array.
public final class OpenAIModelRuntime: ModelRuntime, @unchecked Sendable {

    public private(set) var activeTier: ModelTier
    public private(set) var downloadState: ModelDownloadState = .ready

    private let apiKey: String
    private let model: String
    private let lock = NSLock()
    private var isCancelled = false

    // MARK: - Init

    public init(
        apiKey: String,
        model: String = "gpt-4o-mini",
        activeTier: ModelTier = ModelTier.recommended
    ) {
        self.apiKey = apiKey
        self.model = model
        self.activeTier = activeTier
    }

    // MARK: - ModelRuntime

    public func switchTier(_ tier: ModelTier) async throws {
        activeTier = tier
    }

    public func downloadModel(
        tier: ModelTier,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws {
        // Cloud — nothing to download.
        activeTier = tier
        progressHandler(1.0, nil)
    }

    public func cancelGeneration() {
        withLock { isCancelled = true }
    }

    public func releaseLoadedModel() async {}

    // MARK: - Generation

    public func generateStreaming(
        promptContext: AssembledPromptContext,
        request: AgentGenerationRequest,
        toolExecutor: (@Sendable (String, ToolArguments) async throws -> ToolExecutionResult)?,
        onToken: @escaping @Sendable (String) -> Void,
        onToolEvent: (@Sendable (AgentToolEvent) -> Void)?
    ) async throws -> AgentGenerationResult {
        withLock { isCancelled = false }

        let messages = buildMessages(from: promptContext)

        // Build a sanitized name map: "calendar.search" → "calendar_search"
        // OpenAI only allows [a-zA-Z0-9_-] in function names.
        var sanitizedToOriginal: [String: String] = [:]
        let sanitizedSchemas: [[String: Any]] = request.toolSchemas.compactMap { spec in
            var any = schemaToAny(spec) as? [String: Any] ?? [:]
            guard var fn = any["function"] as? [String: Any],
                  let originalName = fn["name"] as? String else { return nil }
            let safe = originalName.replacingOccurrences(of: ".", with: "_")
                                   .replacingOccurrences(of: " ", with: "_")
            sanitizedToOriginal[safe] = originalName
            fn["name"] = safe
            any["function"] = fn
            return any
        }

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages,
        ]

        if !sanitizedSchemas.isEmpty {
            body["tools"] = sanitizedSchemas
            if request.responseMode == .proseOnly {
                body["tool_choice"] = "none"
            }
        }

        var urlReq = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        urlReq.httpMethod = "POST"
        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: urlReq)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // Read body for the error message
            var errBody = ""
            for try await line in bytes.lines { errBody += line }
            print("[OpenAI] HTTP \(http.statusCode): \(errBody.prefix(300))")
            throw OpenAIRuntimeError.httpError(http.statusCode, errBody)
        }

        // Per-index accumulator for streaming tool call chunks
        var pendingCalls: [Int: PendingToolCall] = [:]
        var fullText = ""

        for try await line in bytes.lines {
            if withLock({ isCancelled }) || Task.isCancelled { throw CancellationError() }
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { break }

            guard
                let data = payload.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let first = choices.first,
                let delta = first["delta"] as? [String: Any]
            else { continue }

            // --- Text token ---
            if let content = delta["content"] as? String, !content.isEmpty {
                fullText += content
                onToken(content)
            }

            // --- Tool call fragments ---
            if let toolCallChunks = delta["tool_calls"] as? [[String: Any]] {
                for chunk in toolCallChunks {
                    guard let index = chunk["index"] as? Int else { continue }
                    let id     = chunk["id"]   as? String ?? ""
                    let fn     = chunk["function"] as? [String: Any]
                    let name   = fn?["name"]      as? String ?? ""
                    let args   = fn?["arguments"] as? String ?? ""

                    if pendingCalls[index] == nil {
                        pendingCalls[index] = PendingToolCall(id: id, name: name, arguments: args)
                    } else {
                        pendingCalls[index]!.merge(id: id, name: name, args: args)
                    }
                }
            }
        }

        // --- Assemble completed tool calls (restore original names) ---
        if !pendingCalls.isEmpty {
            let calls = pendingCalls
                .keys.sorted()
                .compactMap { i -> AgentToolCall? in
                    guard let p = pendingCalls[i], !p.name.isEmpty else { return nil }
                    let originalName = sanitizedToOriginal[p.name] ?? p.name
                    return AgentToolCall(name: originalName, arguments: parseArguments(p.arguments))
                }
            if !calls.isEmpty {
                print("[OpenAI] Tool calls: \(calls.map(\.name).joined(separator: ", "))")
                return AgentGenerationResult(text: "", toolCalls: calls)
            }
        }

        return AgentGenerationResult(text: fullText)
    }

    // MARK: - Message assembly

    private func buildMessages(from context: AssembledPromptContext) -> [[String: Any]] {
        var messages: [[String: Any]] = []

        // System: base prompt + active skill + retrieved evidence + tool results
        var systemParts = [context.systemPrompt]
        if let skill = context.activeSkillInstructions, !skill.isEmpty {
            systemParts.append(skill)
        }
        if !context.retrievedEvidence.isEmpty {
            systemParts.append(
                "Retrieved context:\n" + context.retrievedEvidence.joined(separator: "\n\n")
            )
        }
        if !context.toolResultSummaries.isEmpty {
            systemParts.append(
                "Tool results:\n" + context.toolResultSummaries.joined(separator: "\n")
            )
        }
        messages.append(["role": "system", "content": systemParts.joined(separator: "\n\n")])

        // Chat history — user and assistant turns only
        for msg in context.recentMessages {
            switch msg.role {
            case .user:
                messages.append(["role": "user", "content": msg.content])
            case .assistant where !msg.content.isEmpty:
                messages.append(["role": "assistant", "content": msg.content])
            default:
                break  // localTool / externalTool metadata stays in the system prompt via toolResultSummaries
            }
        }

        // OpenAI requires at least one message and the last message must be from the user.
        // If history is empty after the system message, add a placeholder.
        let hasUserMessage = messages.contains { $0["role"] as? String == "user" }
        if !hasUserMessage {
            messages.append(["role": "user", "content": "Hello"])
        }

        return messages
    }

    // MARK: - JSON helpers

    /// Recursively converts `AgentToolSpec` ([String: any Sendable]) to plain `[String: Any]`
    /// so `JSONSerialization` can encode it.
    private func schemaToAny(_ value: any Sendable) -> Any {
        if let dict = value as? [String: any Sendable] {
            return dict.mapValues { schemaToAny($0) }
        } else if let arr = value as? [any Sendable] {
            return arr.map { schemaToAny($0) }
        } else {
            return value
        }
    }

    /// Parses a JSON object string from the model's `arguments` field into `ToolArguments`.
    private func parseArguments(_ jsonString: String) -> ToolArguments {
        guard
            let data = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json.mapValues { ToolJSONValue.from($0) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

// MARK: - Supporting types

private struct PendingToolCall {
    var id: String
    var name: String
    var arguments: String

    mutating func merge(id: String, name: String, args: String) {
        if !id.isEmpty   { self.id   = id }
        if !name.isEmpty { self.name = name }
        self.arguments += args
    }
}

public enum OpenAIRuntimeError: LocalizedError, Sendable {
    case httpError(Int, String)

    public var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "OpenAI API returned HTTP \(code). \(body.prefix(200))"
        }
    }
}
