// swift-tools-version:6.0
import PackageDescription

// NOTE: The product/executable name below is the ONE place a build-facing name lives.
// The user-facing display name lives in Sources/KelvinCore/Branding.swift (see CLAUDE.md
// "Naming"). Renaming the app should touch Branding.swift + the bundle ID, not this file.
let package = Package(
    name: "Kelvin",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "KelvinCore", targets: ["KelvinCore"]),
        .executable(name: "kelvin-cli", targets: ["KelvinCLI"])
    ],
    targets: [
        // Core/ — pure, no UI, no model. Decode + Recipe + Render (masks/curves land later).
        .target(
            name: "KelvinCore"
        ),
        // CLI/ — headless entry point. First-class target: it is how the eval harness runs.
        .executableTarget(
            name: "KelvinCLI",
            dependencies: ["KelvinCore"]
        ),
        .testTarget(
            name: "KelvinCoreTests",
            dependencies: ["KelvinCore"]
        )
    ]
)
