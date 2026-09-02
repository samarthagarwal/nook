import Foundation

/// Global inference backend selection. Flip to `.mlx` to use the existing MLX stack;
/// `.litert` runs all tiers on LiteRT-LM (default for this branch).
public enum NookInferenceConfig {
    public enum Backend: String, Sendable {
        case litert
        case mlx
    }

    /// Compile-time / single-switch backend. MLX runtime code remains in the tree.
    public static let backend: Backend = .litert

    public static var usesLiteRT: Bool { backend == .litert }
    public static var usesMLX: Bool { backend == .mlx }
}
