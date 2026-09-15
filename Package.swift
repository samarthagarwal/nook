// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Nook",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "NookDesign", targets: ["NookDesign"]),
        .library(name: "NookCore", targets: ["NookCore"]),
        .library(name: "NookRuntime", targets: ["NookRuntime"]),
        .library(name: "NookUI", targets: ["NookUI"]),
        .executable(name: "NookCLI", targets: ["NookCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.6"),
        // Gemma 4 VLM KV-shared layers are fixed on main (#390). Newer than
        // 68947cc also matches the iOS 27 FoundationModels SDK (the older pin
        // fails to compile MLXFoundationModels).
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            revision: "3e6ea1ede1596f05c1715d6b82567619276e98f0",
            // Default trait is unused by Nook; keep it off when SPM honors it.
            traits: []
        ),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Local shallow checkout — remote URL mirror is multi‑GB and stalls Xcode resolve.
        // Committed remote: .package(url: "https://github.com/google-ai-edge/LiteRT-LM", from: "0.16.0")
        .package(path: "/tmp/LiteRT-LM")
    ],
    targets: [
        .target(
            name: "NookDesign",
            dependencies: []
        ),
        .target(
            name: "NookCore",
            dependencies: [
                "NookDesign",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "NookRuntime",
            dependencies: [
                "NookCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "LiteRTLM", package: "LiteRT-LM")
            ],
            resources: [
                .copy("Resources/BundledModels")
            ]
        ),
        .target(
            name: "NookUI",
            dependencies: ["NookDesign", "NookCore", "NookRuntime"]
        ),
        .executableTarget(
            name: "NookCLI",
            dependencies: ["NookCore", "NookRuntime"]
        ),
        .testTarget(
            name: "NookTests",
            dependencies: ["NookDesign", "NookCore", "NookRuntime", "NookUI"]
        )
    ]
)
