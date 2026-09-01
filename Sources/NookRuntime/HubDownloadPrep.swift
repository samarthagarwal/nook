import Foundation
import HuggingFace

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

    static func resolvedCommit(
        cache: HubCache,
        repoID: Repo.ID,
        revision: String
    ) -> String {
        cache.resolveRevision(repo: repoID, kind: .model, ref: revision) ?? revision
    }

    /// Returns the snapshot directory when every required file is present for one commit.
    static func snapshotDirectory(
        cache: HubCache,
        repoID: Repo.ID,
        commitHash: String,
        requiredFiles: [String]
    ) -> URL? {
        for file in requiredFiles {
            guard cache.cachedFilePath(
                repo: repoID,
                kind: .model,
                revision: commitHash,
                filename: file
            ) != nil else {
                return nil
            }
        }
        return try? cache.snapshotPath(repo: repoID, kind: .model, commitHash: commitHash)
    }

    static func missingCachedFiles(
        cache: HubCache,
        repoID: Repo.ID,
        commitHash: String,
        requiredFiles: [HubRepoFileEntry]
    ) -> [HubRepoFileEntry] {
        requiredFiles.filter { file in
            cache.cachedFilePath(
                repo: repoID,
                kind: .model,
                revision: commitHash,
                filename: file.path
            ) == nil
        }
    }

    static func modelSnapshotDirectory(repoId: String) -> URL? {
        guard let repoDirectory = repoCacheDirectory(repoId: repoId) else { return nil }
        let snapshotsRoot = repoDirectory.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotURLs = try? FileManager.default.contentsOfDirectory(
            at: snapshotsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let sorted = snapshotURLs.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lDate > rDate
        }

        for snapshot in sorted where isValidModelSnapshot(snapshot) {
            return snapshot
        }
        return nil
    }

    private static func isValidModelSnapshot(_ url: URL) -> Bool {
        let config = url.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: config.path) else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { $0.hasSuffix(".safetensors") }
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
