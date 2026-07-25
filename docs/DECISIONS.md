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

## D3 — Swift + Core Image + Metal + MLX · Decided

**Confirmed by owner 2026-07-23** (was Proposed). Cross-platform Rust path explicitly
declined in favour of native Mac polish. This unblocks milestone 1.

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

1. ~~Confirm or reject D3 (Swift vs Rust). Blocks everything.~~ **Resolved 2026-07-23 — Swift.**
2. Which reference corpus for D6? MIT-Adobe FiveK is the obvious candidate — thousands
   of RAW files each retouched by five different experts, which is structurally
   identical to the candidate-previews feature. Confirm licensing suits the intended use.
3. Target user for v1: working photographer with a shoot to process, or casual user with
   one photo? The answer changes the first UI substantially.
4. Naming (D9) and license (D8), before external release.

---

## D-model-2 — Which additional models are worth adding, and which are blocked on licence

**Date:** 2026-07-24 · **Status:** analysis; nothing integrated yet

Two capabilities are currently *heuristic* because no model was wired in, and both were
identified as real limits rather than guesses:

1. **Hair / clothing / body-part masks.** Vision gives a whole-person segmentation and nothing
   finer, so "select just the hair" or "just the jacket" is impossible today.
2. **"Does this look good?"** `AestheticEvaluator` measures craft floors — clipping, tonal range,
   skin plausibility, subject modelling. Those are objective and they work, but none of them is
   trained on what people actually *prefer*. It can tell you a frame is defective; it cannot tell
   you a frame is beautiful.

### Candidates surveyed

| Need | Model | Licence | Notes |
|---|---|---|---|
| Human parsing (18 classes incl. hair, face, top, pants, hat) | **FASHN Human Parser** (SegFormer-B4, released Jan 2026) | **verify before use** | Closest fit by far; SegFormer-B4 is small enough for on-device. |
| Face + hair only | **face-parsing.PyTorch** | MIT | ~51 MB, much narrower scope, but licence is unambiguous. |
| Aesthetic / quality scoring | **Q-Align** (ICML 2024, Q-Future) | **verify** — built on mPLUG-Owl2, whose terms may not be Apache | State of the art on IQA + IAA; a full LMM, so heavy next to a 2.9 GB VLM already resident. |
| Aesthetic scoring, cheap | **MLP head on CLIP/SigLIP embeddings** (the LAION-Aesthetics approach) | MIT for the common heads | A few MB. Interesting because the head can be trained on *this user's* picks rather than a generic notion of beauty. |
| Newer perception VLM | **Qwen3.5-4B** (mlx-community, 4-bit) | Apache-2.0 | Drop-in: same family and licence as the current Qwen2.5-VL-3B, newer weights. |

### Decisions

- **Perception model is now swappable at runtime** via `KELVIN_MODEL=<hf-repo-id>`, so a newer
  VLM can be compared against the default on real photos without a rebuild. The seam is the
  prompt and the parser, not the weights.
- **Nothing else is integrated yet, deliberately.** Two blockers, both real:
  - *Licence.* This project has a commercial-clean stance (D-corpus). Several of the strongest
    options have terms that are unclear or inherited from a base model with restrictions. A
    weights licence must be read before integration, not after.
  - *Toolchain.* These ship as PyTorch. Getting them on-device means CoreML conversion or an MLX
    port, which needs torch + coremltools installed and hundreds of MB to GB of weights
    downloaded. That is a deliberate setup step for the owner to opt into, not something to
    install unilaterally.

### If one is added, this is the order

1. **Human parsing** — unblocks a concrete, already-requested feature (hair/clothing masks) and
   the output plugs straight into the existing mask pipeline as another supplied bitmap. Highest
   value per unit of risk.
2. **A preference head trained on the owner's own picks** — more interesting than a generic
   aesthetic model, because it serves the project's actual differentiator (the preference loop)
   rather than importing someone else's taste. Also the smallest model of the lot. Blocked on
   having enough logged picks to train against, which is a data problem, not a modelling one.
3. **A generic aesthetic model (Q-Align)** — last. Heaviest, licence least certain, and it would
   impose an averaged notion of "good" that the owner has already shown differs from his own
   (he preferred Natural where the scorer preferred the flattest option).

## D-tone-1 — Display-referred tone controls, and the flat-recovery gap

**Decision:** the tone stage (endpoints, contrast, dehaze, curves) is applied in sRGB, not in
Core Image's default scene-linear working space. Clarity, texture and vibrance stay linear.

**Why.** Every one of those controls is written in the numbers a photographer reads — "the quarter
tone", "mid grey", a contrast slider pivoting at 50%. Applied in linear light those numbers land
somewhere else: linear 0.5 is display 0.73, so the contrast pivot sat up in the highlights and the
control was, in practice, a shadow-crusher. Measured on a display ramp in the working space the
app actually used:

