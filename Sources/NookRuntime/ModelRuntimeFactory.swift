import Foundation
import NookCore

/// Selects a model runtime appropriate for the current platform.
public enum ModelRuntimeFactory {
    public static func make(activeTier: ModelTier = AppPreferences.activeTier) -> ModelRuntime {
        if MLXPlatformSupport.useMLXInference {
            return MLXModelRuntime(activeTier: activeTier)
        }
        return ScriptedModelRuntime(activeTier: activeTier)
    }
}
