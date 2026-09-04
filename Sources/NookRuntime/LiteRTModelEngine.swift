import Foundation
import LiteRTLM
import NookCore

/// Serial wrapper around LiteRT-LM `Engine` + per-turn `Conversation`.
/// Uses a lock instead of an actor because LiteRTLM's `Conversation` / `ConversationConfig`
/// are not Sendable under Swift 6.
final class LiteRTModelEngine: @unchecked Sendable {
    /// Total context window for LiteRT-LM (input + reserved generation headroom).
    /// 8192 matches Gemma 4 E2B's training context and ContextBudgetConfig.totalContextLimit.
    /// Modern iPhones (A16+) handle this comfortably; the runtime falls back to CPU if GPU
    /// mmap fails under pressure, which avoids OOM rather than crashing.
    private static let engineContextTokens = 8192

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
        maxOutputTokens: Int = 768,
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
        _ = toolExecutor
        _ = onToolEvent
        let proseOnly = request.responseMode == .proseOnly
        var assembled: String
        do {
            assembled = try await generateOnce(
                promptContext: promptContext,
                toolSchemas: request.toolSchemas,
                proseOnly: proseOnly,
                maxOutputTokens: max(maxOutputTokens, 384),
                streamTokens: false,
                onToken: onToken
            )
        } catch {
            // A constrained answer turn is a nice-to-have; never fail the turn
            // because the grammar could not be applied on this backend.
            guard proseOnly,
                  !(error is CancellationError),
                  !Self.isBrokenEmbedderOrMmapError(error) else { throw error }
            print("[LiteRT] Constrained answer turn failed (\(error.localizedDescription)); retrying unconstrained")
            assembled = try await generateOnce(
                promptContext: promptContext,
                toolSchemas: [],
                proseOnly: false,
                maxOutputTokens: max(maxOutputTokens, 384),
                streamTokens: false,
                onToken: onToken
            )
        }
        print("[LiteRT] Step (\(assembled.count) chars): \(assembled.prefix(400))")
        let parsed = LiteRTToolCallParser.parse(from: assembled)
        if !request.toolSchemas.isEmpty, !parsed.isEmpty {
            print("[LiteRT] Parsed \(parsed.count) tool call(s): \(parsed.map(\.name).joined(separator: ", "))")
            return AgentGenerationResult(
                text: "",
                toolCalls: parsed.map { AgentToolCall(name: $0.name, arguments: $0.arguments) }
            )
        }
        let visible = LiteRTToolCallParser.visibleText(from: assembled)
        if !visible.isEmpty {
            onToken(visible)
            return AgentGenerationResult(text: visible)
        }
        if LiteRTToolCallParser.looksLikeToolAttempt(assembled) {
            print("[LiteRT] Unparsed tool attempt; not showing raw markup")
            return AgentGenerationResult(text: "")
        }
        if !assembled.isEmpty {
            onToken(assembled)
            return AgentGenerationResult(text: assembled)
        }
        return AgentGenerationResult(text: "")
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
        proseOnly: Bool,
        maxOutputTokens: Int,
        streamTokens: Bool,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        do {
            return try await runConversation(
                promptContext: promptContext,
                toolSchemas: toolSchemas,
                proseOnly: proseOnly,
                maxOutputTokens: maxOutputTokens,
                streamTokens: streamTokens,
                onToken: onToken
            )
        } catch {
            guard Self.isDeadlineError(error) else { throw error }
            print("[LiteRT] Callback pool timeout; settling and retrying once")
            cancelActiveConversation()
            try? await Task.sleep(nanoseconds: 300_000_000)
            return try await runConversation(
                promptContext: promptContext,
                toolSchemas: toolSchemas,
                proseOnly: proseOnly,
                maxOutputTokens: maxOutputTokens,
                streamTokens: streamTokens,
                onToken: onToken
            )
        }
    }

    /// llguidance grammar for a plain-text answer. Excluding `<` makes Gemma's
    /// `<|tool_call>` sentinel unreachable at the token level, so a synthesis turn
    /// cannot loop back into another tool call.
    private static var proseGrammar: ResponseFormat {
        ResponseFormat.regex(pattern: "[^<]{1,2000}")
    }

    private func runConversation(
        promptContext: AssembledPromptContext,
        toolSchemas: [AgentToolSpec],
        proseOnly: Bool,
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
        print("[LiteRT] Prompt ~\(approxChars) chars (~\(approxChars / 4) tokens est), tools=\(toolSchemas.count), evidence=\(trimmed.retrievedEvidence.count), toolResults=\(trimmed.toolResultSummaries.count), proseOnly=\(proseOnly)")

        let temperature: Float = toolSchemas.isEmpty ? 0.3 : 0.0
        let sampler = try SamplerConfig(topK: 40, topP: 0.95, temperature: temperature)
        let conversationConfig = ConversationConfig(
            systemMessage: built.systemText.isEmpty
                ? nil
                : LiteRTLM.Message(built.systemText, role: .system),
            initialMessages: built.history,
            samplerConfig: sampler,
            automaticToolCalling: false,
            enableResponseFormat: proseOnly
        )
        let conversation = try await engine.createConversation(with: conversationConfig)
        withLock { activeConversation = conversation }
        defer {
            try? conversation.cancel()
            withLock { activeConversation = nil }
        }

        var assembled = ""

        do {
            for try await chunk in conversation.sendMessageStream(
                built.latestUser,
                maxOutputTokens: maxOutputTokens,
                responseFormat: proseOnly ? Self.proseGrammar : nil
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

        try? await Task.sleep(nanoseconds: 120_000_000)
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

    static func isDeadlineError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
            + " "
            + error.localizedDescription.lowercased()
        return message.contains("deadline_exceeded")
            || message.contains("timeout waiting for all tasks")
            || message.contains("callback_thread_pool")
    }

    static func isBrokenEmbedderOrMmapError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
            + " "
            + error.localizedDescription.lowercased()
        // LiteRT reports several shapes for the same failure: GPU mmap left the
        // embedding lookup subgraph uninitialized, so the first prefill dies.
        return message.contains("per_layer_embedding")
            || message.contains("per_layer_embedding_lookup")
            || message.contains("input_per_layer_embeddings")
            || message.contains("embedding lookup model is not initialized")
            || message.contains("input embeddings required")
            || message.contains("cannot allocate memory")
            || message.contains("failed to map")
            || message.contains("mmap")
            || (message.contains("is null") && message.contains("embedding"))
            || (message.contains("failed_precondition") && message.contains("embedding"))
    }

    static func clearCompilationCache() {
        let cache = LiteRTModelPaths.compilationCacheDirectory
        try? FileManager.default.removeItem(at: cache)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        print("[LiteRT] Cleared compilation cache at \(cache.path)")
    }

    /// Keep prompt inside the engine context window (leave headroom for generation).
    private static func trimContext(_ context: AssembledPromptContext) -> AssembledPromptContext {
        let evidence = context.retrievedEvidence.prefix(3).map { truncate($0, maxChars: 900) }
        let tools = context.toolResultSummaries.prefix(2).map { truncate($0, maxChars: 1_500) }
        let messages = context.recentMessages.suffix(4).map(truncateMessage(_:))
        return AssembledPromptContext(
            // Knowledge grounding lives in the system prompt — 1000 chars was cutting it off.
            systemPrompt: truncate(context.systemPrompt, maxChars: 2_800),
            activeSkillInstructions: context.activeSkillInstructions.map { truncate($0, maxChars: 800) },
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
