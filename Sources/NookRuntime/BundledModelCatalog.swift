import Foundation

/// Optional on-disk MLX weights for the Bundled tier (download / local discovery only).
/// MLX no longer ships inside the IPA — LiteRT Bundled uses `LiteRTBundledCatalog` instead.
enum BundledModelCatalog {
    static let tierName = "Bundled"
    static let repoId = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
    static let resourceDirectoryName = "Qwen2.5-0.5B-Instruct-4bit"

    /// Always `nil` in current packaging; kept so MLX load paths can still resolve a
    /// developer-dropped folder under `Resources/BundledModels/` if present.
    static var bundledDirectoryURL: URL? {
        guard let url = Bundle.module.url(
            forResource: resourceDirectoryName,
            withExtension: nil,
            subdirectory: "BundledModels"
        ) else {
            return nil
        }

        let configURL = url.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return nil
        }

        return url
    }

    static var isAvailable: Bool {
        bundledDirectoryURL != nil
    }
}

enum ModelLoadSource: Sendable, Equatable {
    case bundled(URL)
    case remote(repoId: String)
}
