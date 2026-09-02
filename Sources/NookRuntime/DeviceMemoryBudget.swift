import Foundation
import NookCore
import os

#if canImport(Darwin)
import Darwin
#endif

/// Pre-flight checks before loading large MLX models on iPhone.
enum DeviceMemoryBudget {
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

    /// E2B VLM needs headroom for weights, vision encoder, and prefill KV cache.
    private static let balancedMinimumAvailable: UInt64 = 3_200_000_000
    private static let balancedMinimumPhysical: UInt64 = 7_500_000_000

    static func canLoadModel(for tier: ModelTier) -> Bool {
        switch tier.id {
        case "balanced":
            return physicalBytes >= balancedMinimumPhysical
                && availableBytes >= balancedMinimumAvailable
        default:
            // Bundled Qwen and Fast LFM2.5 fit comfortably.
            return true
        }
    }

    static func loadBlockReason(for tier: ModelTier) -> String? {
        guard !canLoadModel(for: tier) else { return nil }

        switch tier.id {
        case "balanced":
            if physicalBytes < balancedMinimumPhysical {
                return "Balanced (Gemma 4 E2B) needs an iPhone with at least 8 GB of RAM. Use Bundled or Fast for this device."
            }
            return "Not enough free memory for Gemma 4 E2B (~3.6 GB). Close other apps or use Bundled or Fast."
        default:
            return "Not enough free memory to load the model."
        }
    }
}
