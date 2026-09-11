import Foundation

/// Global inference backend selection — now driven by user settings in AppPreferences.
/// Flip cloudEnabled in Settings to route generation to OpenAIModelRuntime;
/// otherwise LiteRT (on-device) is used.
public enum NookInferenceConfig {
    public enum Backend: String, Sendable {
        case litert
        case mlx
        case cloud
    }

    /// Current backend — reads from AppPreferences so Settings changes take effect.
    public static var backend: Backend {
        AppPreferences.cloudEnabled ? .cloud : .litert
    }

    /// OpenAI API key from user settings. Empty string means not configured.
    public static var openAIKey: String {
        AppPreferences.openAIAPIKey
    }

    /// OpenAI model name from user settings.
    public static var openAIModel: String {
        AppPreferences.openAIModel
    }

    public static var usesLiteRT: Bool { backend == .litert }
    public static var usesMLX: Bool    { backend == .mlx }
    public static var usesCloud: Bool  { backend == .cloud }
}
