import Foundation

/// Discovers MLX model directories already on disk (macOS dev / simulator).
///
/// Ollama weights are **not** supported — they live in Ollama's blob format, not the
/// Hugging Face MLX layout (`config.json`, tokenizer files, `*.safetensors`) that
/// mlx-swift-lm expects.
enum LocalModelDiscovery {
    /// Returns a directory suitable for `LLMModelFactory.loadContainer(from:)`, if found.
    static func mlxDirectory(for repoId: String) -> URL? {
        if let override = environmentOverride(for: repoId) {
            return override
        }
        #if os(macOS)
        return huggingFaceHubSnapshot(for: repoId)
        #else
        return nil
        #endif
    }

    private static func environmentOverride(for repoId: String) -> URL? {
        let envKey = "NOOK_MODEL_\(repoId.replacingOccurrences(of: "/", with: "_").uppercased())"
        guard let path = ProcessInfo.processInfo.environment[envKey],
              isValidMLXModelDirectory(URL(fileURLWithPath: path))
        else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    #if os(macOS)
    private static func huggingFaceHubSnapshot(for repoId: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".cache/huggingface/hub"),
            home.appendingPathComponent("Library/Caches/huggingface/hub"),
        ]

        let folderName = "models--" + repoId.replacingOccurrences(of: "/", with: "--")

        for cacheRoot in candidates {
            let snapshotsRoot = cacheRoot
                .appendingPathComponent(folderName)
                .appendingPathComponent("snapshots")
            guard let snapshotURLs = try? FileManager.default.contentsOfDirectory(
                at: snapshotsRoot,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            let sorted = snapshotURLs.sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return lDate > rDate
            }

            for snapshot in sorted where isValidMLXModelDirectory(snapshot) {
                return snapshot
            }
        }

        return nil
    }
    #endif

    private static func isValidMLXModelDirectory(_ url: URL) -> Bool {
        let config = url.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: config.path) else {
            return false
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { $0.hasSuffix(".safetensors") }
    }
}
