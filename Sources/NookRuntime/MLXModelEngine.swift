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
        modelKey: String,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws {
        container = nil
        loadedModelKey = nil
        loadedBackend = nil

        let modelContainer: ModelContainer
        switch source {
        case .bundled(let directory):
            reportProgress(0.1, transfer: nil, to: progressHandler)
            print("[MLXModelEngine] Loading bundled model from \(directory.path) (\(backend))")
            modelContainer = try await loadContainer(
                backend: backend,
                from: directory
            )
            reportProgress(1.0, transfer: nil, to: progressHandler)

        case .remote(let repoId):
            let configuration = ModelConfiguration(id: repoId)
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
        restoreDefaultCacheLimit()
    }

    private func loadContainer(
        backend: ModelCatalog.Backend,
        from directory: URL
    ) async throws -> ModelContainer {
        switch backend {
        case .llm:
            return try await LLMModelFactory.shared.loadContainer(
                from: directory,
                using: #huggingFaceTokenizerLoader()
            )
        case .vlm:
            return try await VLMModelFactory.shared.loadContainer(
                from: directory,
                using: #huggingFaceTokenizerLoader()
            )
        }
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
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let container else {
            throw MLXModelEngineError.modelNotLoaded
        }

        resetCancellation()

        let messages = MLXPromptBuilder.chatMessages(from: promptContext)
        let maxTokens = loadedBackend == .vlm ? 512 : 768
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0.3
        )

        let session = ChatSession(
            container,
            generateParameters: parameters
        )

        var fullText = ""
        for try await chunk in session.streamResponse(to: messages) {
            if isCancellationRequested() || Task.isCancelled {
                break
            }
            fullText += chunk
            onToken(chunk)
        }

        if isCancellationRequested() || Task.isCancelled {
            throw CancellationError()
        }

        return fullText
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
