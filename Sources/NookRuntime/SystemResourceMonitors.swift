import Foundation
import NookCore

#if canImport(UIKit)
import UIKit
#endif

extension Notification.Name {
    public static let nookModelUnloadedDueToMemory = Notification.Name("nook.modelUnloadedDueToMemory")
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
