import Foundation
import MLXLMCommon
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
        /// Native tool-call parser for this model family.
        let toolCallFormat: ToolCallFormat
    }

    static func spec(for tier: ModelTier) -> TierSpec {
        switch tier.id {
        case "bundled":
            return TierSpec(
                repoId: BundledModelCatalog.repoId,
                backend: .llm,
                downloadSizeLabel: "280 MB",
                toolCallFormat: .json
            )
        case "fast":
            return TierSpec(
                repoId: "LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit",
                backend: .llm,
                downloadSizeLabel: "660 MB",
                toolCallFormat: .lfm2
            )
        case "balanced":
            return TierSpec(
                repoId: "mlx-community/gemma-4-e2b-it-4bit",
                backend: .vlm,
                downloadSizeLabel: "3.6 GB",
                toolCallFormat: .gemma4
            )
        default:
            return spec(for: ModelTier.recommended)
        }
    }

    static func repoId(for tier: ModelTier) -> String {
        spec(for: tier).repoId
    }

    static func toolCallFormat(for tier: ModelTier) -> ToolCallFormat {
        spec(for: tier).toolCallFormat
    }

    static let hubMap: [String: String] = Dictionary(
        uniqueKeysWithValues: ModelTier.standardTiers.map { ($0.name, repoId(for: $0)) }
    )

    /// Bump when tier repo IDs change so stale downloads are not treated as ready.
    static let catalogVersion = 9
    private static let catalogVersionKey = "nook.models.catalogVersion"

    static func migrateDownloadedTiersIfNeeded() {
        let stored = UserDefaults.standard.integer(forKey: catalogVersionKey)
        guard stored < catalogVersion else { return }

        var ids = AppPreferences.downloadedTierIds
        // Drop removed tiers; pre-v9 "fast" was bundled Qwen — LFM Fast needs a fresh download flag.
        ids.subtract(["powerful", "tools", "fast"])
        if stored < 8 {
            ids.remove("balanced")
        }
        AppPreferences.downloadedTierIds = ids

        switch AppPreferences.activeTierId {
        case "powerful", "tools":
            AppPreferences.activeTier = .recommended
        case "fast":
            // Pre-v9 Fast was the bundled Qwen model.
            AppPreferences.activeTierId = "bundled"
        default:
            break
        }

        UserDefaults.standard.set(catalogVersion, forKey: catalogVersionKey)
        print("[ModelCatalog] Cleared stale tier download flags (catalog v\(catalogVersion))")
    }
}
