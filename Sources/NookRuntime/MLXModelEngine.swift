import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import NookCore
import Tokenizers

actor MLXModelEngine {
    private var container: ModelContainer?
    private var loadedModelKey: String?
    private var loadedBackend: ModelCatalog.Backend?
    private var loadedToolCallFormat: ToolCallFormat?
    private var shouldCancelGeneration = false
    private var inFlightLoad: Task<Void, Error>?

    init() {
        MLX.Memory.cacheLimit = 128 * 1024 * 1024
    }

    func restoreDefaultCacheLimit() {
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
    }

    func reduceMemoryFootprint() {
        MLX.Memory.cacheLimit = 128 * 1024 * 1024
        MLX.Memory.clearCache()
    }

    var isModelLoaded: Bool {
        container != nil
    }

    func load(
        source: ModelLoadSource,
        backend: ModelCatalog.Backend,
        toolCallFormat: ToolCallFormat,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws {
        let modelKey = Self.modelKey(for: source)

        if loadedModelKey == modelKey, loadedBackend == backend, container != nil {
            reportProgress(1.0, transfer: nil, to: progressHandler)
            return
        }

        if let inFlightLoad {
            try await inFlightLoad.value
            if loadedModelKey == modelKey, loadedBackend == backend, container != nil {
                reportProgress(1.0, transfer: nil, to: progressHandler)
                return
            }
        }

        let task = Task<Void, Error> {
            try await self.performLoad(
                source: source,
                backend: backend,
                toolCallFormat: toolCallFormat,
                modelKey: modelKey,
                progressHandler: progressHandler
            )
        }
        inFlightLoad = task
        defer { inFlightLoad = nil }
        try await task.value
    }

    private func performLoad(
        source: ModelLoadSource,
        backend: ModelCatalog.Backend,
        toolCallFormat: ToolCallFormat,
        modelKey: String,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws {
        container = nil
        loadedModelKey = nil
        loadedBackend = nil
        loadedToolCallFormat = nil

        let modelContainer: ModelContainer
        switch source {
        case .bundled(let directory):
            reportProgress(0.1, transfer: nil, to: progressHandler)
            print("[MLXModelEngine] Loading bundled model from \(directory.path) (\(backend), tools=\(toolCallFormat.rawValue))")
            modelContainer = try await loadContainer(
                backend: backend,
                configuration: ModelConfiguration(
                    directory: directory,
                    toolCallFormat: toolCallFormat
                )
            )
            reportProgress(1.0, transfer: nil, to: progressHandler)

        case .remote(let repoId):
            let configuration = ModelConfiguration(
                id: repoId,
                toolCallFormat: toolCallFormat
            )
            print("[MLXModelEngine] Loading \(repoId) (\(backend), tools=\(toolCallFormat.rawValue))")
            let logger = DownloadProgressLogger(label: repoId)
            let diskMonitor = HubDownloadDiskMonitor(repoId: repoId)
            let downloader = NookHubDownloader()
            reportProgress(0.02, transfer: nil, to: progressHandler)
            logger.phase("connecting to Hugging Face")
            logger.progress(mapped: 0.02, note: "starting")

            let loadStarted = Date()
            defer { diskMonitor.stop() }

            let coordinator = DownloadProgressCoordinator { merged in
                let uiFraction = ModelDownloadProgressMapper.mapTransfer(merged)
                let note = ModelDownloadProgressMapper.statusNote(for: merged, uiFraction: uiFraction)
                logger.progress(
                    mapped: uiFraction,
                    hubFraction: merged.fraction,
                    completedUnits: merged.completedBytes,
                    totalUnits: merged.totalBytes,
                    note: note
                )
                progressHandler(uiFraction, merged)
            }

            modelContainer = try await loadContainer(
                backend: backend,
                from: downloader,
                configuration: configuration,
                progressHandler: { progress in
                    let hubMapped = ModelDownloadProgressMapper.mapHubProgress(progress)
                    coordinator.updateHub(hubMapped.transfer)

                    if let total = hubMapped.transfer?.totalBytes, total > 0 {
                        diskMonitor.start(totalBytes: total) { diskTransfer in
                            coordinator.report(disk: diskTransfer)
                        }
                    }
                }
            )
            let elapsed = Int(Date().timeIntervalSince(loadStarted))
            reportProgress(0.90, transfer: nil, to: progressHandler)
            logger.progress(mapped: 0.90, note: "files cached, MLX loaded weights in \(elapsed)s")
            logger.phase("download complete")
            reportProgress(1.0, transfer: nil, to: progressHandler)
            logger.progress(mapped: 1.0)
        }

        container = modelContainer
        loadedModelKey = modelKey
        loadedBackend = backend
        loadedToolCallFormat = toolCallFormat
        if backend == .vlm {
            reduceMemoryFootprint()
        } else {
            restoreDefaultCacheLimit()
        }
    }

    private func loadContainer(
        backend: ModelCatalog.Backend,
        configuration: ModelConfiguration
    ) async throws -> ModelContainer {
        // Directory configs don't download; NookHubDownloader is unused for local paths.
        try await loadContainer(
            backend: backend,
            from: NookHubDownloader(),
            configuration: configuration,
            progressHandler: { _ in }
        )
    }

    private func loadContainer(
        backend: ModelCatalog.Backend,
        from downloader: NookHubDownloader,
        configuration: ModelConfiguration,
        progressHandler: @escaping @Sendable (Progress) -> Void
    ) async throws -> ModelContainer {
        switch backend {
        case .llm:
            return try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: progressHandler
            )
        case .vlm:
            return try await VLMModelFactory.shared.loadContainer(
                from: downloader,
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: progressHandler
            )
        }
    }

    private static func modelKey(for source: ModelLoadSource) -> String {
        switch source {
        case .bundled(let url):
            return "bundled:\(url.path)"
        case .remote(let repoId):
            return "remote:\(repoId)"
        }
    }

    private func reportProgress(
        _ value: Double,
        transfer: DownloadTransferProgress?,
        to progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) {
        let clamped = min(1.0, max(0.0, value))
        progressHandler(clamped, transfer)
    }

    func unload() {
        container = nil
        loadedModelKey = nil
        loadedBackend = nil
        loadedToolCallFormat = nil
        inFlightLoad?.cancel()
        inFlightLoad = nil
        reduceMemoryFootprint()
    }

    func cancelGeneration() {
        shouldCancelGeneration = true
    }

    private func resetCancellation() {
        shouldCancelGeneration = false
    }

    private func isCancellationRequested() -> Bool {
        shouldCancelGeneration
    }

    func generate(
        promptContext: AssembledPromptContext,
        request: AgentGenerationRequest = .textOnly,
        toolExecutor: (@Sendable (String, ToolArguments) async throws -> ToolExecutionResult)? = nil,
        onToken: @escaping @Sendable (String) -> Void,
        onToolEvent: (@Sendable (AgentToolEvent) -> Void)? = nil
    ) async throws -> AgentGenerationResult {
        guard let container else {
            throw MLXModelEngineError.modelNotLoaded
        }

        resetCancellation()

        let safeContext = MLXContextTrimmer.trimmed(promptContext, for: loadedBackend ?? .llm)
        let built = MLXPromptBuilder.build(from: safeContext)
        let maxTokens = loadedBackend == .vlm ? 256 : 768
        let offeringTools = toolExecutor != nil && !request.toolSchemas.isEmpty
        // Greedy decoding when native tools are offered — more reliable tool-call formatting.
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: offeringTools ? 0.0 : 0.3
        )

        MLX.Memory.clearCache()

        let toolSpecs: [ToolSpec]? = request.toolSchemas.isEmpty ? nil : request.toolSchemas
        let maxRounds = max(0, request.maxToolRounds)
        var citations: [Citation] = []
        var conversation = built.messages
        var fullText = ""
        var round = 0
        var allowTools = offeringTools

        print(
            "[MLXModelEngine] Generate backend=\(loadedBackend.map { "\($0)" } ?? "?") toolsFormat=\(loadedToolCallFormat?.rawValue ?? "?") offeringTools=\(offeringTools) schemas=\(request.toolSchemas.count)"
        )

        // Manual tool loop — do not use ChatSession.toolDispatch.
        // Some chat templates (e.g. Gemma) require tool messages to include `name`, which
        // MLX's `.tool(content, id:)` does not set, so auto-dispatch can fail on the
        // continuation turn. Inject results as a user turn instead (template-safe).
        while true {
            let offerTools = allowTools && round < maxRounds
            let session = ChatSession(
                container,
                instructions: built.instructions,
                generateParameters: parameters,
                tools: offerTools ? toolSpecs : nil,
                toolDispatch: nil
            )

            var pendingCalls: [ToolCall] = []
            var roundText = ""
            // streamDetails(to:) is consuming — copy so we can continue the conversation.
            let turnMessages = conversation

            for try await item in session.streamDetails(to: turnMessages) {
                if isCancellationRequested() || Task.isCancelled {
                    break
                }
                switch item {
                case .chunk(let chunk):
                    roundText += chunk
                    // Stream live only on the final (no-tools) turn so tool markup
                    // never flashes in the chat bubble.
                    if !offerTools, !chunk.isEmpty {
                        onToken(chunk)
                    }
                case .toolCall(let call):
                    pendingCalls.append(call)
                    print("[MLXModelEngine] Tool call: \(call.function.name) args=\(call.function.arguments)")
                case .info:
                    break
                @unknown default:
                    break
                }
            }

            if isCancellationRequested() || Task.isCancelled {
                throw CancellationError()
            }

            guard let toolExecutor, !pendingCalls.isEmpty else {
                if pendingCalls.isEmpty {
                    print("[MLXModelEngine] No tool calls this round (round \(round)); text length=\(roundText.count)")
                }

                let visible = Self.visibleAssistantText(roundText)
                if offerTools {
                    // Buffered this turn — emit once.
                    if visible != roundText {
                        print("[MLXModelEngine] Suppressed leaked/incomplete tool markup (\(roundText.count) chars)")
                    }
                    if !visible.isEmpty {
                        onToken(visible)
                    }
                    fullText += visible
                } else if visible != roundText {
                    print("[MLXModelEngine] Suppressed leaked/incomplete tool markup (\(roundText.count) chars)")
                    fullText = visible
                } else {
                    fullText += roundText
                }
                break
            }

            var resultBlocks: [String] = []
            for call in pendingCalls {
                let arguments: ToolArguments = call.function.arguments.mapValues { value in
                    ToolJSONValue.from(value.anyValue)
                }
                let result = try await toolExecutor(call.function.name, arguments)
                citations.append(contentsOf: result.citations)
                onToolEvent?(
                    AgentToolEvent(
                        toolName: call.function.name,
                        displayText: result.displayText,
                        citations: result.citations,
                        chunks: result.chunks,
                        isExternal: false
                    )
                )
                resultBlocks.append("\(call.function.name):\n\(result.textForModel)")
            }

            conversation.append(
                .user(
                    """
                    Tool results:
                    \(resultBlocks.joined(separator: "\n\n"))

                    Answer the user's question using only these results. Be concise and factual.
                    """
                )
            )
            // Force a final answer turn — avoid re-offering tools after results are injected.
            allowTools = false
            round += 1
            print("[MLXModelEngine] Injected \(pendingCalls.count) tool result(s); requesting final answer")
        }

        return AgentGenerationResult(text: fullText, citations: citations)
    }

    /// Never show raw tool-call markup in the chat bubble.
    private static func visibleAssistantText(_ text: String) -> String {
        let markers = [
            "<start_function_call>",
            "<end_function_call>",
            "<start_function_declaration>",
            "<end_function_declaration>",
            "<start_function_response>",
            "<end_function_response>",
            "<|tool_call>",
            "<tool_call|>",
            "<tool_call>",
            "</tool_call>",
        ]
        guard markers.contains(where: { text.contains($0) }) else {
            return text
        }
        return "The model started a tool call but didn’t finish it cleanly. Try asking again, or switch to Balanced for document questions."
    }
}

enum MLXModelEngineError: LocalizedError {
    case modelNotLoaded
    case generationTimedOut

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "The on-device model is not loaded yet."
        case .generationTimedOut:
            return "Generation took too long and was stopped."
        }
    }
}
