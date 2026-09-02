import Foundation
import NookCore
import MLX

#if canImport(UIKit)
import UIKit
#endif

/// Hardware-accelerated local model runtime powered by MLX Swift on Apple Silicon.
public final class MLXModelRuntime: ModelRuntime, @unchecked Sendable {
    public private(set) var activeTier: ModelTier
    public private(set) var downloadState: ModelDownloadState = .notDownloaded

    /// Map model tiers to curated Hugging Face MLX repositories.
    public static let modelHubMap: [String: String] = ModelCatalog.hubMap

    private let engine = MLXModelEngine()
    private let stateLock = NSLock()
    private var downloadedRepos: Set<String> = []
    private var activeGenerationTask: Task<String, Error>?
    private var activeDownloadTask: Task<Void, Error>?
    private var isGenerating = false
    private var pendingUnloadAfterGeneration = false
    private var idleUnloadTask: Task<Void, Never>?

    public init(activeTier: ModelTier = ModelTier.standardTiers[0]) {
        self.activeTier = activeTier
        downloadedRepos = Self.restoredDownloadedRepos()
        if Self.isBundledTier(activeTier) && BundledModelCatalog.isAvailable {
            setDownloadState(.ready)
        } else if AppPreferences.isTierDownloaded(activeTier.id) {
            setDownloadState(.ready)
        }
        installResourceMonitors()
    }

    public func switchTier(_ tier: ModelTier) async throws {
        let repoId = Self.repoId(for: tier)
        let alreadyAvailable = Self.isBundledTier(tier) && BundledModelCatalog.isAvailable
            || withLock { downloadedRepos.contains(repoId) }
            || AppPreferences.isTierDownloaded(tier.id)
            || LocalModelDiscovery.mlxDirectory(for: repoId) != nil

        activeTier = tier

        await engine.unload()
        if alreadyAvailable {
            setDownloadState(.ready)
        } else {
            setDownloadState(.notDownloaded)
        }
    }

