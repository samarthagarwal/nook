import Foundation
import NookCore

#if canImport(UIKit)
import UIKit
#endif

/// On-device LiteRT-LM runtime (Gemma / Qwen `.litertlm` packages).
public final class LiteRTModelRuntime: ModelRuntime, @unchecked Sendable {
    public private(set) var activeTier: ModelTier
    public private(set) var downloadState: ModelDownloadState = .notDownloaded

    private let engine = LiteRTModelEngine()
    private let stateLock = NSLock()
    private var activeDownloadTask: Task<Void, Error>?
    private var activeGenerationTask: Task<AgentGenerationResult, Error>?

    public init(activeTier: ModelTier = ModelTier.recommended) {
        self.activeTier = activeTier
        if supports(tier: activeTier), isLocallyReady(tier: activeTier) {
            setDownloadState(.ready)
        }
        installBackgroundUnload()
    }

    public func switchTier(_ tier: ModelTier) async throws {
        guard supports(tier: tier) else {
            throw LiteRTModelRuntimeError.unsupportedTier(tier.name)
        }
        activeTier = tier
        await engine.unload()
        if isLocallyReady(tier: tier) || AppPreferences.isTierDownloaded(tier.id) {
            setDownloadState(.ready)
        } else {
            setDownloadState(.notDownloaded)
        }
    }

    public func downloadModel(
        tier: ModelTier,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws {
        guard supports(tier: tier) else {
            throw LiteRTModelRuntimeError.unsupportedTier(tier.name)
        }

        if let activeDownloadTask {
            try await activeDownloadTask.value
            if activeTier.id == tier.id, case .ready = downloadState {
                progressHandler(1.0, nil)
                return
            }
        }

        let task = Task<Void, Error> {
            try await self.performDownload(tier: tier, progressHandler: progressHandler)
        }
        setActiveDownloadTask(task)
        defer { setActiveDownloadTask(nil) }
        try await task.value
    }

    public func generateStreaming(
        promptContext: AssembledPromptContext,
        request: AgentGenerationRequest,
        toolExecutor: (@Sendable (String, ToolArguments) async throws -> ToolExecutionResult)?,
        onToken: @escaping @Sendable (String) -> Void,
        onToolEvent: (@Sendable (AgentToolEvent) -> Void)?
    ) async throws -> AgentGenerationResult {
        _ = toolExecutor
        _ = onToolEvent
        _ = request

        if ThermalStateMonitor.shared.currentAdvice == .throttled {
            throw LiteRTModelRuntimeError.deviceTooHot
        }

        guard case .ready = downloadState else {
            throw LiteRTModelRuntimeError.modelNotReady(underlying: nil)
        }

        // Stop any prior hung native stream before loading/generating again.
        await cancelAndDropGeneration(unloadWeights: false)
        try await ensureModelLoaded()

        let task = Task<AgentGenerationResult, Error> {
            let text = try await self.engine.generateStreaming(
                promptContext: promptContext,
                onToken: onToken
            )
            return AgentGenerationResult(text: text, citations: [])
        }
        setActiveGenerationTask(task)
        defer { setActiveGenerationTask(nil) }

        do {
            return try await withThrowingTaskGroup(of: AgentGenerationResult.self) { group in
                group.addTask {
                    try await task.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 90_000_000_000)
                    throw LiteRTModelRuntimeError.generationFailed(
                        underlying: URLError(.timedOut)
                    )
                }
                let result = try await group.next()!
                group.cancelAll()
                task.cancel()
                return result
            }
        } catch is CancellationError {
            await cancelAndDropGeneration(unloadWeights: true)
            throw CancellationError()
        } catch let error as LiteRTModelRuntimeError {
            await cancelAndDropGeneration(unloadWeights: true)
            throw error
        } catch {
            await cancelAndDropGeneration(unloadWeights: true)
            if LiteRTModelEngine.isBrokenEmbedderOrMmapError(error) {
                throw LiteRTModelRuntimeError.insufficientMemory(detail: error.localizedDescription)
            }
            throw LiteRTModelRuntimeError.generationFailed(underlying: error)
        }
    }

    public func cancelGeneration() {
        Task { await cancelAndDropGeneration(unloadWeights: false) }
    }

    public func releaseLoadedModel() async {
        await cancelAndDropGeneration(unloadWeights: true)
    }

    public func ensureModelReady() async throws {
        try await ensureModelLoaded()
    }

    // MARK: - Internals

    func supports(tier: ModelTier) -> Bool {
        ModelCatalog.spec(for: tier).engine == .litert
            || NookInferenceConfig.usesLiteRT
    }

    private func cancelAndDropGeneration(unloadWeights: Bool) async {
        engine.requestCancel()
        activeGenerationTask?.cancel()
        setActiveGenerationTask(nil)
        if unloadWeights {
            await engine.unload()
        }
    }

