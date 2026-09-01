import Foundation

public struct DownloadTransferProgress: Equatable, Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(completedBytes) / Double(totalBytes)))
    }
}

public enum ModelDownloadProgressMapper {
    /// Maps Hugging Face hub progress into UI bar position (5%–85% while downloading files).
    public static func mapHubProgress(_ progress: Progress) -> (uiFraction: Double, transfer: DownloadTransferProgress?) {
        let completed = progress.completedUnitCount
        let total = progress.totalUnitCount

        let hubFraction: Double
        if total > 0 {
            hubFraction = min(1.0, max(0.0, Double(completed) / Double(total)))
        } else {
            hubFraction = min(1.0, max(0.0, progress.fractionCompleted))
        }

        let uiFraction = min(1.0, max(0.0, 0.05 + (hubFraction * 0.80)))
        let transfer = total > 0 ? DownloadTransferProgress(completedBytes: completed, totalBytes: total) : nil
        return (uiFraction, transfer)
    }

    public static func mapTransfer(_ transfer: DownloadTransferProgress) -> Double {
        min(1.0, max(0.0, 0.05 + (transfer.fraction * 0.80)))
    }

    public static func mergedTransfer(
        hub: DownloadTransferProgress?,
        disk: DownloadTransferProgress?
    ) -> DownloadTransferProgress? {
        switch (hub, disk) {
        case let (hub?, disk?):
            let total = max(hub.totalBytes, disk.totalBytes)
            // Disk cache can include bytes from a prior attempt while hub/direct
            // download restarted — trust the active transfer until it finishes.
            if hub.fraction < 0.99 {
                return DownloadTransferProgress(completedBytes: hub.completedBytes, totalBytes: total)
            }
            let completed = max(hub.completedBytes, disk.completedBytes)
            return DownloadTransferProgress(completedBytes: completed, totalBytes: total)
        case let (hub?, nil):
            return hub
        case let (nil, disk?):
            return disk
        case (nil, nil):
            return nil
        }
    }

    public static func statusNote(
        for transfer: DownloadTransferProgress?,
        uiFraction: Double
    ) -> String? {
        guard let transfer, transfer.totalBytes > 0 else {
            if uiFraction < 0.05 {
                return "connecting to Hugging Face"
            }
            return nil
        }

        let downloaded = AppStorageUsage.format(transfer.completedBytes)
        let total = AppStorageUsage.format(transfer.totalBytes)

        if transfer.fraction < 0.01 {
            return "\(downloaded) of \(total) — downloading model weights"
        }
        return "\(downloaded) of \(total)"
    }
}
