# KelvinPerceptionMLX

The real perception backend for Kelvin: a small on-device VLM (**Qwen3.5-2B, 4-bit**,
Apache-2.0) that reads a photo and returns a `KelvinCore.Perception` — categorical judgments
only, never numbers (CLAUDE.md non-negotiable #1).

**Model weights are downloaded at runtime and are NOT redistributed by this repository.** The
default is Apache-2.0 so that anyone can use Kelvin for anything. `KELVIN_MODEL=<hf-repo-id>`
swaps it without a rebuild — if you point it somewhere else, the terms of that model become
yours to honour. This matters more than it looks: the previous default was
`Qwen2.5-VL-3B-Instruct`, which is licensed for *"research or evaluation purposes only"* and
was documented here as Apache-2.0 for months. See `docs/DECISIONS.md` D-model-3.

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

The first *run* downloads the model (~1.5 GB) from Hugging Face and caches it.

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
- The target **compiles** (`swift build` → *Build complete*, ~71 s cold), so the provider
  type-checks against the real `mlx-swift-lm` 3.31.4 API (`ChatSession`, `respond(to:image:)`,
  `GenerateParameters`, `UserInput.Image.ciImage`, the `#huggingFaceLoadModelContainer` macro).
- **Live inference verified end-to-end.** `swift run kelvin-perceive <image> [out-dir]` loads
  the model, perceives a real photo, and the model emits valid closed-vocabulary perception
  JSON (categorical only — no numbers), which parses cleanly and drives the engine + renderer.
  First run downloads ~2.9 GB to `~/.cache/huggingface`; after that, inference is seconds.

### Metal Toolchain prerequisite

Xcode 16+ ships the Metal compiler as a separate component. If `swift build` fails with
`cannot execute tool 'metal' due to missing Metal Toolchain`, install it once:

```sh
xcodebuild -downloadComponent MetalToolchain
```

(This was the sole reason an earlier build attempt failed — not the code and not the toolchain
version.)
