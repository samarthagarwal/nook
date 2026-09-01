import Foundation

/// Polls the on-disk Hugging Face cache while hub `Progress` is slow to update during large shards.
final class HubDownloadDiskMonitor: @unchecked Sendable {
    private let repoId: String
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var lastBytes: Int64 = 0
    private var lastChange = Date.distantPast

    init(repoId: String) {
        self.repoId = repoId
    }

    func start(
        totalBytes: Int64,
        onUpdate: @escaping @Sendable (DownloadTransferProgress) -> Void
    ) {
        lock.lock()
        if task != nil {
            lock.unlock()
            return
        }

        let repoId = repoId
        let newTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let bytes = HubDownloadPrep.cachedBytes(repoId: repoId)
                let transfer = DownloadTransferProgress(completedBytes: bytes, totalBytes: totalBytes)

                if bytes > 0 {
                    onUpdate(transfer)
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        task = newTask
        lock.unlock()
    }

    func noteProgressBytes(_ bytes: Int64) {
        lock.lock()
        if bytes != lastBytes {
            lastBytes = bytes
            lastChange = Date()
        }
        lock.unlock()
    }

    func secondsSinceLastByteChange() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastChange)
    }

    func stop() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }
}