    public func downloadModel(
        tier: ModelTier,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws {
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

    private func performDownload(
        tier: ModelTier,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws {
        let spec = ModelCatalog.spec(for: tier)
        let source = Self.loadSource(for: tier)
        let logger = DownloadProgressLogger(label: "\(tier.name) (\(spec.repoId))")
        activeTier = tier
        setDownloadState(.downloading(progressPct: 0.01))
        logger.phase("download started")

        var lastError: Error?
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            if attempt > 1 {
                logger.phase("retrying (attempt \(attempt)/\(maxAttempts))")
                HubDownloadPrep.clearIncompleteBlobs(repoId: spec.repoId)
            }
            do {
                try await engine.load(
                    source: source,
                    backend: spec.backend,
                    toolCallFormat: spec.toolCallFormat
                ) { progress, transfer in
                    progressHandler(progress, transfer)
                    self.setDownloadState(.downloading(progressPct: progress, transfer: transfer))
                }

                _ = withLock { downloadedRepos.insert(spec.repoId) }
                AppPreferences.markTierDownloaded(tier.id)
                setDownloadState(.ready)
                progressHandler(1.0, nil)
                logger.phase("marked ready")
                await engine.unload()
                MLX.Memory.clearCache()
                return
            } catch {
                lastError = error
                logger.error(error, attempt: attempt, maxAttempts: maxAttempts)
                let shouldRetry = attempt < maxAttempts && Self.isRetriableDownloadError(error)
                if shouldRetry {
                    let delaySeconds = UInt64(attempt) * 2
                    logger.phase("waiting \(delaySeconds)s before retry")
                    try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                    continue
                }
                break
            }
        }

        logger.phase("download failed")

        setDownloadState(.notDownloaded)
        await engine.unload()
        throw MLXModelRuntimeError.downloadFailed(underlying: lastError ?? URLError(.unknown))
    }

    private static func isRetriableDownloadError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == URLError.timedOut.rawValue {
            return true
        }

        let description = nsError.localizedDescription.lowercased()
        return description.contains("timed out") || description.contains("network")
    }

    public func generateStreaming(
        promptContext: AssembledPromptContext,
        request: AgentGenerationRequest,
        toolExecutor: (@Sendable (String, ToolArguments) async throws -> ToolExecutionResult)?,
        onToken: @escaping @Sendable (String) -> Void,
        onToolEvent: (@Sendable (AgentToolEvent) -> Void)?
    ) async throws -> AgentGenerationResult {
        if ThermalStateMonitor.shared.currentAdvice == .throttled {
            throw MLXModelRuntimeError.deviceTooHot
        }

        guard case .ready = downloadState else {
            throw MLXModelRuntimeError.modelNotReady(underlying: nil)
        }

        if let blockReason = DeviceMemoryBudget.loadBlockReason(for: activeTier) {
            throw MLXModelRuntimeError.memoryConstrained(message: blockReason)
        }

        idleUnloadTask?.cancel()
        isGenerating = true
        defer {
            isGenerating = false
            if pendingUnloadAfterGeneration {
                pendingUnloadAfterGeneration = false
                Task { await self.unloadModelWeights(reason: .memoryPressure) }
            } else {
                idleUnloadTask = Task { await self.scheduleIdleUnload() }
            }
        }

        do {
            print("[MLXModelRuntime] Loading \(activeTier.name); free memory: \(DeviceMemoryBudget.formattedAvailable())")
            try await ensureModelLoaded()
        } catch {
            throw MLXModelRuntimeError.modelNotReady(underlying: error)
        }

        cancelGeneration()

        do {
            return try await withThrowingTaskGroup(of: AgentGenerationResult.self) { group in
                group.addTask {
                    try await self.engine.generate(
                        promptContext: promptContext,
                        request: request,
                        toolExecutor: toolExecutor,
                        onToken: onToken,
                        onToolEvent: onToolEvent
                    )
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: 90_000_000_000)
                    await self.engine.cancelGeneration()
                    throw MLXModelEngineError.generationTimedOut
                }

                guard let result = try await group.next() else {
                    throw MLXModelEngineError.generationTimedOut
                }
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MLXModelRuntimeError.generationFailed(underlying: error)
        }
    }

    public func cancelGeneration() {
        let task = clearActiveGenerationTask()
        task?.cancel()

        Task {
            await engine.cancelGeneration()
        }
    }

    public func releaseLoadedModel() async {
        cancelGeneration()
        await engine.unload()
    }

    public func ensureModelReady() async throws {
        try await ensureModelLoaded()
    }

    /// Loads weights into memory if they are not loaded yet.
    public func ensureModelLoaded() async throws {
        if case .downloading = downloadState {
            throw MLXModelRuntimeError.modelNotReady(underlying: nil)
        }

        if let blockReason = DeviceMemoryBudget.loadBlockReason(for: activeTier) {
            throw MLXModelRuntimeError.memoryConstrained(message: blockReason)
        }

        MLX.Memory.clearCache()
        let spec = ModelCatalog.spec(for: activeTier)
        let source = Self.loadSource(for: activeTier)
        try await engine.load(
            source: source,
            backend: spec.backend,
            toolCallFormat: spec.toolCallFormat
        ) { _, _ in }
        _ = withLock { downloadedRepos.insert(spec.repoId) }
        AppPreferences.markTierDownloaded(activeTier.id)
        setDownloadState(.ready)
    }

    private func installResourceMonitors() {
        MemoryPressureMonitor.shared.setHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.performMemoryUnload()
            }
        }

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.unloadModelWeights(reason: .idle)
            }
        }
        #endif
    }

    private func performMemoryUnload() async {
        MemoryPressureState.shared.recordWarning()
        if withLock({ isGenerating }) {
            pendingUnloadAfterGeneration = true
            return
        }
        await unloadModelWeights(reason: .memoryPressure)
    }

    private func scheduleIdleUnload() async {
        let delayNanoseconds: UInt64
        switch activeTier.id {
        case "bundled", "fast":
            delayNanoseconds = 2_000_000_000
        default:
            // Balanced VLM — keep warm a bit longer after use.
            delayNanoseconds = 20_000_000_000
        }

        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard !Task.isCancelled else { return }
        guard !withLock({ isGenerating }) else { return }
        guard await engine.isModelLoaded else { return }
        await unloadModelWeights(reason: .idle)
    }

    private func unloadModelWeights(reason: ModelUnloadReason) async {
        idleUnloadTask?.cancel()
        if withLock({ isGenerating }) {
            if reason == .memoryPressure {
                pendingUnloadAfterGeneration = true
            }
            return
        }

        if reason == .memoryPressure {
            cancelGeneration()
        }

        await engine.unload()
        MLX.Memory.clearCache()

        if reason == .memoryPressure {
            MemoryPressureState.shared.reset()
            NotificationCenter.default.post(
                name: .nookModelUnloadedDueToMemory,
                object: nil,
                userInfo: ["reason": reason.rawValue]
            )
        }
    }

    private static func restoredDownloadedRepos() -> Set<String> {
        Set(
            ModelTier.standardTiers
                .filter { AppPreferences.isTierDownloaded($0.id) }
                .map { repoId(for: $0) }
        )
    }

    private static func isBundledTier(_ tier: ModelTier) -> Bool {
        tier.shipsBundled
    }

    private static func repoId(for tier: ModelTier) -> String {
        ModelCatalog.repoId(for: tier)
    }

    private static func loadSource(for tier: ModelTier) -> ModelLoadSource {
        if isBundledTier(tier), let bundledURL = BundledModelCatalog.bundledDirectoryURL {
            return .bundled(bundledURL)
        }
        let repoId = repoId(for: tier)
        if let localURL = LocalModelDiscovery.mlxDirectory(for: repoId) {
            return .bundled(localURL)
        }
        return .remote(repoId: repoId)
    }

    private func setActiveGenerationTask(_ task: Task<String, Error>?) {
        stateLock.lock()
        activeGenerationTask = task
        stateLock.unlock()
    }

    private func clearActiveGenerationTask() -> Task<String, Error>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let task = activeGenerationTask
        activeGenerationTask = nil
        return task
    }

    private func setActiveDownloadTask(_ task: Task<Void, Error>?) {
        stateLock.lock()
        activeDownloadTask = task
        stateLock.unlock()
    }

    private func setDownloadState(_ state: ModelDownloadState) {
        stateLock.lock()
        downloadState = state
        stateLock.unlock()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}

