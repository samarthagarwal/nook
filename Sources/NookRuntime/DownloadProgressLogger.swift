import Foundation

/// Throttled NSLog-style progress for long model downloads (avoids log spam).
final class DownloadProgressLogger: @unchecked Sendable {
    private let label: String
    private let lock = NSLock()
    private var lastLoggedPercent = -1
    private var lastLogTime = Date.distantPast
    private var lastCompletedUnits: Int64?
    private var lastUnitsChangeTime = Date.distantPast
    private let minInterval: TimeInterval
    private let stallWarningInterval: TimeInterval

    init(label: String, minInterval: TimeInterval = 5, stallWarningInterval: TimeInterval = 45) {
        self.label = label
        self.minInterval = minInterval
        self.stallWarningInterval = stallWarningInterval
    }

    func phase(_ note: String) {
        print("[Download] \(label) — \(note)")
    }

    func progress(
        mapped: Double,
        hubFraction: Double? = nil,
        completedUnits: Int64? = nil,
        totalUnits: Int64? = nil,
        note: String? = nil
    ) {
        let percent = Int((min(1.0, max(0.0, mapped)) * 100).rounded())
        let hubPercentLabel: String? = hubFraction.map { fraction in
            let value = fraction * 100
            if value < 1 {
                return String(format: "%.1f%%", value)
            }
            return "\(Int(value.rounded()))%"
        }

        lock.lock()
        let now = Date()
        if let completedUnits {
            if completedUnits != lastCompletedUnits {
                lastCompletedUnits = completedUnits
                lastUnitsChangeTime = now
            }
        }
        let stalled = completedUnits != nil
            && now.timeIntervalSince(lastUnitsChangeTime) >= stallWarningInterval
        let shouldLog = percent == 100
            || lastLoggedPercent < 0
            || percent - lastLoggedPercent >= 5
            || now.timeIntervalSince(lastLogTime) >= minInterval
            || stalled
        if shouldLog {
            lastLoggedPercent = percent
            lastLogTime = now
            if stalled, completedUnits != nil {
                lastUnitsChangeTime = now
            }
        }
        lock.unlock()

        guard shouldLog else { return }

        var parts = ["\(percent)%"]
        if let hubPercentLabel {
            parts.append("hub \(hubPercentLabel)")
        }
        if let completedUnits, let totalUnits, totalUnits > 0 {
            parts.append("units \(completedUnits)/\(totalUnits)")
        }
        if let note, !note.isEmpty {
            parts.append(note)
        }
        if stalled {
            parts.append("no new bytes for \(Int(stallWarningInterval))s — keep app open on Wi‑Fi")
        }
        print("[Download] \(label): \(parts.joined(separator: " · "))")
    }

    func error(_ error: Error, attempt: Int, maxAttempts: Int) {
        print("[Download] \(label) attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)")
    }
}
