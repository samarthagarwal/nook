import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import NookCore
import Tokenizers

actor MLXModelEngine {
    private var container: ModelContainer?
    private var loadedModelKey: String?
    private var shouldCancelGeneration = false

    init() {
        MLX.Memory.cacheLimit = 512 * 1024 * 1024
    }

    var isModelLoaded: Bool {
        container != nil
    }

    func load(
        source: ModelLoadSource,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws {
        let modelKey: String
        switch source {
        case .bundled(let url):
            modelKey = "bundled:\(url.path)"
        case .remote(let repoId):
            modelKey = "remote:\(repoId)"
        }

        if loadedModelKey == modelKey, container != nil {
            reportProgress(1.0, transfer: nil, to: progressHandler)
            return
        }

        container = nil
        loadedModelKey = nil

        let modelContainer: ModelContainer
        switch source {
        case .bundled(let directory):
            reportProgress(0.1, transfer: nil, to: progressHandler)
            print("[MLXModelEngine] Loading bundled model from \(directory.path)")
            modelContainer = try await LLMModelFactory.shared.loadContainer(
                from: directory,
                using: #huggingFaceTokenizerLoader()
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

            modelContainer = try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: #huggingFaceTokenizerLoader(),
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
        let parameters = GenerateParameters(
            maxTokens: 1024,
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
