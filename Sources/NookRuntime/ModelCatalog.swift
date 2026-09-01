import Foundation
import NookCore

/// Curated Hugging Face MLX models for each human-facing tier.
enum ModelCatalog {
    enum Backend: Sendable, Equatable {
        case llm
        case vlm
    }

    struct TierSpec: Sendable, Equatable {
        let repoId: String
        let backend: Backend
        /// Approximate on-disk download size for UI copy.
        let downloadSizeLabel: String
    }

    static func spec(for tier: ModelTier) -> TierSpec {
        switch tier.id {
        case "fast":
            return TierSpec(
                repoId: BundledModelCatalog.repoId,
                backend: .llm,
                downloadSizeLabel: "280 MB"
            )
        case "balanced":
            return TierSpec(
                repoId: "mlx-community/gemma-3-1b-it-qat-4bit",
                backend: .llm,
                downloadSizeLabel: "750 MB"
            )
        case "powerful":
            return TierSpec(
                repoId: "mlx-community/gemma-3-4b-it-qat-4bit",
                backend: .vlm,
                downloadSizeLabel: "3.0 GB"
            )
        default:
            return spec(for: ModelTier.standardTiers[1])
        }
    }

    static func repoId(for tier: ModelTier) -> String {
        spec(for: tier).repoId
    }

    static let hubMap: [String: String] = [
        "Fast": spec(for: ModelTier.standardTiers[0]).repoId,
        "Balanced": spec(for: ModelTier.standardTiers[1]).repoId,
        "Powerful": spec(for: ModelTier.standardTiers[2]).repoId,
    ]

    /// Bump when tier repo IDs change so stale downloads are not treated as ready.
    static let catalogVersion = 5
    private static let catalogVersionKey = "nook.models.catalogVersion"

    static func migrateDownloadedTiersIfNeeded() {
        let stored = UserDefaults.standard.integer(forKey: catalogVersionKey)
        guard stored < catalogVersion else { return }

        var ids = AppPreferences.downloadedTierIds
        ids.subtract(["balanced", "powerful"])
        AppPreferences.downloadedTierIds = ids
        UserDefaults.standard.set(catalogVersion, forKey: catalogVersionKey)
        print("[ModelCatalog] Cleared stale tier download flags (catalog v\(catalogVersion))")
    }
}