| display in | contrast +3 | contrast +24 |
|---|---|---|
| 0.05 | 0.00 | 0.00 |
| 0.10 | 0.02 | 0.00 |
| 0.20 | 0.17 | 0.00 |

A contrast of +3 — nominally imperceptible — wiped out everything below display 0.10. On a foggy
headland the *faithful* "Natural" render put 21% of the frame into unreadable black against 1% in
the original; ablation pinned contrast as the cause. After the fix that is 5.7%, and the heavy
looks went from 46–49% to 12–22%.

Scoped deliberately to the tone controls. Sweeping clarity/texture/vibrance in too changed their
effective strength and cost ~5 ΔE on the benchmark's flat case — they were not part of the bug.

**Consequence — a real gap, recorded not tuned away.** With the tone controls behaving truthfully,
the engine is now measurably *worse than doing nothing* at recovering a genuinely flat frame
(11.8 ΔE vs 8.9 on the synthetic benchmark; 12.3 vs 9.6 on a real photograph). It still beats
naive-auto comfortably (23.3).

The cause is structural: `whites`/`blacks` bend the QUARTER tones of a curve pinned at 0 and 1.
Nothing in the recipe can map a compressed 0.235…0.764 range back out to 0…1, so a flat frame gets
its midtones redistributed instead of its range restored. It needs a levels-style range stretch.
An attempt to express that by moving the luma curve's outer control points off 0/255 made it far
worse (29.9 ΔE) — `CIToneCurve` does not behave that way — and was reverted rather than shipped.

This was invisible before because the degradation constant that produced a "flat" test frame under
the broken renderer produced a barely-flattened one (dynamic range 0.74, where the evaluator's own
flat threshold is 0.45). The corpus now uses a degradation that is actually flat, and
`EngineBenchmarkTests` asserts the naive-auto floor for that case with this gap cited.

**Not decided here:** whether the range stretch lands as a new recipe field or a reinterpretation
of the existing endpoints. That changes the schema, so it is the owner's call (CLAUDE.md).

---

## D-model-3 — Perception model: measured alternatives, July 2026

**The early default model is licensed for research and evaluation only, and needs replacing.**

`Qwen/Qwen2.5-VL-3B-Instruct` is under `qwen-research`, whose text reads: *"You are granted a
… limited license … FOR NON-COMMERCIAL PURPOSES ONLY"*, with *"Non-Commercial" defined as *"for
research or evaluation purposes only"*, and *"If you are commercially using the Materials, you
shall request a license from us."*

It is the **only** model in its family with that licence. The 7B, the 32B, and every Qwen2-VL
including the 2B are Apache 2.0. The default was picked for size and capability before anyone
checked, and D-model-2's commercially-clean requirement is therefore not yet met. Nothing about this is urgent for a private repo and all of it is blocking before a
first external user — the same deadline as the rename.

**RESOLVED — the default is now `mlx-community/Qwen3.5-2B-MLX-4bit` (Apache 2.0).**

