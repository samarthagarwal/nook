import Foundation
import NookCore

/// Routes each tier to MLX or LiteRT-LM while presenting a single `ModelRuntime` to the app.
public final class RoutingModelRuntime: ModelRuntime, @unchecked Sendable {
    public private(set) var activeTier: ModelTier

    private let mlx: MLXModelRuntime
    private let litert: LiteRTModelRuntime
    private let lock = NSLock()

    public init(activeTier: ModelTier = AppPreferences.activeTier) {
        self.activeTier = activeTier
        self.mlx = MLXModelRuntime(activeTier: activeTier)
        self.litert = LiteRTModelRuntime(activeTier: activeTier)
    }

    public var downloadState: ModelDownloadState {
        backend(for: activeTier).downloadState
    }

    public func switchTier(_ tier: ModelTier) async throws {
        let previous = activeTier
        if ModelCatalog.spec(for: previous).engine != ModelCatalog.spec(for: tier).engine {
            await backend(for: previous).releaseLoadedModel()
        }
        setActiveTier(tier)
        try await backend(for: tier).switchTier(tier)
    }

    public func downloadModel(
        tier: ModelTier,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws {
        setActiveTier(tier)
        try await backend(for: tier).downloadModel(tier: tier, progressHandler: progressHandler)
    }

    public func generateStreaming(
        promptContext: AssembledPromptContext,
        request: AgentGenerationRequest,
        toolExecutor: (@Sendable (String, ToolArguments) async throws -> ToolExecutionResult)?,
        onToken: @escaping @Sendable (String) -> Void,
        onToolEvent: (@Sendable (AgentToolEvent) -> Void)?
    ) async throws -> AgentGenerationResult {
        try await backend(for: activeTier).generateStreaming(
            promptContext: promptContext,
            request: request,
            toolExecutor: toolExecutor,
            onToken: onToken,
            onToolEvent: onToolEvent
        )
    }

    public func cancelGeneration() {
        mlx.cancelGeneration()
        litert.cancelGeneration()
    }

    public func releaseLoadedModel() async {
        await mlx.releaseLoadedModel()
        await litert.releaseLoadedModel()
    }

    public func ensureModelReady() async throws {
        try await backend(for: activeTier).ensureModelReady()
    }

    private func backend(for tier: ModelTier) -> any ModelRuntime {
        switch ModelCatalog.spec(for: tier).engine {
        case .mlx:
            return mlx
        case .litert:
            return litert
        }
    }

    private func setActiveTier(_ tier: ModelTier) {
        lock.lock()
        activeTier = tier
        lock.unlock()
    }
}
