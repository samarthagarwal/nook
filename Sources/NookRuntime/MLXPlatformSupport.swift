import Foundation

/// Platform gates for MLX inference.
public enum MLXPlatformSupport {
    /// MLX on macOS and physical iOS devices. Simulator uses the scripted runtime because
    /// Metal/MLX is unreliable in the iOS Simulator.
    public static var useMLXInference: Bool {
        #if os(iOS)
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
        #else
        return true
        #endif
    }

    public static var runtimeLabel: String {
        #if os(iOS)
        #if targetEnvironment(simulator)
        return "ScriptedModelRuntime (simulator)"
        #else
        return useMLXInference ? "MLXModelRuntime (device)" : "ScriptedModelRuntime"
        #endif
        #else
        return "MLXModelRuntime (macOS)"
        #endif
    }
}
