import Foundation
import NookCore
import MLX

/// Hardware-accelerated local model runtime powered by MLX Swift on Apple Silicon.
public final class MLXModelRuntime: ModelRuntime, @unchecked Sendable {
    public private(set) var activeTier: ModelTier
    public private(set) var downloadState: ModelDownloadState = .notDownloaded

    /// Map model tiers to curated Hugging Face MLX model repositories.
    public static let modelHubMap: [String: String] = [
        "Fast": BundledModelCatalog.repoId,
        "Balanced": "mlx-community/gemma-3-4b-it-4bit",
        "Powerful": "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"
    ]

    private let engine = MLXModelEngine()
    private let stateLock = NSLock()
    private var downloadedRepos: Set<String> = []

    public init(activeTier: ModelTier = ModelTier.standardTiers[0]) {
        self.activeTier = activeTier
    }

    public func switchTier(_ tier: ModelTier) async throws {
        let source = Self.loadSource(for: tier)
        let repoId = Self.repoId(for: tier)
        let alreadyAvailable = Self.isBundledTier(tier) && BundledModelCatalog.isAvailable
            || withLock { downloadedRepos.contains(repoId) }

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
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let source = Self.loadSource(for: tier)
        let repoId = Self.repoId(for: tier)
        activeTier = tier
        setDownloadState(.downloading(progressPct: 0))

        do {
            try await engine.load(source: source) { progress in
                progressHandler(progress)
                self.setDownloadState(.downloading(progressPct: progress))
            }

            _ = withLock { downloadedRepos.insert(repoId) }
            setDownloadState(.ready)
            progressHandler(1.0)
        } catch {
            setDownloadState(.notDownloaded)
            await engine.unload()
            throw error
        }
    }

    public func generateStreaming(
        promptContext: AssembledPromptContext,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        do {
            try await ensureModelLoaded()
        } catch {
            let message = "Could not load the on-device model. \(error.localizedDescription)"
            onToken(message)
            return message
        }

        guard case .ready = downloadState else {
            let fallback = "The on-device model is still downloading. Try again in a moment."
            onToken(fallback)
            return fallback
        }

        do {
            return try await Task.detached(priority: .userInitiated) { [engine] in
                try await engine.generate(promptContext: promptContext, onToken: onToken)
            }.value
        } catch {
            let message = "Something went wrong while generating on device. \(error.localizedDescription)"
            onToken(message)
            return message
        }
    }

    /// Loads weights into memory if they are not loaded yet.
    public func ensureModelLoaded() async throws {
        let source = Self.loadSource(for: activeTier)
        let repoId = Self.repoId(for: activeTier)
        try await engine.load(source: source) { _ in }
        _ = withLock { downloadedRepos.insert(repoId) }
        setDownloadState(.ready)
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
        return .remote(repoId: repoId(for: tier))
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
