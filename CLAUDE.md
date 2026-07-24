# CLAUDE.md

Read this first, every session. Then read `docs/DECISIONS.md` before proposing any
architectural change — most of the obvious ideas have already been considered and
rejected for reasons recorded there.

---

## What this is

A local-AI photo editor for macOS. You drop in a photo (RAW, JPEG, or PNG), a small
vision model reads the scene, and the app hands back three or four fully-formed
candidate edits. You pick the one you like. It applies that look to the rest of the
shoot, and it learns from your pick.

Everything runs on-device. No cloud, no account, no upload.

## The one-sentence differentiator

**Semantic understanding of a single photo produces several candidate parametric
recipes; the user's pick becomes training signal.**

Everything else in this app is table stakes that other tools already do better. If a
proposed feature does not serve that sentence, it is out of scope for v1.

---

## Non-negotiables

These are load-bearing. Do not violate them without an explicit conversation.

### 1. The model never emits numbers

The VLM outputs **structured judgments only**: scene type, subject, lighting condition,
what is technically wrong, likely intent. Classification and description.

The recipe engine computes every actual parameter from the histogram, the EXIF, and the
mask stack. Deterministic code, unit-tested, debuggable.

A small model asked for `exposure_ev: +0.37` will invent it confidently and you will
never be able to tell a good hallucination from a bad one. This split is the entire
reason the architecture works with 4B-class models. See `docs/RECIPE-SCHEMA.md`.

### 2. Do not build a RAW pipeline

Core Image's RAW support gives us Apple's decoder, demosaicing, and per-camera color
profiles for free. That is a year of color science we are not spending.

If you find yourself writing a demosaicing algorithm, stop and ask.

### 3. Edits are parametric and non-destructive, always

The unit of work is a **recipe** — a small struct of numbers — not pixels. Recipes
serialize to a sidecar file. The original is never written to.

Generative pixel editing (inpainting, object removal) is a *separate, later* feature
that operates on top of a recipe. It is never part of the base edit path.

### 4. Proxy-first

Everything interactive runs on a downsampled proxy. Full resolution touches the pipeline
exactly once, at export.

The VLM sees a ~768px JPEG proxy and never the RAW. This turns perception from a
bottleneck into a rounding error.

### 5. Boring infrastructure, novel product

The novelty budget is fully spent on the recipe IR and the preference loop. Everything
else — rendering, file handling, UI — should be the most proven, least clever approach
available.

Rationale: novel architecture plus novel product means two unsolved problems at once,
and when an edit comes out ugly you cannot tell which one failed.

---

## Stack

**Proposed, not yet confirmed with the owner. Confirm before the first real commit.**

| Layer | Choice | Why |
|---|---|---|
| Language | Swift 6 | Native, no bridge tax, best Mac polish per hour |
| UI | SwiftUI | Native scroll/gesture/menu behaviour for free |
| RAW decode | Core Image (`CIRAWFilter`) | Apple's decoder + camera profiles, zero cost |
| Render | Metal / Core Image kernels | Same memory as the decoder, no copy |
| Inference | MLX Swift | On-device, no Python in the bundle |
| Perception model | Small open VLM, 4B-class, 4-bit | Fits in memory alongside image buffers |
| Persistence | JSON sidecars + SQLite index | Human-readable edits, fast library |

**Known cost of this stack:** Metal shaders do not port. This is a Mac-only app unless
rewritten. That is accepted — Mac-only is positioning, not a limitation.

If the owner wants cross-platform instead, the alternative is Rust + wgpu + Tauri. Do
not mix the two.

---

## Build order

Do not skip ahead. The UI is the last thing, not the first.

1. **Recipe schema + renderer** — a headless CLI that takes an image plus a recipe JSON
   and writes an output. No AI yet. Proves the parametric pipeline.
2. **Evaluation harness** — score a recipe against a reference corpus. See
   `docs/EVALUATION.md`. **This must exist before any model work.**
3. **Recipe engine** — hand-written rules mapping perception output to recipes. Still no
   model; feed it hand-labelled perception JSON. Get the numbers good.
4. **Perception layer** — wire in the VLM to produce the perception JSON that step 3
   already consumes.
5. **Candidate generation** — produce 3–4 meaningfully different recipes per image.
6. **Preference store** — record which candidate was picked. Just logging at first.
7. **UI** — only now.
8. **Batch apply** — recipe propagation across a folder.
9. **Preference learning** — use the logged pairs to reweight candidate generation.

The reason for this order: if the recipes are bad, the most beautiful app in the world
is worthless. Find that out in week three, not month nine.

---

## Conventions

- **Display name lives in exactly one constant.** Never hardcode the product name in a
  view, a string literal, or a filename. The project is getting renamed; make it a
  one-line change. See "Naming" below.
- **Bundle ID is reverse-DNS and treated as sacred.** Changing it after users exist
  orphans their preferences, keychain entries, and sandbox container.
- Recipe schema is versioned from commit one. Every serialized recipe carries `version`.
- A recipe of all-neutral values must render a byte-identical no-op. This is a test.
- Prefer `struct` over `class`. Prefer value semantics for anything in the recipe path.
- No force-unwrapping outside tests.

## Naming

The current folder name is a **placeholder**. The owner is leaning toward "Kelvin" but
has not committed, and another product in this category uses the name. See `docs/DECISIONS.md` for the full naming analysis.

The rename deadline is **before the first external user**, not before the first commit —
because the expensive part is the bundle identifier and the sidecar file extension, not
the repo name.

Keep the rename cheap: one display-name constant, one bundle ID, one file extension
constant. Do not scatter the name.

## Repository status

Private until there is something working. Do not add public-facing README badges,
CI status shields, or a license file yet — the license choice interacts with decisions
recorded in `docs/DECISIONS.md` and is deliberately deferred.

---

## What to do when stuck

Ask. Do not guess at the following, ever:

- Which perception categories to add or remove (this is product design, not code)
- Whether an edit "looks good" (use the eval harness, not judgment)
- License choice
- Anything that changes the recipe schema after data exists

Read `docs/ARCHITECTURE.md` for the pipeline, `docs/RECIPE-SCHEMA.md` for the data
model, `docs/LANDSCAPE.md` for what already exists and why we are not copying it.
