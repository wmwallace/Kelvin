# Architecture

## The pipeline

```
  ┌─────────────┐
  │   Decode    │  RAW / JPEG / PNG → linear buffer
  │             │  Core Image, cached, done once per file
  └──────┬──────┘
         │
         ├──────────────────► full-res buffer (export only)
         │
         ▼
  ┌─────────────┐
  │    Proxy    │  ~2048px working, ~768px for the model
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │ Perception  │  small VLM → perception JSON
  │             │  categorical judgments only, no numbers
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │   Recipe    │  perception + histogram + EXIF → N recipes
  │   engine    │  deterministic, unit-tested
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  Candidates │  3–4 recipes rendered against one resident texture
  │             │  cheap: parameter swaps, not re-decodes
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  User pick  │  → preference pair → batch propagation
  └─────────────┘
```

## Why the layering is what it is

**Decode once.** RAW decode and demosaicing is the single most expensive operation in
the app — hundreds of milliseconds to seconds per file, CPU-bound. Everything downstream
is cheap if this is cached correctly and ruinous if it is not. Cache the demosaiced
linear buffer keyed by file hash.

**Proxy everywhere.** No interactive operation ever touches full resolution. Full res is
decoded once more at export time and the recipe is replayed against it. This is why the
app can feel instant on a 45-megapixel file.

**The model sees a thumbnail.** 768px is enough for scene, subject, lighting, and
problem detection. It is not enough for pixel-level work, and we do not ask it to do
pixel-level work. Inference cost becomes negligible.

**Candidates are parameter swaps.** This is the key performance insight and it falls out
of the recipe design. Once the proxy is uploaded to the GPU, generating four style
previews is four shader passes against resident memory. No re-decode, no re-upload, no
model call. Effectively instant.

If you ever find yourself re-running perception to produce a second candidate, the
architecture has been broken.

## Module boundaries

```
Sources/KelvinCore/
  Decode/         file → linear buffer, EXIF. Knows nothing about recipes.
  Recipe/         the schema, serialization, validation, ranges.
  Render/         buffer + recipe → buffer. Pure. No I/O, no UI, no model.
  Perception/     proxy → perception JSON. Swappable model backend (protocol here,
                  MLX implementation in Integrations/).
  Engine/         perception + stats → [Recipe]. Pure. Deterministic. No I/O.
  Eval/           the harness: corpus, metrics, baselines, degradation builder.
  Preference/     pick logging and, later, reweighting.
  Browse/         folder scan, ordering, triage. Flat and file-based — no catalogue.
  Batch/          recipe propagation across a folder, with overwrite refusal.
  Export/         naming and collision policy.
Sources/KelvinCLI/
  kelvin-cli      headless entry point: render, engine, eval, corpus tools.
Integrations/KelvinPerceptionMLX/
  KelvinPerceptionMLX   the MLX-backed perception provider.
  KelvinApp             SwiftUI. Depends on everything. Nothing depends on it.
  kelvin-perceive       headless perception over one image.
```

Edits persist as JSON in Kelvin's Application Support folder, keyed to the photograph —
never as files written next to anyone's originals.

**`Render` and `Engine` must both be pure and independently testable.** They are the two
places bugs will actually hurt, and they are the two places you can get full test
coverage cheaply. If either one grows an I/O dependency, that is a design failure.

The CLI is not a toy — it is how the eval harness runs, and it is the first thing built.
Treat it as a first-class target, not a debug affordance.

## Performance targets

Fixed early so regressions are visible.

| Operation | Target | Notes |
|---|---|---|
| Slider drag → visible update | < 16 ms | one frame; this is the whole feel of the app |
| Recipe swap (candidate → candidate) | < 50 ms | resident texture, parameter change only |
| Cold RAW decode, 45 MP | < 1.5 s | Core Image, cached after |
| Perception pass | < 2 s | 768px proxy, 4-bit model. Currently missed: D-model-3 measured ~4.5–6 s |
| Full analysis, first open | < 4 s | decode + proxy + perception + 4 candidates |
| Apply a look to a shoot | < 100 ms | one JSON record; nothing is rendered (D13) |
| Export 100 look-carried frames | perception-bound | a decode + perception pass per frame, by design |

The first row is the one users feel. Protect it above all others.

## What is deliberately not here

- **Generative editing.** Inpainting and object removal are a later feature layered on
  top of a finished recipe, never part of the base edit. Different problem, different
  models, different failure modes.
- **Cloud anything.** No sync, no accounts, no telemetry in v1.
- **Cross-platform.** See `DECISIONS.md`.
- **A full digital-asset-management catalogue.** A flat, fast, folder-based library. Do not
  build a database-backed asset manager.
