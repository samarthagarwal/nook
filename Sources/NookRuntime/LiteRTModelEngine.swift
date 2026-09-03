import Foundation
import LiteRTLM
import NookCore

/// Serial wrapper around LiteRT-LM `Engine` + per-turn `Conversation`.
/// Uses a lock instead of an actor because LiteRTLM's `Conversation` / `ConversationConfig`
/// are not Sendable under Swift 6.
final class LiteRTModelEngine: @unchecked Sendable {
    /// Total context window for LiteRT-LM (input + reserved generation headroom).
    /// Kept modest for on-device memory; still well above prior 1024 that broke MCP chats.
    private static let engineContextTokens = 4096

    private let lock = NSLock()
    private var engine: Engine?
    private var loadedModelPath: String?
    private var loadedOnCPU = false
    private var cancelRequested = false
    private var activeConversation: LiteRTLM.Conversation?

    var isModelLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return engine != nil
    }

    func load(modelPath: String, forceCPU: Bool = false) async throws {
        if !forceCPU,
           let existingPath = withLock({ loadedModelPath }),
           existingPath == modelPath,
           let engine = withLock({ engine }),
           await engine.isInitialized() {
            return
        }

        await unload()
        // Extra settle time so Metal / mmap address space can reclaim after a failed map.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let preferCPU = forceCPU
        print(
            "[LiteRT] Loading \(URL(fileURLWithPath: modelPath).lastPathComponent) " +
            "(\(preferCPU ? "CPU" : "GPU")); allocatable: \(DeviceMemoryBudget.formattedAvailable())"
        )

        if preferCPU {
            try await mount(modelPath: modelPath, backend: .cpu(), label: "CPU")
            return
        }

        do {
            try await mount(modelPath: modelPath, backend: .gpu, label: "GPU, no MTP")
        } catch {
            print("[LiteRT] GPU init failed (\(error.localizedDescription)); retrying on CPU")
            await unload()
            try? await Task.sleep(nanoseconds: 150_000_000)
            try await mount(modelPath: modelPath, backend: .cpu(), label: "CPU fallback")
        }
    }

    func unload() async {
        cancelActiveConversation()
        withLock {
            engine = nil
            loadedModelPath = nil
            loadedOnCPU = false
            cancelRequested = false
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func requestCancel() {
        withLock { cancelRequested = true }
        cancelActiveConversation()
    }

    func generateStreaming(
        promptContext: AssembledPromptContext,
        request: AgentGenerationRequest = .textOnly,
        toolExecutor: (@Sendable (String, ToolArguments) async throws -> ToolExecutionResult)? = nil,
        maxOutputTokens: Int = 512,
        onToken: @escaping @Sendable (String) -> Void,
        onToolEvent: (@Sendable (AgentToolEvent) -> Void)? = nil
    ) async throws -> AgentGenerationResult {
        do {
            return try await generateWithTools(
                promptContext: promptContext,
                request: request,
                toolExecutor: toolExecutor,
                maxOutputTokens: maxOutputTokens,
                onToken: onToken,
                onToolEvent: onToolEvent
            )
        } catch {
            guard Self.isBrokenEmbedderOrMmapError(error) else { throw error }
            guard let path = withLock({ loadedModelPath }) else { throw error }
            let alreadyCPU = withLock({ loadedOnCPU })
            print(
                "[LiteRT] Prefill failed after incomplete mmap " +
                "(\(error.localizedDescription)); " +
                (alreadyCPU ? "already on CPU — giving up" : "remounting on CPU")
            )
            await unload()
            Self.clearCompilationCache()
            guard !alreadyCPU else {
                throw LiteRTModelRuntimeError.insufficientMemory(
                    detail: error.localizedDescription
                )
            }
            try await load(modelPath: path, forceCPU: true)
            do {
                return try await generateWithTools(
                    promptContext: promptContext,
                    request: request,
                    toolExecutor: toolExecutor,
                    maxOutputTokens: maxOutputTokens,
                    onToken: onToken,
                    onToolEvent: onToolEvent
                )
            } catch {
                await unload()
                if Self.isBrokenEmbedderOrMmapError(error) {
                    throw LiteRTModelRuntimeError.insufficientMemory(
                        detail: error.localizedDescription
                    )
                }
                throw error
            }
        }
    }

    // MARK: - Private

    private func generateWithTools(
        promptContext: AssembledPromptContext,
        request: AgentGenerationRequest,
        toolExecutor: (@Sendable (String, ToolArguments) async throws -> ToolExecutionResult)?,
        maxOutputTokens: Int,
        onToken: @escaping @Sendable (String) -> Void,
        onToolEvent: (@Sendable (AgentToolEvent) -> Void)?
    ) async throws -> AgentGenerationResult {
        let offeringTools = toolExecutor != nil && !request.toolSchemas.isEmpty
        var workingContext = promptContext
        var citations: [Citation] = []
        var finalText = ""
        var executedTools = false
        let maxRounds = max(0, request.maxToolRounds)

        if offeringTools, let toolExecutor {
            print("[LiteRT] Offering \(request.toolSchemas.count) tool schema(s); maxRounds=\(maxRounds)")
            for round in 0..<maxRounds {
                let assembled = try await generateOnce(
                    promptContext: workingContext,
                    toolSchemas: request.toolSchemas,
                    maxOutputTokens: max(maxOutputTokens, 384),
                    streamTokens: false,
                    onToken: onToken
                )
                print("[LiteRT] Tool round \(round) output (\(assembled.count) chars): \(assembled.prefix(400))")

                let calls = LiteRTToolCallParser.parse(from: assembled)
                if !calls.isEmpty {
                    var resultBlocks: [String] = []
                    for call in calls {
                        print("[LiteRT] Executing tool \(call.name) args=\(call.arguments.keys.sorted())")
                        let result = try await toolExecutor(call.name, call.arguments)
                        citations.append(contentsOf: result.citations)
                        onToolEvent?(
                            AgentToolEvent(
                                toolName: call.name,
                                displayText: result.displayText,
                                citations: result.citations,
                                chunks: result.chunks,
                                isExternal: result.isExternal
                            )
                        )
                        // Cap what we feed back into the model — UI still gets full displayText.
                        let clipped = Self.truncate(result.textForModel, maxChars: 1_500)
                        resultBlocks.append("\(call.name):\n\(clipped)")
                        executedTools = true
                    }

                    workingContext = AssembledPromptContext(
                        systemPrompt: workingContext.systemPrompt,
                        activeSkillInstructions: workingContext.activeSkillInstructions,
                        retrievedEvidence: workingContext.retrievedEvidence,
                        recentMessages: workingContext.recentMessages,
                        toolResultSummaries: [
                            """
                            Tool results:
                            \(resultBlocks.joined(separator: "\n\n"))

                            Answer the user's question using these results. Be concise and factual. \
                            Do not emit tool JSON or <|tool_call> / call:NAME syntax. \
                            Do not say you lack web access or cannot use tools — \
                            these results came from a successful tool call.
                            """
                        ],
                        totalEstimatedTokens: workingContext.totalEstimatedTokens
                    )
                    // After tools run, leave the loop and generate a final prose answer.
                    break
                }

                if LiteRTToolCallParser.looksLikeToolAttempt(assembled) {
                    print("[LiteRT] Tool call parse failed; raw=\(assembled.prefix(400))")
                    if round + 1 < maxRounds {
                        workingContext = AssembledPromptContext(
                            systemPrompt: workingContext.systemPrompt,
                            activeSkillInstructions: workingContext.activeSkillInstructions,
                            retrievedEvidence: workingContext.retrievedEvidence,
                            recentMessages: workingContext.recentMessages,
                            toolResultSummaries: [
                                """
                                Your previous tool call was invalid or truncated. \
                                Reply with ONLY complete JSON like:
                                {"name":"TOOL_NAME","arguments":{"query":"..."}}
                                No markdown fences.
                                """
                            ],
                            totalEstimatedTokens: workingContext.totalEstimatedTokens
                        )
                        continue
                    }
                    finalText = "I couldn't complete the tool call. Please try asking again."
                    onToken(finalText)
                    return AgentGenerationResult(text: finalText, citations: citations)
                }

                // Model answered in prose without calling a tool — use that.
                let visible = LiteRTToolCallParser.visibleText(from: assembled)
                if !visible.isEmpty {
                    onToken(visible)
                    return AgentGenerationResult(
                        text: visible.trimmingCharacters(in: .whitespacesAndNewlines),
                        citations: citations
                    )
                }
            }
        }

        // Final prose turn (no tool schemas). Always run when we still need an answer.
        if finalText.isEmpty {
            print("[LiteRT] Final answer turn (executedTools=\(executedTools))")
            finalText = try await generateFinalProseAnswer(
                promptContext: workingContext,
                maxOutputTokens: maxOutputTokens,
                executedTools: executedTools,
                onToken: onToken
            )
            print("[LiteRT] Final answer (\(finalText.count) chars): \(finalText.prefix(200))")
        }

        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let fallback = executedTools
                ? "I ran the tool but couldn't form a follow-up answer. Please try asking again."
                : "I couldn't generate a reply. Please try again."
            print("[LiteRT] Empty model output — using fallback")
            onToken(fallback)
            return AgentGenerationResult(text: fallback, citations: citations)
        }

        return AgentGenerationResult(text: trimmed, citations: citations)
    }

    /// Generates a user-visible answer and never returns raw tool-call markup.
    private func generateFinalProseAnswer(
        promptContext: AssembledPromptContext,
        maxOutputTokens: Int,
        executedTools: Bool,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        // Don't stream until sanitized — otherwise `<|tool_call>…` leaks into the bubble.
        var context = promptContext
        for attempt in 0..<2 {
            let assembled = try await generateOnce(
                promptContext: context,
                toolSchemas: [],
                maxOutputTokens: maxOutputTokens,
                streamTokens: false,
                onToken: onToken
            )
            let visible = LiteRTToolCallParser.visibleText(from: assembled)
            if !visible.isEmpty {
                onToken(visible)
                return visible
            }

            let dirty = LiteRTToolCallParser.looksLikeToolAttempt(assembled)
                || !LiteRTToolCallParser.parse(from: assembled).isEmpty
            if dirty, attempt == 0 {
                print("[LiteRT] Final turn emitted tool markup; retrying prose-only")
                context = AssembledPromptContext(
                    systemPrompt: context.systemPrompt,
                    activeSkillInstructions: context.activeSkillInstructions,
                    retrievedEvidence: context.retrievedEvidence,
                    recentMessages: context.recentMessages,
                    toolResultSummaries: [
                        """
                        \(context.toolResultSummaries.joined(separator: "\n\n"))

                        Write the final answer now in plain Markdown for the user. \
                        Do NOT emit <|tool_call>, call:NAME{…}, JSON tool calls, or code fences. \
                        Just answer the question.
                        """
                    ],
                    totalEstimatedTokens: context.totalEstimatedTokens
                )
                continue
            }

            // Never surface raw tool syntax.
            if dirty {
                break
            }
            // Non-tool empty/whitespace — fall through.
            if !assembled.isEmpty {
                onToken(assembled)
                return assembled
            }
        }

        let fallback = executedTools
            ? "I ran the tool but couldn't form a follow-up answer. Please try asking again."
            : "I couldn't generate a reply. Please try again."
        onToken(fallback)
        return fallback
    }

    private func mount(
        modelPath: String,
        backend: LiteRTLM.Backend,
        label: String
    ) async throws {
        // Context must fit system + tools + recent chat + generation.
        // 1024 was too small once MCP tool results enter history (prompts hit 2.5k+ tokens).
        let config = try EngineConfig(
            modelPath: modelPath,
            backend: backend,
            visionBackend: nil,
            audioBackend: nil,
            maxNumTokens: Self.engineContextTokens,
            cacheDir: LiteRTModelPaths.compilationCacheDirectory.path
        )

        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableSpeculativeDecoding = false

        let engine = Engine(engineConfig: config)
        try await engine.initialize()
        withLock {
            self.engine = engine
            self.loadedModelPath = modelPath
            self.loadedOnCPU = {
                if case .cpu = backend { return true }
                return false
            }()
        }
        print("[LiteRT] Engine initialized (\(label)) at \(modelPath) maxNumTokens=\(Self.engineContextTokens)")
    }

    private func generateOnce(
        promptContext: AssembledPromptContext,
        toolSchemas: [AgentToolSpec],
        maxOutputTokens: Int,
        streamTokens: Bool,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let engine = withLock({ engine }) else {
            throw LiteRTModelRuntimeError.modelNotReady(underlying: nil)
        }

        withLock { cancelRequested = false }
        let trimmed = Self.trimContext(promptContext)
        let built = LiteRTPromptBuilder.build(from: trimmed, toolSchemas: toolSchemas)
        let approxChars = built.systemText.count
            + built.history.reduce(0) { $0 + $1.toString.count }
            + built.latestUser.toString.count
        print("[LiteRT] Prompt ~\(approxChars) chars (~\(approxChars / 4) tokens est), tools=\(toolSchemas.count)")

        let temperature: Float = toolSchemas.isEmpty ? 0.3 : 0.0
        let sampler = try SamplerConfig(topK: 40, topP: 0.95, temperature: temperature)
        let conversationConfig = ConversationConfig(
            systemMessage: built.systemText.isEmpty
                ? nil
                : LiteRTLM.Message(built.systemText, role: .system),
            initialMessages: built.history,
            samplerConfig: sampler,
            automaticToolCalling: false
        )
        let conversation = try await engine.createConversation(with: conversationConfig)
        withLock { activeConversation = conversation }
        defer {
            withLock { activeConversation = nil }
        }

        var assembled = ""

        do {
            for try await chunk in conversation.sendMessageStream(
                built.latestUser,
                maxOutputTokens: maxOutputTokens
            ) {
                if withLock({ cancelRequested }) || Task.isCancelled {
                    try? conversation.cancel()
                    throw CancellationError()
                }
                let text = chunk.toString
                guard !text.isEmpty else { continue }

                var delta = ""
                if text.hasPrefix(assembled) {
                    delta = String(text.dropFirst(assembled.count))
                    assembled = text
                } else if assembled.hasPrefix(text) {
                    continue
                } else {
                    delta = text
                    assembled += text
                }
                if streamTokens, !delta.isEmpty {
                    onToken(delta)
                }
            }
        } catch {
            try? conversation.cancel()
            throw error
        }

        return assembled.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cancelActiveConversation() {
        let conversation = withLock { () -> LiteRTLM.Conversation? in
            let current = activeConversation
            activeConversation = nil
            return current
        }
        try? conversation?.cancel()
    }

    static func isBrokenEmbedderOrMmapError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
            + " "
            + error.localizedDescription.lowercased()
        return message.contains("per_layer_embedding")
            || message.contains("per_layer_embedding_lookup")
            || message.contains("input_per_layer_embeddings")
            || message.contains("cannot allocate memory")
            || message.contains("failed to map")
            || message.contains("mmap")
            || (message.contains("is null") && message.contains("embedding"))
    }

    static func clearCompilationCache() {
        let cache = LiteRTModelPaths.compilationCacheDirectory
        try? FileManager.default.removeItem(at: cache)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        print("[LiteRT] Cleared compilation cache at \(cache.path)")
    }

    /// Keep prompt inside the engine context window (leave headroom for generation).
    private static func trimContext(_ context: AssembledPromptContext) -> AssembledPromptContext {
        let evidence = context.retrievedEvidence.prefix(2).map { truncate($0, maxChars: 600) }
        let tools = context.toolResultSummaries.prefix(1).map { truncate($0, maxChars: 1_200) }
        let messages = context.recentMessages.suffix(4).map(truncateMessage(_:))
        return AssembledPromptContext(
            systemPrompt: truncate(context.systemPrompt, maxChars: 1_000),
            activeSkillInstructions: context.activeSkillInstructions.map { truncate($0, maxChars: 400) },
            retrievedEvidence: Array(evidence),
            recentMessages: Array(messages),
            toolResultSummaries: Array(tools),
            totalEstimatedTokens: context.totalEstimatedTokens
        )
    }

    private static func truncateMessage(_ message: NookCore.Message) -> NookCore.Message {
        var copy = message
        copy.content = truncate(message.content, maxChars: 600)
        if let local = message.localToolText {
            copy.localToolText = truncate(local, maxChars: 300)
        }
        if let external = message.externalToolData {
            let clipped = truncate(external.lines.joined(separator: "\n"), maxChars: 400)
            copy.externalToolData = ExternalToolExecution(
                toolName: external.toolName,
                lines: clipped.components(separatedBy: "\n"),
                footer: truncate(external.footer, maxChars: 80)
            )
        }
        return copy
    }

    private static func truncate(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let index = text.index(text.startIndex, offsetBy: maxChars)
        return String(text[..<index]) + "…"
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
