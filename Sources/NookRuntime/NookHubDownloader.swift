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

        let resolvedRevision = revision ?? "main"
        let files = try await HubRepoFileLister.listModelFiles(repoId: id, revision: resolvedRevision)
        let matched = HubRepoFileLister.filter(files, matching: patterns)
            .sorted { $0.size < $1.size }

        guard !matched.isEmpty else {
            print("[Download] \(id) — no matching files, falling back to snapshot download")
            return try await hub.downloadSnapshot(
                of: repoID,
                revision: resolvedRevision,
                matching: patterns,
                progressHandler: { @MainActor progress in
                    progressHandler(progress)
                }
            )
        }

        let totalBytes = matched.reduce(Int64(0)) { $0 + $1.size }
        let overall = Progress(totalUnitCount: max(totalBytes, 1))
        var completedBytes: Int64 = 0

        print(
            "[Download] \(id) — staged download of \(matched.count) file(s), \(AppStorageUsage.format(totalBytes)) total"
        )

        for (index, file) in matched.enumerated() {
            let label = AppStorageUsage.format(file.size)
            print("[Download] \(id) — file \(index + 1)/\(matched.count): \(file.path) (\(label))")

            let baseCompleted = completedBytes

            if NookDirectHubFileDownloader.shouldUseDirectDownload(for: file.size) {
                try await NookDirectHubFileDownloader.downloadIfNeeded(
                    hub: hub,
                    repoID: repoID,
                    repoId: id,
                    revision: resolvedRevision,
                    file: file
                ) { fileCompleted, _ in
                    overall.completedUnitCount = baseCompleted + min(file.size, fileCompleted)
                    progressHandler(overall)
                }
            } else {
                _ = try await hub.downloadSnapshot(
                    of: repoID,
                    revision: resolvedRevision,
                    matching: [file.path],
                    maxConcurrentDownloads: 1,
                    progressHandler: { @MainActor fileProgress in
                        let fileCompleted = min(file.size, fileProgress.completedUnitCount)
                        overall.completedUnitCount = baseCompleted + fileCompleted
                        progressHandler(overall)
                    }
                )
            }

            completedBytes += file.size
            overall.completedUnitCount = completedBytes
            await MainActor.run {
                progressHandler(overall)
            }
        }

        return try await hub.downloadSnapshot(
            of: repoID,
            revision: resolvedRevision,
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }
}
