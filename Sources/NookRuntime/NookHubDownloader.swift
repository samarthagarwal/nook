import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon

/// Downloads Hugging Face model snapshots small-files-first so UI progress moves before multi-GB shards.
struct NookHubDownloader: Downloader {
    private let hub: HubClient

    init(hub: HubClient = NookHubClient.shared) {
        self.hub = hub
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: id) else {
            throw HuggingFaceDownloaderError.invalidRepositoryID(id)
        }

        let branchRevision = revision ?? "main"
        let files = try await HubRepoFileLister.listModelFiles(repoId: id, revision: branchRevision)
        let matched = HubRepoFileLister.filter(files, matching: patterns)
            .sorted { $0.size < $1.size }

        guard !matched.isEmpty else {
            print("[Download] \(id) — no matching files, falling back to snapshot download")
            return try await hub.downloadSnapshot(
                of: repoID,
                revision: branchRevision,
                matching: patterns,
                progressHandler: { @MainActor progress in
                    progressHandler(progress)
                }
            )
        }

        guard let cache = hub.cache else {
            return try await hub.downloadSnapshot(
                of: repoID,
                revision: branchRevision,
                matching: patterns,
                progressHandler: { @MainActor progress in
                    progressHandler(progress)
                }
            )
        }

        let commitHash: String
        do {
            commitHash = try await HubDownloadPrep.resolveCommitHash(
                repoId: id,
                repoID: repoID,
                revision: branchRevision,
                cache: cache
            )
        } catch {
            print("[Download] \(id) — failed to resolve commit for \(branchRevision): \(error)")
            throw error
        }

        let requiredPaths = matched.map(\.path)
        let totalBytes = matched.reduce(Int64(0)) { $0 + $1.size }
        let overall = Progress(totalUnitCount: max(totalBytes, 1))

        print(
            "[Download] \(id) — staged download of \(matched.count) file(s) @ \(commitHash.prefix(8))…, \(AppStorageUsage.format(totalBytes)) total"
        )

        try await downloadFiles(
            matched,
            repoID: repoID,
            repoId: id,
            commitHash: commitHash,
            branchRevision: branchRevision,
            overall: overall,
            progressHandler: progressHandler
        )

        // Ensure branch ref points at the SHA we downloaded into.
        try? cache.updateRef(repo: repoID, kind: .model, ref: branchRevision, commit: commitHash)

        if let snapshot = HubDownloadPrep.snapshotDirectory(
            cache: cache,
            repoID: repoID,
            commitHash: commitHash,
            requiredFiles: requiredPaths
        ) {
            overall.completedUnitCount = totalBytes
            progressHandler(overall)
            print("[Download] \(id) — staged download complete, snapshot ready at \(snapshot.path)")
            return snapshot
        }

        let missing = HubDownloadPrep.missingCachedFiles(
            cache: cache,
            repoID: repoID,
            commitHash: commitHash,
            requiredFiles: matched
        )
        if !missing.isEmpty {
            print(
                "[Download] \(id) — fetching \(missing.count) missing file(s) into commit \(commitHash.prefix(8))…"
            )
            try await downloadFiles(
                missing,
                repoID: repoID,
                repoId: id,
                commitHash: commitHash,
                branchRevision: branchRevision,
                overall: overall,
                progressHandler: progressHandler
            )
            try? cache.updateRef(repo: repoID, kind: .model, ref: branchRevision, commit: commitHash)
        }

        if let snapshot = HubDownloadPrep.snapshotDirectory(
            cache: cache,
            repoID: repoID,
            commitHash: commitHash,
            requiredFiles: requiredPaths
        ) {
            overall.completedUnitCount = totalBytes
            progressHandler(overall)
            print("[Download] \(id) — snapshot ready after topping up missing files")
            return snapshot
        }

        print("[Download] \(id) — warning: falling back to full snapshot download @ \(commitHash.prefix(8))")
        return try await hub.downloadSnapshot(
            of: repoID,
            revision: commitHash,
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }

    private func downloadFiles(
        _ files: [HubRepoFileEntry],
        repoID: Repo.ID,
        repoId: String,
        commitHash: String,
        branchRevision: String,
        overall: Progress,
        progressHandler: @escaping @Sendable (Progress) -> Void
    ) async throws {
        var completedBytes = overall.completedUnitCount

        for (index, file) in files.enumerated() {
            let label = AppStorageUsage.format(file.size)
            print("[Download] \(repoId) — file \(index + 1)/\(files.count): \(file.path) (\(label))")

            let baseCompleted = completedBytes

            if NookDirectHubFileDownloader.shouldUseDirectDownload(for: file.size) {
                try await NookDirectHubFileDownloader.downloadIfNeeded(
                    hub: hub,
                    repoID: repoID,
                    repoId: repoId,
                    revision: commitHash,
                    branchRef: branchRevision,
                    file: file
                ) { fileCompleted, _ in
                    overall.completedUnitCount = baseCompleted + min(file.size, fileCompleted)
                    progressHandler(overall)
                }
            } else {
                _ = try await hub.downloadSnapshot(
                    of: repoID,
                    revision: commitHash,
                    matching: [file.path],
                    maxConcurrentDownloads: 1,
                    progressHandler: { @MainActor fileProgress in
                        let fileCompleted = min(file.size, fileProgress.completedUnitCount)
                        overall.completedUnitCount = baseCompleted + fileCompleted
                        progressHandler(overall)
                    }
                )
            }

            completedBytes = baseCompleted + file.size
            overall.completedUnitCount = completedBytes
            await MainActor.run {
                progressHandler(overall)
            }
        }
    }
}
