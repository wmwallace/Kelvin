# Decisions

Append-only. If you disagree with one, raise it — do not silently reverse it.

Status values: **Decided** · **Proposed** (needs owner sign-off) · **Deferred** ·
**Rejected**

---

## D1 — Start fresh rather than fork · Decided

Considered forking or merging RapidRAW, darktable, and RawTherapee.

Rejected because:

- **Licensing.** RapidRAW is AGPL-3.0, chosen specifically to prevent absorption into
  closed-source software. darktable and RawTherapee are GPL-3.0. Combining is legally
  possible but the result is copyleft permanently, and AGPL's network clause reaches
  hosted use. That forecloses every future option.
- **There is no merge to perform.** RapidRAW is Rust + Tauri + WGSL, darktable is C,
  RawTherapee is C++. The value in those projects is in architectural coupling, not in
  extractable modules.

What *is* reusable is libraries and algorithms, not application code: RAW decoders,
lens-correction databases, model checkpoints. Those are already designed as
dependencies.

Read those codebases. Do not fork them.

## D2 — Perception and parameterization are separate stages · Decided

The VLM emits categorical judgments; deterministic code computes numbers.

A 4B-class model asked for a specific exposure value will produce a confident,
unfalsifiable number. Splitting the stages makes the numeric half unit-testable and the
categorical half the only thing that needs a model at all.

This is the central architectural claim of the project. See `RECIPE-SCHEMA.md`.

## D3 — Swift + Core Image + Metal + MLX · Proposed

**Needs owner confirmation before the first real commit.**

Core Image's RAW support supplies Apple's decoder and per-camera color profiles at zero
cost — the largest single saving available. MLX Swift keeps Python out of the bundle.

Accepted cost: Metal shaders do not port. Mac-only unless rewritten.

Alternative considered: Rust + wgpu + Tauri, which is the path RapidRAW proved works and
which is cross-platform. Rejected for v1 because it re-treads solved ground and costs
native polish, which is the thing this app is competing on.

## D4 — Recipes, not pixels · Decided

The unit of work is a small numeric struct, not an image buffer.

Consequences that fall out of this and are load-bearing:

- Candidate previews cost four shader passes, not four renders
- Edits are non-destructive by construction
- Recipes are diffable, so preference learning is possible at all
- Sidecars are small enough to version-control

## D5 — Novelty budget goes to the recipe IR and preference loop · Decided

Everything else uses the most proven approach available.

Novel architecture plus novel product is two unsolved problems running simultaneously.
When output looks wrong you need to know whether it was the model, the mapping, or the
renderer — and that is only possible if two of the three are boring and well-tested.

## D6 — Evaluation harness precedes model work · Decided

No perception or engine work begins until there is a way to answer "is recipe A better
than recipe B" without human judgment.

Without it, tuning happens by vibes, indefinitely. See `EVALUATION.md`.

## D7 — Repository private until the recipes are good · Decided

The differentiator is recipe quality. Until that works, there is no story, and launching
a half-working editor into a space where RapidRAW has 8.6k stars means launching from
behind.

## D8 — License choice · Deferred

Deliberately open. Interacts with D1 and with whether a hosted or paid tier is ever
wanted. Do not add a LICENSE file until the owner decides.

Note that the decision is effectively one-way once contributors exist.

## D9 — Naming · Deferred

Current folder name is a placeholder.

Analysis so far:

- **Descriptive names are anti-household.** Kodak was coined to be meaningless on
  purpose. Gamut can never mean more than gamut.
- **"Open-" prefix rejected.** Describes the license, not the product; unownable as a
  trademark; and "Open Photo AI" already exists in this exact category.
- **Verifiably taken:** Safelight (open-source RAW editor, announced June 2026),
  Emulsion (proprietary Mac editor), Revela (Pearla Revela, announced July 2026),
  Halide, Aperture, Ansel.
- **Kelvin** — owner's current lean. Another product in this category uses the name; weighed
  and accepted. Also an SI unit, so search dominance is unachievable. Does not verb well.
- **Kalo** — from *calotype*, Greek *kalos*, "beautiful". Clear as far as checked. Verbs
  cleanly. Better origin story.

Rename deadline is **before the first external user**, not before the first commit. The
expensive parts are the bundle identifier, the sidecar file extension, and the
Application Support directory — not the repo name.

Keep the rename to a one-line change. One display-name constant, one bundle ID
constant, one file-extension constant.

## D10 — Generative editing is out of scope for v1 · Decided

Inpainting and object removal are a later layer on top of a finished recipe.

Open image-editing models that repaint pixels are the wrong tool for base retouching,
where the entire point is parametric, reversible, sidecar-stored adjustment.

---

## Open questions for the owner

1. Confirm or reject D3 (Swift vs Rust). Blocks everything.
2. Which reference corpus for D6? MIT-Adobe FiveK is the obvious candidate — thousands
   of RAW files each retouched by five different experts, which is structurally
   identical to the candidate-previews feature. Confirm licensing suits the intended use.
3. Target user for v1: working photographer with a shoot to process, or casual user with
   one photo? The answer changes the first UI substantially.
4. Naming (D9) and license (D8), before external release.
