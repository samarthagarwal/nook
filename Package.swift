// swift-tools-version: 6.0
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
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
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
                .product(name: "Tokenizers", package: "swift-transformers")
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