The prompt work succeeded, so the 7B's ~1.8x cost was not needed. Qwen3.5-2B initially answered
"golden-hour" on an overcast frame; the cause was a prompt bug rather than the model — nothing
stopped it inferring the LIGHT from the COLOUR of the image, and `wbStrength` halves for
golden/blue hour, so a warm cast was suppressing the correction for warm casts. With the rule
fenced to `lighting.condition` it reads correctly (see the commit "Stop the model reading a colour
cast as golden hour" for the three placements tried and why two failed).

Result: **4.5–4.7 s against the old default's 5.2–5.7 s**, correct reads on every frame tried, and
Apache 2.0. The licence-clean option turned out to be the faster one, which is not how these
usually go.

Sample size is three photographs. Worth a broader run against the eval corpus before treating the
quality comparison as settled; the *licence* conclusion does not depend on sample size.

Perception costs **~6 s per photo** and is now the dominant cost of opening one — the rest of the
load path is about 1.3 s. So the model is the biggest remaining performance lever, which is why
this was worth measuring rather than assuming. Every figure below was taken on the owner's machine
against real photographs, with weights cached, via `KELVIN_MODEL=<repo-id>`.

| model | licence | inference | result |
|---|---|---|---|
| **Qwen2.5-VL-3B-4bit** (current) | **`qwen-research` — NON-COMMERCIAL** | **5.9–6.3 s** | the most accurate of everything tried |
| Qwen2.5-VL-7B-4bit | **Apache 2.0** | 10.4–11.2 s | works; better scene read, weaker lighting read |
| Qwen3.5-2B-4bit | **Apache 2.0** | **4.5 s** | "golden-hour" on an overcast frame; "blue-hour / landscape" elsewhere, with an invented note about fisheye distortion |
| Qwen3.5-4B-4bit | **Apache 2.0** | — | prose, no JSON at all — though its *reasoning* was right ("fits best under 'other'", matching the incumbent) |
| Qwen2-VL-2B-4bit | **Apache 2.0** | — | no parseable JSON on either frame |
| SmolVLM2-500M | Apache 2.0 | 2.5 s | "golden-hour" on an overcast frame; on another, *all twelve* problems at once |
| SmolVLM2-2.2B | Apache 2.0 | slower than current | emitted malformed JSON (`subject` as a string) — hard parse failure |
| Gemma 3 4B | Gemma Terms (commercial permitted, custom) | 11.0 s | good — arguably a better scene read ("portrait" where Qwen said "other") |
| Gemma 4 | **Apache 2.0** | — | **will not load**: `config.json` has no `vision_config` the Swift VLM decoder can use |
| Apple FastVLM, Ferret | Apple research licence | — | **commercially prohibited** — "non-commercial scientific research and academic purposes" only |
| Apple `FoundationModels` | free, built into macOS | — | **text-only** to third-party apps; cannot read an image |

**There is no free-to-use Apple vision model for this.** Apple's open VLMs are research-licensed,
and the system on-device model exposed to apps does not take image input.

**Smaller did not mean faster-and-fine.** The architecture's whole premise (non-negotiable #1) is
that the model only emits categories, so a small model *should* suffice — and it may yet, with a
tighter prompt. But the categories are the input to every number the engine computes, so a wrong
one does not degrade the edit gracefully, it produces a confidently wrong recipe. SmolVLM2-500M is
2.4× faster and its output is unusable; that is not a trade worth making. Both SmolVLM tests used
the Qwen-tuned prompt, which is a real confound — a constrained or few-shot prompt deserves a try
before the family is written off.

**Gemma 4 is the one to watch.** Apache 2.0 with no custom terms, multimodal across 1B/4B/12B/27B.
The blocker is tooling, not licence, and tooling moves.

**The uncomfortable shape of this result:** the most accurate model tested is the one we may not
ship. Every Apache-2.0 alternative is either slower (7B, Gemma 3), or faster but measurably worse at
the categorical read that the entire engine is driven by (Qwen3.5-2B), or cannot produce parseable
JSON at all (Qwen3.5-4B, Qwen2-VL-2B, SmolVLM2-2.2B).

Two of those failures are *format*, not perception — Qwen3.5-4B reasoned correctly and then wrote
prose. Qwen3.5 is a reasoning-mode family and the prompt was written for Qwen2.5. So the cheapest
path to a legal AND faster perception layer is prompt work on Qwen3.5-2B, not a bigger model. That
is worth trying before accepting the 1.8x cost of the 7B.

**Verification note:** on IMG_5411 (EXIF: 10:22 AM, overcast) the incumbent 3B answered "overcast"
while the 7B, Qwen3.5-2B and SmolVLM all answered "golden-hour" or "blue-hour". 10:22 is not golden
hour, so the incumbent is right and the agreement among the others is not evidence against it. A
wrong `condition` is not cosmetic: `wbStrength` halves for golden/blue hour, so it directly changes
the white balance the engine applies.

**Also found:** `kelvin-perceive` printed "Loading Qwen2.5-VL-3B-Instruct-4bit" regardless of
`KELVIN_MODEL`, so throughout an A/B it named the model that was not running. Fixed — but it means
any earlier comparison recorded elsewhere should be distrusted.

---

## D-browse-1 — One "Group by" control, not two grouping menus

**Decided with the owner, July 2026. Not yet built.**

Two independent passes now produce groupings of a shoot, and they are complementary rather than
competing:

- `PhotoOrder.grouped(_:by:index:)` partitions by **when and where** — day, burst (3 s gap), place
  (250 m anchor clustering), all from one EXIF header read.
- `PhotoTriage.groups(_:)` partitions by **what the picture looks like** — a 64-bit difference hash
  plus a time signal, for near-duplicates.

**Surfacing both as separate menus would be worse than either.** "How is the strip organised" is one
question, and a photographer who has picked "by day" and then meets a second, orthogonal grouping
control has to hold two partitions in their head at once to predict what they will see.

So: **one control, one axis** — None / Burst / Day / Place / Similar. Near-duplicate grouping takes
its place as a peer of the metadata groupings rather than as a second dimension.

Rejected: day-or-place as an outer partition with similarity nested inside. It is strictly more
expressive and it is a worse control, because the nesting is invisible until you have already chosen
both halves, and the common case — "show me the near-duplicates so I can pick one" — does not want
an outer partition at all.

Constraints for whoever builds it:
- Groups and their members arrive in final order from Core. Do not re-sort them.
- The Place lens must be hidden or disabled when `CaptureIndex.hasAnyLocation` is false, which is
  most folders.
- Residue groups (`isResidue`) are always last and need their own heading — "No date", "No location".
- Headings are the app's to format; Core does no localisation on purpose.
- Grouping assumes the shoot arrives in capture order.
