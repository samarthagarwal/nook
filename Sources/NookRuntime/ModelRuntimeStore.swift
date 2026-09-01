import Foundation
import NookCore

@MainActor
public final class ModelRuntimeStore: ObservableObject {
    @Published public private(set) var downloadState: ModelDownloadState
    @Published public private(set) var activeTier: ModelTier
    @Published public private(set) var thermalAdvice: ThermalStateMonitor.Advice = .normal
    @Published public var statusMessage: String?

    public let runtime: any ModelRuntime

    public init(runtime: (any ModelRuntime)? = nil) {
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
        ) { [weak self] _ in
            Task { @MainActor in
                self?.presentStatus("Freed memory. The model will reload on your next message.")
            }
        }
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
        downloadState = .downloading(progressPct: 0.01)
        let repoId = MLXModelRuntime.modelHubMap[tier.name] ?? tier.name
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

        if tier.shipsBundled || AppPreferences.isTierDownloaded(tier.id)
            || LocalModelDiscovery.mlxDirectory(for: MLXModelRuntime.modelHubMap[tier.name] ?? "") != nil {
            try await runtime.switchTier(tier)
            activeTier = tier
            AppPreferences.activeTier = tier
            syncFromRuntime()
            return
        }

        try await downloadModel(tier: tier)
    }

    public func preloadActiveTierIfNeeded() async {
        guard case .notDownloaded = downloadState else { return }
        try? await downloadModel(tier: activeTier)
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
        return "Something went wrong. Try again."
    }
}
