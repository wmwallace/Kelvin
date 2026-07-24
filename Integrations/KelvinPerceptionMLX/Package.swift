// swift-tools-version:6.1
import PackageDescription

// KelvinPerceptionMLX — the real VLM backend for the perception layer, kept in a SEPARATE
// nested package on purpose.
//
// MLX pulls a large dependency graph and compiles Metal kernels, and it requires macOS 14.
// The root Kelvin package must stay MLX-free: its eval harness and renderer are headless,
// fast, and independently testable (ARCHITECTURE.md), and they must not inherit a heavier OS
// floor or a multi-minute build for a feature not every build needs. This package depends on
// the root by path and conforms to KelvinCore's `PerceptionProvider` seam, so it drops in
// without the core ever knowing MLX exists.
//
// Build it explicitly:  cd Integrations/KelvinPerceptionMLX && swift build
let package = Package(
    name: "KelvinPerceptionMLX",
    platforms: [
        .macOS(.v14)   // required by mlx-swift-lm
    ],
    products: [
        .library(name: "KelvinPerceptionMLX", targets: ["KelvinPerceptionMLX"]),
        // A tiny driver that proves the on-device loop: perceive a photo → engine → render.
        .executable(name: "kelvin-perceive", targets: ["kelvin-perceive"])
    ],
    dependencies: [
        .package(name: "Kelvin", path: "../.."),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        // mlx-swift-lm's Hugging Face loader macros expand against these two packages but do
        // not declare them — the consumer must supply them. swift-transformers vends the
        // `Tokenizers` module; swift-huggingface vends the `HuggingFace` module (the old `Hub`
        // module, renamed). Versions are chosen to satisfy the macro's API surface
        // (HubClient, Repo.ID, AutoTokenizer.from(modelFolder:)).
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "KelvinPerceptionMLX",
            dependencies: [
                .product(name: "KelvinCore", package: "Kelvin"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface")
            ]
        ),
        .executableTarget(
            name: "kelvin-perceive",
            dependencies: [
                "KelvinPerceptionMLX",
                .product(name: "KelvinCore", package: "Kelvin")
            ]
        )
    ]
)
