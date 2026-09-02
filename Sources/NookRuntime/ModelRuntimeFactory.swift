import Foundation
import NookCore

/// Selects a model runtime appropriate for the current platform and `NookInferenceConfig`.
public enum ModelRuntimeFactory {
    public static func make(activeTier: ModelTier = AppPreferences.activeTier) -> ModelRuntime {
        #if os(iOS)
        #if targetEnvironment(simulator)
        return ScriptedModelRuntime(activeTier: activeTier)
        #endif
        #endif

        switch NookInferenceConfig.backend {
        case .litert:
            return LiteRTModelRuntime(activeTier: activeTier)
        case .mlx:
            // Full MLX stack preserved; Routing kept for any future hybrid experiments.
            if MLXPlatformSupport.useMLXInference {
                return MLXModelRuntime(activeTier: activeTier)
            }
            return ScriptedModelRuntime(activeTier: activeTier)
        }
    }
}
