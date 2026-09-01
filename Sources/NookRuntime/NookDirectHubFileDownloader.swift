import Foundation
import HuggingFace

enum NookDirectHubFileDownloader {
    private static let largeFileThreshold: Int64 = 32 * 1024 * 1024

    static func shouldUseDirectDownload(for size: Int64) -> Bool {
        size >= largeFileThreshold
    }

    static func downloadIfNeeded(
        hub: HubClient,
        repoID: Repo.ID,
        repoId: String,
        revision: String,
        file: HubRepoFileEntry,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        guard shouldUseDirectDownload(for: file.size) else { return }

        if let cache = hub.cache,
           cache.cachedFilePath(repo: repoID, kind: .model, revision: revision, filename: file.path) != nil {
            print("[Download] \(repoId) — \(file.path) already cached, skipping direct download")
            onProgress(file.size, file.size)
            return
        }

        guard let cache = hub.cache else {
            throw URLError(.cannotCreateFile)
        }

        let resolveURL = HubClient.defaultHost
            .appending(path: repoID.namespace)
            .appending(path: repoID.name)
            .appending(path: "resolve")
            .appending(component: revision)
            .appending(path: file.path)

        print("[Download] \(repoId) — direct download starting for \(file.path)")

        var headRequest = URLRequest(url: resolveURL)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 120

        let (_, headResponse) = try await URLSession.shared.data(for: headRequest)
        guard let httpHead = headResponse as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let rawEtag = httpHead.value(forHTTPHeaderField: "X-Linked-Etag")
            ?? httpHead.value(forHTTPHeaderField: "ETag")
        let commitHash = httpHead.value(forHTTPHeaderField: "X-Repo-Commit") ?? revision

        guard let rawEtag else {
            throw URLError(.resourceUnavailable)
        }

        let normalizedEtag = cache.normalizeEtag(rawEtag)
        let incompletePath = try cache.incompleteBlobPath(repo: repoID, kind: .model, etag: normalizedEtag)
        // Resume via Hub incomplete blobs is unreliable here; start each direct attempt cleanly.
        try? FileManager.default.removeItem(at: incompletePath)
        let resumeOffset: Int64 = 0

        var downloadRequest = URLRequest(url: resolveURL)
        downloadRequest.timeoutInterval = 60 * 60

        let logger = DownloadProgressLogger(label: "\(repoId)/\(file.path)", minInterval: 3)

        let (tempURL, response) = try await NookDownloadSession.shared.download(
            request: downloadRequest,
            resumeOffset: resumeOffset
        ) { written, expected in
            let fraction = expected > 0 ? Double(written) / Double(expected) : 0
            logger.progress(
                mapped: fraction,
                hubFraction: fraction,
                completedUnits: written,
                totalUnits: expected,
                note: "\(AppStorageUsage.format(written)) of \(AppStorageUsage.format(expected))"
            )
            onProgress(written, max(expected, file.size))
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) || httpResponse.statusCode == 206
        else {
            throw URLError(.badServerResponse)
        }

        let responseEtag = (httpResponse.value(forHTTPHeaderField: "X-Linked-Etag")
            ?? httpResponse.value(forHTTPHeaderField: "ETag"))
            .map { cache.normalizeEtag($0) } ?? normalizedEtag

        try await cache.storeFile(
            at: tempURL,
            repo: repoID,
            kind: .model,
            revision: commitHash,
            filename: file.path,
            etag: responseEtag,
            ref: nil
        )

        try? FileManager.default.removeItem(at: incompletePath)

        onProgress(file.size, file.size)
        print("[Download] \(repoId) — direct download finished for \(file.path)")
    }
}
