import Foundation

/// Downloads a single Hugging Face `.litertlm` file into `LiteRTModelPaths`.
enum LiteRTModelDownloader {
    static func download(
        repoId: String,
        filename: String,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws -> URL {
        let destination = LiteRTModelPaths.localFileURL(repoId: repoId, filename: filename)
        if LiteRTModelPaths.isDownloaded(repoId: repoId, filename: filename) {
            progressHandler(1.0, nil)
            return destination
        }

        let parts = repoId.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw LiteRTModelRuntimeError.downloadFailed(underlying: URLError(.badURL))
        }

        let resolveURL = URL(string: "https://huggingface.co")!
            .appending(path: parts[0])
            .appending(path: parts[1])
            .appending(path: "resolve")
            .appending(path: "main")
            .appending(path: filename)

        var request = URLRequest(url: resolveURL)
        request.timeoutInterval = 60 * 60

        let logger = DownloadProgressLogger(label: "\(repoId)/\(filename)", minInterval: 3)
        print("[LiteRT] Starting download \(resolveURL.absoluteString)")

        let (tempURL, response) = try await NookDownloadSession.shared.download(
            request: request,
            resumeOffset: 0
        ) { written, expected in
            let total = max(expected, 1)
            let fraction = Double(written) / Double(total)
            let transfer = DownloadTransferProgress(completedBytes: written, totalBytes: total)
            logger.progress(
                mapped: fraction,
                hubFraction: fraction,
                completedUnits: written,
                totalUnits: total,
                note: "\(AppStorageUsage.format(written)) of \(AppStorageUsage.format(total))"
            )
            progressHandler(min(0.99, fraction), transfer)
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode) || http.statusCode == 206
        else {
            throw LiteRTModelRuntimeError.downloadFailed(underlying: URLError(.badServerResponse))
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)

        progressHandler(1.0, DownloadTransferProgress(
            completedBytes: (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0,
            totalBytes: (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        ))
        print("[LiteRT] Saved model to \(destination.path)")
        return destination
    }
}
