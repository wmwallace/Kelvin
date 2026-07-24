# KelvinPerceptionMLX

The real perception backend for Kelvin: a small on-device VLM (**Qwen2.5-VL-3B-Instruct,
4-bit**, Apache-2.0) that reads a photo and returns a `KelvinCore.Perception` — categorical
judgments only, never numbers (CLAUDE.md non-negotiable #1).

It is a **separate nested Swift package on purpose.** MLX pulls a large dependency graph,
compiles Metal kernels, and requires macOS 14. The root `Kelvin` package must stay MLX-free so
its eval harness and renderer remain headless, fast, and independently testable
(ARCHITECTURE.md). This package depends on the root by path and conforms to KelvinCore's
`PerceptionProvider` seam, so the core never knows MLX exists.

## Build

```sh
cd Integrations/KelvinPerceptionMLX
swift build          # first build compiles MLX's Metal kernels — several minutes
```

The first *run* downloads the model (~2–3 GB) from Hugging Face and caches it.

## Usage

```swift
import KelvinCore
import KelvinPerceptionMLX

let provider = MLXPerceptionProvider()                 // loads the model container lazily
let perception = try await provider.perceive(image)    // image: CIImage
let stats = try ImageStatistics.compute(image)
let recipe = RecipeEngine.recipe(perception: perception, statistics: stats)
```

## Dependencies

- `mlx-swift-lm` (exact 3.31.4) — MLXVLM, MLXLMCommon, MLXHuggingFace
- `swift-transformers` — the `Tokenizers` module
- `swift-huggingface` — the `HuggingFace` module

`mlx-swift-lm`'s Hugging Face loader macros expand against `Tokenizers.*` and `HuggingFace.*`
but do **not** declare those packages themselves, so they are listed here directly. If a future
`mlx-swift-lm` bump changes the macro's expected API, adjust these two versions to match.

## Verification status

- Dependency graph **resolves** cleanly.
- Provider code is written against the source-verified `mlx-swift-lm` 3.31.4 API (`ChatSession`,
  `respond(to:image:)`, `GenerateParameters`, `UserInput.Image.ciImage`, the
  `#huggingFaceLoadModelContainer` macro).
- The Swift target's **type-check has not been confirmed in CI**: the sandbox used to author
  this could not compile MLX's Metal shaders (a `metal`-compiler crash under a beta toolchain,
  unrelated to this code). Build once on a standard Apple-Silicon Xcode to confirm, and treat
  any first-build API drift as expected maintenance of the three pinned dependencies above.
