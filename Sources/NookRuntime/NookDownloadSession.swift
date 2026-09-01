import Foundation

enum NookHubSessionConfig {
    static func make() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10 * 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.waitsForConnectivity = false
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.httpMaximumConnectionsPerHost = 4
        return config
    }
}

/// URLSession with a retained download delegate — required for reliable multi-GB file progress on iOS.
final class NookDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = NookDownloadSession()

    private struct TaskState {
        var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        var onProgress: (@Sendable (Int64, Int64) -> Void)?
        var resumeOffset: Int64
        var tempURL: URL?
    }

    private let lock = NSLock()
    private var tasks: [Int: TaskState] = [:]

    private lazy var session: URLSession = {
        URLSession(configuration: NookHubSessionConfig.make(), delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    func download(
        request: URLRequest,
        resumeOffset: Int64 = 0,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            var request = request
            if resumeOffset > 0 {
                request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            }

            let task = session.downloadTask(with: request)
            lock.lock()
            tasks[task.taskIdentifier] = TaskState(
                continuation: continuation,
                onProgress: onProgress,
                resumeOffset: resumeOffset,
                tempURL: nil
            )
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let state = tasks[downloadTask.taskIdentifier]
        lock.unlock()
        guard let onProgress = state?.onProgress else { return }

        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
        let offset = status == 206 ? (state?.resumeOffset ?? 0) : 0
        let written = totalBytesWritten + offset
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite + offset : written
        onProgress(written, expected)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let copied = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        do {
            try FileManager.default.copyItem(at: location, to: copied)
            lock.lock()
            tasks[downloadTask.taskIdentifier]?.tempURL = copied
            lock.unlock()
        } catch {
            lock.lock()
            tasks[downloadTask.taskIdentifier]?.tempURL = location
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = tasks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        guard let state else { return }

        if let error {
            if let temp = state.tempURL {
                try? FileManager.default.removeItem(at: temp)
            }
            state.continuation?.resume(throwing: error)
            return
        }

        guard let tempURL = state.tempURL, let response = task.response else {
            state.continuation?.resume(throwing: URLError(.badServerResponse))
            return
        }

        state.continuation?.resume(returning: (tempURL, response))
    }
}
