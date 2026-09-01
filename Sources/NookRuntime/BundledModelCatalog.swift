import Foundation

/// Smallest curated MLX instruct model that produces coherent chat, shipped for the Fast tier.
enum BundledModelCatalog {
    static let tierName = "Fast"
    static let repoId = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
    static let resourceDirectoryName = "Qwen2.5-0.5B-Instruct-4bit"

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
