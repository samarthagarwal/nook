import Foundation
import NookCore

#if canImport(UIKit)
import UIKit
#endif

extension Notification.Name {
    public static let nookModelUnloadedDueToMemory = Notification.Name("nook.modelUnloadedDueToMemory")
}

enum ModelUnloadReason: String {
    case memoryPressure
    case idle
}

/// Tracks recent iOS memory warnings for diagnostics.
public final class MemoryPressureState: @unchecked Sendable {
    public static let shared = MemoryPressureState()

    private let lock = NSLock()
    private var warningCount = 0
    private var lastWarningAt: Date?

    private init() {}

    public var recentWarningCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return warningCount
    }

    public func recordWarning() {
        lock.lock()
        if let lastWarningAt, Date().timeIntervalSince(lastWarningAt) > 120 {
            warningCount = 0
        }
        warningCount += 1
        lastWarningAt = Date()
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        warningCount = 0
        lastWarningAt = nil
        lock.unlock()
    }
}

/// Observes system memory pressure and notifies the model runtime to release weights.
public final class MemoryPressureMonitor: @unchecked Sendable {
    public static let shared = MemoryPressureMonitor()

    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    private init() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        #endif
    }

    public func setHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    #if canImport(UIKit)
    @objc private func handleMemoryWarning() {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?()
    }
    #endif
}

/// Observes thermal state changes for on-device inference.
public final class ThermalStateMonitor: @unchecked Sendable {
    public enum Advice: Sendable, Equatable {
        case normal
        case warm
        case throttled
    }

    public static let shared = ThermalStateMonitor()

    private let lock = NSLock()
    private var handler: (@Sendable (Advice) -> Void)?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThermalChange),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    public var currentAdvice: Advice {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair:
            return .normal
        case .serious:
            return .warm
        case .critical:
            return .throttled
        @unknown default:
            return .normal
        }
    }

    public func setHandler(_ handler: (@Sendable (Advice) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
        if let handler {
            handler(currentAdvice)
        }
    }

    @objc private func handleThermalChange() {
        let advice = currentAdvice
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(advice)
    }
}
