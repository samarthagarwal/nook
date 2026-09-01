import Foundation

final class DownloadProgressCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var hubTransfer: DownloadTransferProgress?
    private let onReport: @Sendable (DownloadTransferProgress) -> Void

    init(onReport: @escaping @Sendable (DownloadTransferProgress) -> Void) {
        self.onReport = onReport
    }

    func updateHub(_ transfer: DownloadTransferProgress?) {
        lock.lock()
        hubTransfer = transfer
        lock.unlock()
        report(disk: nil)
    }

    func report(disk: DownloadTransferProgress?) {
        lock.lock()
        let hub = hubTransfer
        lock.unlock()

        guard let merged = ModelDownloadProgressMapper.mergedTransfer(hub: hub, disk: disk) ?? hub ?? disk else {
            return
        }
        onReport(merged)
    }
}
