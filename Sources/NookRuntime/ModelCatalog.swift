import Foundation
import MLXLMCommon
import NookCore

/// Curated on-device models for each human-facing tier.
enum ModelCatalog {
    enum InferenceEngine: Sendable, Equatable {
        case mlx
        case litert
    }

    enum MLXBackend: Sendable, Equatable {
        case llm
        case vlm
    }

    /// Back-compat alias used by MLX load paths.
    typealias Backend = MLXBackend

    struct TierSpec: Sendable, Equatable {
        let engine: InferenceEngine
        let repoId: String
        let mlxBackend: MLXBackend?
        /// Approximate on-disk download size for UI copy.
        let downloadSizeLabel: String
        /// Native tool-call parser for MLX model families.
        let toolCallFormat: ToolCallFormat?
        /// Single-file LiteRT-LM asset inside `repoId` (nil for MLX tiers).
        let litertFilename: String?

        var backend: MLXBackend {
            mlxBackend ?? .llm
        }
    }

    static func spec(for tier: ModelTier) -> TierSpec {
        switch NookInferenceConfig.backend {
        case .litert:
            return litertSpec(for: tier)
        case .mlx:
            return mlxSpec(for: tier)
        }
    }

    // MARK: - LiteRT-LM catalog (default)

    private static func litertSpec(for tier: ModelTier) -> TierSpec {
        switch tier.id {
        case "bundled":
            // Qwen3 0.6B INT4, thinking off — small, direct chat answers.
            return TierSpec(
                engine: .litert,
                repoId: "litert-community/Qwen3-0.6B-int4",
                mlxBackend: nil,
                downloadSizeLabel: "330 MB",
                toolCallFormat: nil,
                litertFilename: "qwen3_0.6b_nothink_q4_block32_ekv1280.litertlm"
            )
        case "fast":
            // Qwen2.5 1.5B Instruct Q8 — sits cleanly between 0.6B and Gemma 4 E2B.
            return TierSpec(
                engine: .litert,
                repoId: "litert-community/Qwen2.5-1.5B-Instruct",
                mlxBackend: nil,
                downloadSizeLabel: "1.6 GB",
                toolCallFormat: nil,
                litertFilename: "Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm"
            )
        case "balanced":
            return TierSpec(
                engine: .litert,
                repoId: "litert-community/gemma-4-E2B-it-litert-lm",
                mlxBackend: nil,
                downloadSizeLabel: "2.6 GB",
                toolCallFormat: nil,
                litertFilename: "gemma-4-E2B-it.litertlm"
            )
        default:
            return litertSpec(for: ModelTier.recommended)
        }
    }

    // MARK: - MLX catalog (preserved; used when NookInferenceConfig.backend == .mlx)

    private static func mlxSpec(for tier: ModelTier) -> TierSpec {
        switch tier.id {
        case "bundled":
            return TierSpec(
                engine: .mlx,
                repoId: BundledModelCatalog.repoId,
                mlxBackend: .llm,
                downloadSizeLabel: "280 MB",
                toolCallFormat: .json,
                litertFilename: nil
            )
        case "fast":
            // LFM removed from product; MLX Fast uses Qwen2.5 1.5B when backend flipped back.
            return TierSpec(
                engine: .mlx,
                repoId: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                mlxBackend: .llm,
                downloadSizeLabel: "1.0 GB",
                toolCallFormat: .json,
                litertFilename: nil
            )
        case "balanced":
            return TierSpec(
                engine: .mlx,
                repoId: "mlx-community/gemma-4-e2b-it-4bit",
                mlxBackend: .vlm,
                downloadSizeLabel: "3.6 GB",
                toolCallFormat: .gemma4,
                litertFilename: nil
            )
        default:
            return mlxSpec(for: ModelTier.recommended)
        }
    }

    static func repoId(for tier: ModelTier) -> String {
        spec(for: tier).repoId
    }

    static func toolCallFormat(for tier: ModelTier) -> ToolCallFormat {
        spec(for: tier).toolCallFormat ?? .json
    }

    static let hubMap: [String: String] = Dictionary(
        uniqueKeysWithValues: ModelTier.standardTiers.map { ($0.name, repoId(for: $0)) }
    )

    /// Bump when tier repo IDs / engines change so stale downloads are not treated as ready.
    static let catalogVersion = 11
    private static let catalogVersionKey = "nook.models.catalogVersion"

    static func migrateDownloadedTiersIfNeeded() {
        let stored = UserDefaults.standard.integer(forKey: catalogVersionKey)
        let balanced = ModelTier.standardTiers.first { $0.id == "balanced" }

        if stored < catalogVersion {
            var ids = AppPreferences.downloadedTierIds
            ids.subtract(["powerful", "tools"])

            // v11: Bundled/Fast assets changed (Qwen3 0.6B / Qwen2.5 1.5B). Clear those flags.
            // Keep Balanced if the Gemma 4 E2B `.litertlm` is already on disk — same file as v10.
            if stored < 11 {
                ids.remove("bundled")
                ids.remove("fast")
                if let balanced, !LiteRTModelPaths.isReady(for: balanced) {
                    ids.remove("balanced")
                }
                if AppPreferences.activeTierId == "fast" {
                    AppPreferences.activeTierId = "bundled"
                }
            }

            AppPreferences.downloadedTierIds = ids
            UserDefaults.standard.set(catalogVersion, forKey: catalogVersionKey)
            print("[ModelCatalog] Migrated download flags (catalog v\(catalogVersion))")
        }

        reconcileLiteRTDownloadsFromDisk()
    }

    /// Re-marks tiers whose `.litertlm` files are already on disk so UI/download won't re-fetch.
    static func reconcileLiteRTDownloadsFromDisk() {
        guard NookInferenceConfig.usesLiteRT else { return }
        for tier in ModelTier.standardTiers {
            guard LiteRTModelPaths.isReady(for: tier) else { continue }
            AppPreferences.markTierDownloaded(tier.id)
            print("[ModelCatalog] Reused on-disk LiteRT asset for \(tier.name)")
        }
    }
}
