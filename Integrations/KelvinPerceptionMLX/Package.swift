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
        .executable(name: "kelvin-perceive", targets: ["kelvin-perceive"]),
        // The SwiftUI app. It lives here (not the root package) so it can use the real VLM
        // backend; the root package stays MLX-free.
        .executable(name: "kelvin-app", targets: ["KelvinApp"])
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
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        // Auto-update for the released .app. MIT-licensed, GPL-compatible. The updater only
        // activates inside a bundle whose Info.plist carries SUFeedURL (see AppMain) — a
        // `swift run` dev build has no plist and therefore no update machinery at all.
        // Pinned exact like mlx-swift-lm: applications pin, and the version in use is the one
        // the release process has actually been exercised against. Bump deliberately.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.8.1")
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
        ),
        .executableTarget(
            name: "KelvinApp",
            dependencies: [
                "KelvinPerceptionMLX",
                .product(name: "KelvinCore", package: "Kelvin"),
                .product(name: "Sparkle", package: "Sparkle")
            ]
            // Icon comes from the packaged .app's .icns (CFBundleIconFile) — no runtime
            // Bundle.module lookup, which fatal-errors inside a hand-assembled bundle.
        ),
        // The app layer's logic, tested. It had no test target at all, and a whole class of bug
        // shipped straight through the gap: two mask editors offering different adjustment lists,
        // `toMask()` dropping adjustments the renderer honours, sidecar fields silently not
        // persisted. All of those are pure value-level rules with no window in sight.
        //
        // Depending on an EXECUTABLE target is deliberate and it does work: SwiftPM links the test
        // bundle against the executable's objects and hides `_main`, so `@testable import KelvinApp`
        // reaches the whole app module without KelvinApp having to be split into a library first.
        // Views are out of scope here — nothing in this target renders SwiftUI.
        .testTarget(
            name: "KelvinAppTests",
            dependencies: [
                "KelvinApp",
                "KelvinPerceptionMLX",
                .product(name: "KelvinCore", package: "Kelvin")
            ],
            // The test bundle links KelvinApp, which links @rpath/Sparkle.framework — and the
            // build system copies that framework next to the .xctest, not inside it. Three
            // levels up from Contents/MacOS/KelvinAppTests is the products directory where it
            // lives; without this, every test dies in dlopen before one assertion runs.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])
            ]
        )
    ]
)
