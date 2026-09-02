import Foundation
import NookCore

@MainActor
public final class ModelRuntimeStore: ObservableObject {
    @Published public private(set) var downloadState: ModelDownloadState
    @Published public private(set) var activeTier: ModelTier
    @Published public private(set) var downloadingTier: ModelTier?
    @Published public private(set) var thermalAdvice: ThermalStateMonitor.Advice = .normal
    @Published public var statusMessage: String?

    public let runtime: any ModelRuntime

    private var downloadTask: Task<Void, Error>?
    private var modelNeedsReload = false

    /// Tier name to show while a download is in progress, otherwise the active tier.
    public var displayTierName: String {
        downloadingTier?.name ?? activeTier.name
    }

    public var isDownloading: Bool {
        if case .downloading = downloadState { return true }
        return false
    }

    public init(runtime: (any ModelRuntime)? = nil) {
        ModelCatalog.migrateDownloadedTiersIfNeeded()
        let tier = AppPreferences.activeTier
        let resolvedRuntime = runtime ?? ModelRuntimeFactory.make(activeTier: tier)
        self.runtime = resolvedRuntime
        self.activeTier = tier
        self.downloadState = resolvedRuntime.downloadState

        ThermalStateMonitor.shared.setHandler { [weak self] advice in
            Task { @MainActor in
                self?.thermalAdvice = advice
            }
        }

        NotificationCenter.default.addObserver(
            forName: .nookModelUnloadedDueToMemory,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?["reason"] as? String
            Task { @MainActor [weak self] in
                guard let self else { return }
                if reason == ModelUnloadReason.memoryPressure.rawValue {
                    self.modelNeedsReload = true
                    self.presentStatus(
                        "Freed model memory to keep Nook running. Sending again will reload the model if memory allows."
                    )
                }
            }
        }
    }

    public func resetMemoryPressureState() {
        MemoryPressureState.shared.reset()
        modelNeedsReload = false
    }

    public func prepareForGenerationIfNeeded() async throws {
        guard modelNeedsReload else { return }

        presentStatus("Reloading on-device model…")
        defer {
            if statusMessage == "Reloading on-device model…" {
                statusMessage = nil
            }
        }
        try await runtime.ensureModelReady()
        modelNeedsReload = false
        MemoryPressureState.shared.reset()
    }

    public func presentStatus(_ message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.statusMessage == message {
                self.statusMessage = nil
            }
        }
    }

    public func syncFromRuntime() {
        downloadState = runtime.downloadState
        activeTier = runtime.activeTier
    }

    public func completeOnboarding(with tier: ModelTier) async throws {
        try await downloadModel(tier: tier)
        AppPreferences.markOnboardingComplete(chosenTier: tier)
        activeTier = tier
        syncFromRuntime()
    }

    public func downloadModel(
        tier: ModelTier,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        if let downloadTask {
            try await downloadTask.value
            syncFromRuntime()
            if activeTier.id == tier.id, case .ready = downloadState {
                progressHandler?(1.0)
            }
            return
        }

        let task = Task<Void, Error> {
            try await self.runDownload(tier: tier, progressHandler: progressHandler)
        }
        downloadTask = task
        defer { downloadTask = nil }
        try await task.value
    }

    private func runDownload(
        tier: ModelTier,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        downloadingTier = tier
        defer { downloadingTier = nil }

        downloadState = .downloading(progressPct: 0.01)
        let repoId = ModelCatalog.repoId(for: tier)
        print("[ModelRuntimeStore] Starting download for \(tier.name) → \(repoId)")

        let uiLogger = DownloadProgressLogger(label: "UI \(tier.name)", minInterval: 10)
        try await runtime.downloadModel(tier: tier) { progress, transfer in
            let clamped = min(1.0, max(0.0, progress))
            progressHandler?(clamped)
            uiLogger.progress(
                mapped: clamped,
                hubFraction: transfer?.fraction,
                completedUnits: transfer?.completedBytes,
                totalUnits: transfer?.totalBytes,
                note: ModelDownloadProgressMapper.statusNote(for: transfer, uiFraction: clamped)
            )
            Task { @MainActor in
                self.downloadState = .downloading(progressPct: clamped, transfer: transfer)
            }
        }
        activeTier = tier
        AppPreferences.activeTier = tier
        syncFromRuntime()
        print("[ModelRuntimeStore] Download finished for \(tier.name). State: \(downloadState)")
    }

    public func switchTier(_ tier: ModelTier) async throws {
        if tier.id == activeTier.id,
           case .ready = runtime.downloadState {
            return
        }

        if let downloadingTier, downloadingTier.id == tier.id {
            return
        }

        if tier.shipsBundled || AppPreferences.isTierDownloaded(tier.id)
            || LocalModelDiscovery.mlxDirectory(for: ModelCatalog.repoId(for: tier)) != nil
            || LiteRTModelPaths.isReady(for: tier) {
            try await runtime.switchTier(tier)
            activeTier = tier
            AppPreferences.activeTier = tier
            syncFromRuntime()
            return
        }

        try await downloadModel(tier: tier)
    }

    public func preloadActiveTierIfNeeded() async {
        guard activeTier.shipsBundled else { return }
        guard case .notDownloaded = downloadState else { return }
        guard !isDownloading else { return }
        try? await downloadModel(tier: activeTier)
    }

    public func releaseModelWhenIdle() {
        Task {
            await runtime.releaseLoadedModel()
        }
    }

    public func cancelGeneration() {
        runtime.cancelGeneration()
    }

    public func userFacingErrorMessage(for error: Error) -> String {
        if error is CancellationError {
            return "Stopped."
        }
        if let runtimeError = error as? MLXModelRuntimeError {
            return runtimeError.localizedDescription
        }
        if let runtimeError = error as? LiteRTModelRuntimeError {
            return runtimeError.localizedDescription
        }
        return "Something went wrong. Try again."
    }
}