    private func performDownload(
        tier: ModelTier,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws {
        let spec = ModelCatalog.spec(for: tier)
        guard let filename = spec.litertFilename else {
            throw LiteRTModelRuntimeError.unsupportedTier(tier.name)
        }

        activeTier = tier
        setDownloadState(.downloading(progressPct: 0.01))

        do {
            let url = try await LiteRTModelDownloader.download(
                repoId: spec.repoId,
                filename: filename,
                progressHandler: { progress, transfer in
                    progressHandler(progress, transfer)
                    self.setDownloadState(.downloading(progressPct: progress, transfer: transfer))
                }
            )
            try await engine.load(modelPath: url.path)
            AppPreferences.markTierDownloaded(tier.id)
            setDownloadState(.ready)
            progressHandler(1.0, nil)
            // Don't keep a freshly downloaded GPU engine resident until first chat —
            // frees Metal pipelines between Settings download and first send.
            await engine.unload()
        } catch {
            setDownloadState(.notDownloaded)
            await engine.unload()
            if let litertError = error as? LiteRTModelRuntimeError {
                throw litertError
            }
            throw LiteRTModelRuntimeError.downloadFailed(underlying: error)
        }
    }

    private func ensureModelLoaded() async throws {
        let spec = ModelCatalog.spec(for: activeTier)
        guard let filename = spec.litertFilename else {
            throw LiteRTModelRuntimeError.unsupportedTier(activeTier.name)
        }
        guard isLocallyReady(tier: activeTier) else {
            throw LiteRTModelRuntimeError.modelNotReady(underlying: nil)
        }
        if let block = DeviceMemoryBudget.loadBlockReason(
            for: activeTier,
            alreadyLoaded: engine.isModelLoaded
        ) {
            throw LiteRTModelRuntimeError.insufficientMemory(detail: block)
        }
        let path = LiteRTModelPaths.localFileURL(repoId: spec.repoId, filename: filename).path
        if engine.isModelLoaded {
            return
        }
        do {
            // Large Gemma packages often fail GPU mmap under pressure — prefer CPU when tight.
            let forceCPU = activeTier.id == "balanced"
                && DeviceMemoryBudget.availableBytes < 2_000_000_000
            try await engine.load(modelPath: path, forceCPU: forceCPU)
            setDownloadState(.ready)
        } catch {
            await engine.unload()
            // One more CPU remount if the first attempt was GPU and mmap was incomplete.
            if !forceCPUPreferred(for: activeTier),
               LiteRTModelEngine.isBrokenEmbedderOrMmapError(error) {
                print("[LiteRT] Load mmap failed; forcing CPU remount")
                do {
                    try await engine.load(modelPath: path, forceCPU: true)
                    setDownloadState(.ready)
                    return
                } catch {
                    await engine.unload()
                    throw LiteRTModelRuntimeError.insufficientMemory(detail: error.localizedDescription)
                }
            }
            if LiteRTModelEngine.isBrokenEmbedderOrMmapError(error) {
                throw LiteRTModelRuntimeError.insufficientMemory(detail: error.localizedDescription)
            }
            throw LiteRTModelRuntimeError.modelNotReady(underlying: error)
        }
    }

    private func forceCPUPreferred(for tier: ModelTier) -> Bool {
        tier.id == "balanced" && DeviceMemoryBudget.availableBytes < 2_000_000_000
    }

    private func isLocallyReady(tier: ModelTier) -> Bool {
        let spec = ModelCatalog.spec(for: tier)
        guard let filename = spec.litertFilename else { return false }
        return LiteRTModelPaths.isDownloaded(repoId: spec.repoId, filename: filename)
    }

    private func installBackgroundUnload() {
        MemoryPressureMonitor.shared.setHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleMemoryPressure() }
        }

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.cancelAndDropGeneration(unloadWeights: true) }
        }
        #endif
    }

    /// Bundled/Fast unload under pressure. Balanced stays mapped (same load↔warn loop as MLX)
    /// and relies on background unload + generation timeout instead.
    private func handleMemoryPressure() async {
        MemoryPressureState.shared.recordWarning()
        if activeTier.id == "balanced" {
            print(
                "[LiteRT] Memory warning during Balanced — keeping weights mapped; " +
                "allocatable \(DeviceMemoryBudget.formattedAvailable())"
            )
            return
        }
        await cancelAndDropGeneration(unloadWeights: true)
        MemoryPressureState.shared.reset()
        NotificationCenter.default.post(
            name: .nookModelUnloadedDueToMemory,
            object: nil,
            userInfo: ["reason": ModelUnloadReason.memoryPressure.rawValue]
        )
    }

    private func setDownloadState(_ state: ModelDownloadState) {
        stateLock.lock()
        downloadState = state
        stateLock.unlock()
    }

    private func setActiveDownloadTask(_ task: Task<Void, Error>?) {
        stateLock.lock()
        activeDownloadTask = task
        stateLock.unlock()
    }

    private func setActiveGenerationTask(_ task: Task<AgentGenerationResult, Error>?) {
        stateLock.lock()
        activeGenerationTask = task
        stateLock.unlock()
    }
}

public enum LiteRTModelRuntimeError: LocalizedError, Sendable {
    case modelNotReady(underlying: Error?)
    case downloadFailed(underlying: Error)
    case generationFailed(underlying: Error)
    case insufficientMemory(detail: String?)
    case deviceTooHot
    case unsupportedTier(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotReady(let underlying):
            if let underlying {
                return "Couldn't load the LiteRT model. (\(underlying.localizedDescription))"
            }
            return "The on-device LiteRT model isn't ready yet. Finish downloading Balanced in Settings → Models."
        case .downloadFailed(let underlying):
            if let urlError = underlying as? URLError, urlError.code == .timedOut {
                return "Download timed out. Stay on Wi‑Fi, keep the app open, and try again."
            }
            return "Couldn't download the LiteRT model. Check your connection and try again. (\(underlying.localizedDescription))"
        case .generationFailed(let underlying):
            if let urlError = underlying as? URLError, urlError.code == .timedOut {
                return "That reply took too long and was stopped to free GPU memory. Try a shorter question or a new chat."
            }
            return "Something went wrong while generating with LiteRT. (\(underlying.localizedDescription))"
        case .insufficientMemory:
            return "Not enough memory to map Gemma 4 E2B. Force-quit other apps, wait a few seconds, or use Bundled/Fast — then try Balanced again."
        case .deviceTooHot:
            return "This iPhone is running hot. Wait a moment, then try again."
        case .unsupportedTier(let name):
            return "\(name) isn't available on the LiteRT runtime."
        }
    }
}
