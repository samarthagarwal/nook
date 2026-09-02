import Foundation
import LiteRTLM
import NookCore

/// Serial wrapper around LiteRT-LM `Engine` + per-turn `Conversation`.
/// Uses a lock instead of an actor because LiteRTLM's `Conversation` / `ConversationConfig`
/// are not Sendable under Swift 6.
final class LiteRTModelEngine: @unchecked Sendable {
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
        maxOutputTokens: Int = 512,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        do {
            return try await generateOnce(
                promptContext: promptContext,
                maxOutputTokens: maxOutputTokens,
                onToken: onToken
            )
        } catch {
            // Gemma 4 can "initialize" even when mmap of per-layer embeddings failed;
            // the first prefill then throws. Remount on CPU once.
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
                return try await generateOnce(
                    promptContext: promptContext,
                    maxOutputTokens: maxOutputTokens,
                    onToken: onToken
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

    private func mount(
        modelPath: String,
        backend: LiteRTLM.Backend,
        label: String
    ) async throws {
        // Smaller KV helps mmap succeed on memory-constrained phones.
        let config = try EngineConfig(
            modelPath: modelPath,
            backend: backend,
            visionBackend: nil,
            audioBackend: nil,
            maxNumTokens: 1024,
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
        print("[LiteRT] Engine initialized (\(label)) at \(modelPath)")
    }

    private func generateOnce(
        promptContext: AssembledPromptContext,
        maxOutputTokens: Int,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let engine = withLock({ engine }) else {
            throw LiteRTModelRuntimeError.modelNotReady(underlying: nil)
        }

        withLock { cancelRequested = false }
        let trimmed = Self.trimContext(promptContext)
        let built = LiteRTPromptBuilder.build(from: trimmed)

        let sampler = try SamplerConfig(topK: 40, topP: 0.95, temperature: 0.3)
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

                if text.hasPrefix(assembled) {
                    let newPart = String(text.dropFirst(assembled.count))
                    assembled = text
                    if !newPart.isEmpty {
                        onToken(newPart)
                    }
                } else if assembled.hasPrefix(text) {
                    continue
                } else {
                    assembled += text
                    onToken(text)
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
            || message.contains("cannot allocate memory")
            || message.contains("failed to map")
            || message.contains("input_per_layer_embeddings")
    }

    static func clearCompilationCache() {
        let cache = LiteRTModelPaths.compilationCacheDirectory
        try? FileManager.default.removeItem(at: cache)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        print("[LiteRT] Cleared compilation cache at \(cache.path)")
    }

    /// Keep prompt small — long chats + large KV were hanging prefill and exhausting Metal.
    private static func trimContext(_ context: AssembledPromptContext) -> AssembledPromptContext {
        let evidence = context.retrievedEvidence.prefix(2).map { truncate($0, maxChars: 800) }
        let tools = context.toolResultSummaries.prefix(1).map { truncate($0, maxChars: 500) }
        let messages = Array(context.recentMessages.suffix(4))
        return AssembledPromptContext(
            systemPrompt: truncate(context.systemPrompt, maxChars: 1_200),
            activeSkillInstructions: context.activeSkillInstructions.map { truncate($0, maxChars: 400) },
            retrievedEvidence: Array(evidence),
            recentMessages: messages,
            toolResultSummaries: Array(tools),
            totalEstimatedTokens: context.totalEstimatedTokens
        )
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
