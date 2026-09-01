// swift-tools-version: 5.10
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
        .executable(name: "NookApp", targets: ["NookApp"]),
        .executable(name: "NookCLI", targets: ["NookCLI"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "NookDesign",
            dependencies: []
        ),
        .target(
            name: "NookCore",
            dependencies: ["NookDesign"]
        ),
        .target(
            name: "NookRuntime",
            dependencies: ["NookCore"]
        ),
        .target(
            name: "NookUI",
            dependencies: ["NookDesign", "NookCore", "NookRuntime"]
        ),
        .executableTarget(
            name: "NookApp",
            dependencies: ["NookDesign", "NookCore", "NookRuntime", "NookUI"]
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
