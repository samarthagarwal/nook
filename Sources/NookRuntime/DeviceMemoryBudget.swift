import Foundation
import NookCore
import os

#if canImport(Darwin)
import Darwin
#endif

/// Pre-flight checks before loading large MLX models on iPhone.
enum DeviceMemoryBudget {
    /// Memory this process can still allocate before jetsam.
    /// Not the same as “free RAM” in Xcode — it drops once weights are resident.
    static var availableBytes: UInt64 {
        #if os(iOS) && !targetEnvironment(simulator)
        return UInt64(os_proc_available_memory())
        #else
        return 8_000_000_000
        #endif
    }

    static var physicalBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    static func formattedAvailable() -> String {
        let megabytes = Double(availableBytes) / 1_048_576.0
        return String(format: "%.0f MB", megabytes)
    }

    /// Device class gate for Balanced (Gemma 4 E2B VLM).
    private static let balancedMinimumPhysical: UInt64 = 7_500_000_000
    /// Headroom needed to *start* a cold load (not the full weight size —
    /// `os_proc_available_memory` collapses once weights are mapped).
    private static let balancedMinimumAvailableToLoad: UInt64 = 1_200_000_000

    /// Whether this device class can run the tier at all (ignores momentary free memory).
    static func deviceSupports(_ tier: ModelTier) -> Bool {
        switch tier.id {
        case "balanced":
            return physicalBytes >= balancedMinimumPhysical
        default:
            return true
        }
    }

    /// Whether it is safe to begin a cold load of weights into memory.
    static func canLoadModel(for tier: ModelTier) -> Bool {
        guard deviceSupports(tier) else { return false }
        switch tier.id {
        case "balanced":
            return availableBytes >= balancedMinimumAvailableToLoad
        default:
            return true
        }
    }

    static func loadBlockReason(for tier: ModelTier, alreadyLoaded: Bool = false) -> String? {
        // If weights are already resident, do not re-check allocatable memory —
        // available bytes will look “too low” precisely because the model is loaded.
        if alreadyLoaded {
            return nil
        }

        guard deviceSupports(tier) else {
            switch tier.id {
            case "balanced":
                return "Balanced (Gemma 4 E2B) needs an iPhone with at least 8 GB of RAM. Use Bundled or Fast for this device."
            default:
                return "This model isn’t supported on this device."
            }
        }

        guard canLoadModel(for: tier) else {
            switch tier.id {
            case "balanced":
                return "Not enough free memory to load Gemma 4 E2B right now. Close other apps, wait a moment, or use Bundled or Fast."
            default:
                return "Not enough free memory to load the model."
            }
        }

        return nil
    }
}
