import Foundation
import NookCore
import MLX

/// Hardware-accelerated local model runtime powered by MLX Swift on Apple Silicon.
public final class MLXModelRuntime: ModelRuntime, @unchecked Sendable {
    public private(set) var activeTier: ModelTier
    public private(set) var downloadState: ModelDownloadState = .notDownloaded

    /// Map model tiers to curated Hugging Face MLX text-model repositories.
    /// Vision tiers (Qwen3-VL, Gemma 3 4B multimodal) require VLMModelFactory — not wired yet.
    public static let modelHubMap: [String: String] = [
        "Fast": BundledModelCatalog.repoId,
        "Balanced": "mlx-community/Llama-3.2-3B-Instruct-4bit",
        "Powerful": "mlx-community/Qwen2.5-7B-Instruct-4bit"
    ]

    private let engine = MLXModelEngine()
    private let stateLock = NSLock()
    private var downloadedRepos: Set<String> = []
    private var activeGenerationTask: Task<String, Error>?

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

        if alreadyAvailable {
            try await ensureModelLoaded()
            setDownloadState(.ready)
        } else {
            setDownloadState(.notDownloaded)
            await engine.unload()
        }
    }

    public func downloadModel(
        tier: ModelTier,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws {
        let source = Self.loadSource(for: tier)
        let repoId = Self.repoId(for: tier)
        let logger = DownloadProgressLogger(label: "\(tier.name) (\(repoId))")
        activeTier = tier
        setDownloadState(.downloading(progressPct: 0.01))
        logger.phase("download started")

        var lastError: Error?
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            if attempt > 1 {
                logger.phase("retrying (attempt \(attempt)/\(maxAttempts))")
                HubDownloadPrep.clearIncompleteBlobs(repoId: repoId)
            }
            do {
                try await engine.load(source: source) { progress, transfer in
                    progressHandler(progress, transfer)
                    self.setDownloadState(.downloading(progressPct: progress, transfer: transfer))
                }

                _ = withLock { downloadedRepos.insert(repoId) }
                AppPreferences.markTierDownloaded(tier.id)
                setDownloadState(.ready)
                progressHandler(1.0, nil)
                logger.phase("marked ready")
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
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        if ThermalStateMonitor.shared.currentAdvice == .throttled {
            throw MLXModelRuntimeError.deviceTooHot
        }

        do {
            try await ensureModelLoaded()
        } catch {
            throw MLXModelRuntimeError.modelNotReady(underlying: error)
        }

        guard case .ready = downloadState else {
            throw MLXModelRuntimeError.modelNotReady(underlying: nil)
        }

        cancelGeneration()

        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await self.engine.generate(promptContext: promptContext, onToken: onToken)
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

    /// Loads weights into memory if they are not loaded yet.
    public func ensureModelLoaded() async throws {
        let source = Self.loadSource(for: activeTier)
        let repoId = Self.repoId(for: activeTier)
        try await engine.load(source: source) { _, _ in }
        _ = withLock { downloadedRepos.insert(repoId) }
        AppPreferences.markTierDownloaded(activeTier.id)
        setDownloadState(.ready)
    }

    private func installResourceMonitors() {
        MemoryPressureMonitor.shared.setHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.handleMemoryPressure()
            }
        }
    }

    private func handleMemoryPressure() async {
        cancelGeneration()
        await engine.unload()
        MLX.Memory.clearCache()
        NotificationCenter.default.post(name: .nookModelUnloadedDueToMemory, object: nil)
    }

    private static func restoredDownloadedRepos() -> Set<String> {
        Set(
            ModelTier.standardTiers
                .filter { AppPreferences.isTierDownloaded($0.id) }
                .map { repoId(for: $0) }
        )
    }

    private static func isBundledTier(_ tier: ModelTier) -> Bool {
        tier.name == BundledModelCatalog.tierName
    }

    private static func repoId(for tier: ModelTier) -> String {
        modelHubMap[tier.name] ?? modelHubMap["Balanced"]!
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
