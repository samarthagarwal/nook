import Foundation

enum HubDownloadPrep {
    /// Removes partial blob files so the Hub client can start a clean resume.
    static func clearIncompleteBlobs(repoId: String) {
        guard let blobsDirectory = repoBlobsDirectory(repoId: repoId) else { return }

        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: blobsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var removed = 0
        for url in entries where url.lastPathComponent.hasSuffix(".incomplete") {
            try? manager.removeItem(at: url)
            removed += 1
        }

        if removed > 0 {
            print("[Download] \(repoId) — cleared \(removed) incomplete blob(s) before download")
        }
    }

    static func cachedBytes(repoId: String) -> Int64 {
        guard let repoDirectory = repoCacheDirectory(repoId: repoId) else { return 0 }
        guard FileManager.default.fileExists(atPath: repoDirectory.path) else { return 0 }
        return directorySize(at: repoDirectory)
    }

    private static func repoCacheDirectory(repoId: String) -> URL? {
        guard let hubRoot = hubCacheRoot() else { return nil }
        let folder = "models--" + repoId.replacingOccurrences(of: "/", with: "--")
        return hubRoot.appendingPathComponent(folder, isDirectory: true)
    }

    private static func repoBlobsDirectory(repoId: String) -> URL? {
        repoCacheDirectory(repoId: repoId)?.appendingPathComponent("blobs", isDirectory: true)
    }

    private static func hubCacheRoot() -> URL? {
        if let override = ProcessInfo.processInfo.environment["HF_HUB_CACHE"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return caches.appendingPathComponent("huggingface/hub", isDirectory: true)
    }

    private static func directorySize(at url: URL) -> Int64 {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else {
                continue
            }
            total += Int64(size)
        }
        return total
    }
}
