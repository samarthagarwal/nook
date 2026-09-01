import Foundation
import NookCore

/// On-device storage used by Nook, measured from real directories.
public struct StorageBreakdown: Sendable, Equatable {
    public let modelsBytes: Int64
    public let knowledgeBytes: Int64
    public let chatsBytes: Int64
    public let deviceFreeBytes: Int64
    public let deviceTotalBytes: Int64

    public var nookBytes: Int64 {
        modelsBytes + knowledgeBytes + chatsBytes
    }

    public static let empty = StorageBreakdown(
        modelsBytes: 0,
        knowledgeBytes: 0,
        chatsBytes: 0,
        deviceFreeBytes: 0,
        deviceTotalBytes: 0
    )
}

public enum AppStorageUsage {
    public static func measure() -> StorageBreakdown {
        let volumes = measureDeviceVolumes()
        return StorageBreakdown(
            modelsBytes: measureModelsBytes(),
            knowledgeBytes: measureDirectoryIfExists(knowledgeDirectory),
            chatsBytes: NookDatabase.fileBytesOnDisk(),
            deviceFreeBytes: volumes.free,
            deviceTotalBytes: volumes.total
        )
    }

    public static func format(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Device volumes

    private static func measureDeviceVolumes() -> (free: Int64, total: Int64) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]) else {
            return (0, 0)
        }

        let free = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let total = Int64(values.volumeTotalCapacity ?? 0)
        return (free, total)
    }

    // MARK: - Models (bundled weights + Hugging Face hub cache)

    private static func measureModelsBytes() -> Int64 {
        var total: Int64 = 0
        total += measureDirectoryIfExists(huggingFaceHubCacheDirectory)
        if let bundled = BundledModelCatalog.bundledDirectoryURL {
            total += measureDirectoryIfExists(bundled)
        }
        return total
    }

    private static var huggingFaceHubCacheDirectory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let path = caches.appendingPathComponent("huggingface/hub", isDirectory: true)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    // MARK: - Placeholders until Knowledge persistence ships

    private static var knowledgeDirectory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let path = support.appendingPathComponent("Nook/Knowledge", isDirectory: true)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    private static func measureDirectoryIfExists(_ url: URL?) -> Int64 {
        guard let url else { return 0 }
        return directorySize(at: url)
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
