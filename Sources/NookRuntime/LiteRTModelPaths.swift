import Foundation
import NookCore

/// On-disk layout for LiteRT-LM `.litertlm` assets downloaded into Application Support.
enum LiteRTModelPaths {
    static var modelsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base
            .appendingPathComponent("Nook", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("litert", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static var compilationCacheDirectory: URL {
        let dir = modelsRoot.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func localFileURL(repoId: String, filename: String) -> URL {
        let safeRepo = repoId.replacingOccurrences(of: "/", with: "__")
        let dir = modelsRoot.appendingPathComponent(safeRepo, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename, isDirectory: false)
    }

    static func isDownloaded(repoId: String, filename: String) -> Bool {
        let url = localFileURL(repoId: repoId, filename: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        // Reject tiny incomplete/corrupt leftovers.
        return size > 64 * 1024 * 1024
    }

    static func isReady(for tier: ModelTier) -> Bool {
        let spec = ModelCatalog.spec(for: tier)
        guard spec.engine == .litert, let filename = spec.litertFilename else { return false }
        if tier.id == "bundled", LiteRTBundledCatalog.isAvailable {
            return true
        }
        return isDownloaded(repoId: spec.repoId, filename: filename)
    }

    /// Resolves the on-disk path to load for a tier (bundled materialization or download).
    static func loadableFileURL(for tier: ModelTier) throws -> URL {
        let spec = ModelCatalog.spec(for: tier)
        guard let filename = spec.litertFilename else {
            throw LiteRTModelRuntimeError.unsupportedTier(tier.name)
        }
        if tier.id == "bundled", LiteRTBundledCatalog.isAvailable {
            return try LiteRTBundledCatalog.materializeIntoApplicationSupport()
        }
        let url = localFileURL(repoId: spec.repoId, filename: filename)
        guard isDownloaded(repoId: spec.repoId, filename: filename) else {
            throw LiteRTModelRuntimeError.modelNotReady(underlying: nil)
        }
        return url
    }

    static var measuredBytes: Int64 {
        measureDirectory(modelsRoot)
    }

    private static func measureDirectory(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