public enum MLXModelRuntimeError: LocalizedError, Sendable {
    case modelNotReady(underlying: Error?)
    case downloadFailed(underlying: Error)
    case generationFailed(underlying: Error)
    case deviceTooHot
    case memoryConstrained(message: String?)

    public var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "The on-device model isn't ready yet. Finish downloading it in Settings → Models."
        case .downloadFailed(let underlying):
            if Self.isArchitectureMismatch(underlying) {
                return "This model format isn't supported yet. Update the app, or delete and re-download the tier in Settings → Models."
            }
            if Self.isDownloadTimeout(underlying) {
                return "Download timed out. Stay on Wi‑Fi, keep the app open, and try again — partial downloads resume automatically."
            }
            return "Couldn't download the model. Check your connection and try again. (\(underlying.localizedDescription))"
        case .generationFailed(let underlying):
            return "Something went wrong while generating on device. (\(underlying.localizedDescription))"
        case .deviceTooHot:
            return "This iPhone is running hot. Wait a moment, then try again."
        case .memoryConstrained(let message):
            return message
                ?? "This model needs more memory than is available right now. Switch to the Fast tier in Settings → Models, or restart Nook."
        }
    }

    private static func isDownloadTimeout(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == URLError.timedOut.rawValue
    }

    private static func isArchitectureMismatch(_ error: Error) -> Bool {
        let message = (error as? LocalizedError)?.errorDescription
            ?? (error as NSError).localizedDescription
        return message.localizedCaseInsensitiveContains("mismatched parameter")
    }
}
