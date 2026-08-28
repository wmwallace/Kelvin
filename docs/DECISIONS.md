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

> **Amended 9 August 2026.** The third bullet's justification is dead — D18 dropped preference
> learning. Diffability itself is untouched and still load-bearing; what it now buys is candidate
> comparison and `ablate`, which ranks a recipe's levers by the damage each does. The bullet is
> left as written because this file is a record of what was believed and when, not a description
> of the current build. Read the fourth bullet's "sidecars" the same way: edits now live in
> Kelvin's Application Support folder keyed to the photograph, and no `.kelvin` file is written
> beside anyone's originals — see `CLAUDE.md` non-negotiable #3.

## D5 — Novelty budget goes to the recipe IR and preference loop · Decided

Everything else uses the most proven approach available.

Novel architecture plus novel product is two unsolved problems running simultaneously.
When output looks wrong you need to know whether it was the model, the mapping, or the
renderer — and that is only possible if two of the three are boring and well-tested.

> **Amended 9 August 2026.** Read the heading as "the recipe IR and the **candidate-and-choice**
> loop", which is where `CLAUDE.md` non-negotiable #5 now stands. The decision itself is unchanged
> and has aged well: the novelty budget still goes to those two things, and D19 is that principle
> paying out — the engine got *less* clever about perception, not more.

## D6 — Evaluation harness precedes model work · Decided

No perception or engine work begins until there is a way to answer "is recipe A better
than recipe B" without human judgment.

Without it, tuning happens by vibes, indefinitely. See `EVALUATION.md`.

## D7 — Repository private until the recipes are good · **Superseded**

The differentiator is recipe quality. Until that works, there is no story, and launching
a half-working editor into a space where RapidRAW has 8.6k stars means launching from
behind.

> **Superseded 26 July 2026 — the repository is public.** The gate this entry set was a
> measurable one: an eval harness that can answer "is recipe A better than recipe B"
> without human judgment. That harness exists, runs in CI, and the corrective path
> validated against real photographs, so staying private had stopped buying anything.

## D8 — Licence choice · **Superseded**

Left open at the time. Settled on 25 July 2026 as AGPL-3.0-only plus a contributor licence
agreement — the full reasoning is in the second D8 entry, near the end of this file.

The one line here worth keeping: the choice is effectively one-way once contributors exist. That
is why a CLA came with it.

## D9 — Naming · ~~Deferred~~ **RESOLVED 25 July 2026 — Kelvin, with the collision risk accepted**

> **This entry is history and one of its claims was WRONG.** "Kalo" is recorded below as
> "clear as far as checked"; it is not — plain `Kalo` is already an App Store app name, and
> Apple's names are unique store-wide. The naming collision below is also understated. The owner
> read the fuller research and chose to keep Kelvin anyway. See D11 for the domain that followed,
> and `Branding.swift` for the rename insurance that decision made necessary.

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
where the entire point is parametric, reversible, separately-stored adjustment.

---

## Open questions for the owner

1. ~~Confirm or reject D3 (Swift vs Rust). Blocks everything.~~ **Resolved 2026-07-23 — Swift.**
2. ~~Which reference corpus for D6? MIT-Adobe FiveK is the obvious candidate — thousands
   of RAW files each retouched by five different experts, which is structurally
   identical to the candidate-previews feature. Confirm licensing suits the intended use.~~
   **Resolved 2026-07 — rejected.** The licensing was confirmed and the answer was no:
   FiveK and PPR10K are non-commercial-research only, and the restriction extends to
   derived data. The corpus is built from owned photographs instead — see the
   degradation corpus in `EVALUATION.md` and the stance recorded in `CONTRIBUTING.md`.
3. Target user for v1: working photographer with a shoot to process, or casual user with
   one photo? The answer changes the first UI substantially.
4. ~~Naming (D9) and license (D8), before external release.~~ **Both resolved 25 July 2026** — Kelvin (risk accepted), AGPL-3.0-only + CLA.

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
| Newer perception VLM | **Qwen3.5-4B** (mlx-community, 4-bit) | Apache-2.0 | Drop-in: same family as the then-default Qwen2.5-VL-3B, newer weights. (This row originally claimed "same licence" — WRONG: the then-default was `qwen-research`, non-commercial. D-model-3 caught it.) |

### Decisions

- **Perception model is now swappable at runtime** via `KELVIN_MODEL=<hf-repo-id>`, so a newer
  VLM can be compared against the default on real photos without a rebuild. The seam is the
  prompt and the parser, not the weights.
- **Nothing else is integrated yet, deliberately.** Two blockers, both real:
  - *Licence.* This project has a commercial-clean stance (open question 2 above, and the
    corpus paragraph in `CONTRIBUTING.md`). Several of the strongest
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

**Decided: `mlx-community/Qwen3.5-2B-MLX-4bit`, Apache-2.0.**

The default during early development was `Qwen/Qwen2.5-VL-3B-Instruct`, which is licensed
`qwen-research` — research and evaluation only, with a separate licence required to use it
commercially. It is the only model in its family carrying that licence: the 7B, the 32B and every
Qwen2-VL including the 2B are Apache-2.0. It had been chosen for size and capability before the
licences were compared, and it was replaced once they were — before any release, and without its
weights ever being committed here (nothing in this repository has ever contained model weights).

That satisfies D-model-2's requirement that everything shipped be commercially clean.

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
| **Qwen2.5-VL-3B-4bit** (then-default, since replaced) | **`qwen-research` — NON-COMMERCIAL** | **5.9–6.3 s** | the most accurate of everything tried |
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

**Decided with the owner, July 2026. Built — see "As built" at the end of this entry.**

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

### As built

One menu in the filmstrip header, beside the sort menu, labelled with the current lens. Five
positions, exactly as decided. The four decisions the build had to make on top of the above:

- **A run is a column, not an interleaved row.** Heading above its own thumbnails, a rule between
  runs. Headings inline in one long row leave nothing marking where a group ends.
- **A lone frame gets no heading under Burst or Similar.** A shoot of 437 frames produces a few
  hundred runs of one, and labelling each of them buries the runs that are actually a burst. Day and
  Place always carry a heading: a day with one frame in it is still that day.
- **Place is headed with coordinates** ("50.4°N, 4.1°W"), not a place name. Reverse geocoding is a
  network call and this app makes none. One decimal is ~11 km — enough to tell two venues apart
  without pretending to precision the heading is not for. *(Overtaken by D14, 28 July 2026: the
  owner reversed the no-lookup stance, so Place now carries a name when the switch is on. The
  coordinate heading survives as the fallback when it is off or the lookup has not answered.)*
- **Similar holds unmeasured frames back** in a trailing "Not measured yet" run rather than
  scattering them as singletons, because "no fingerprint yet" is not the claim "this frame is
  unique". Choosing the lens starts the triage scan that produces the fingerprints, since asking for
  the lens is asking for the measurement.

Place also falls back to "None" if the EXIF read lands and the folder turns out to have no positions
at all — the lens was chosen for a different folder, and leaving it on would partition the shoot into
one run called "No location", which reads as a broken control rather than as files without GPS.

**Found while building it:** `AppState.triage` was declared, `@Published`, and never written to. The
folder scan called a focus-only helper, so every verdict Core had been taught to produce — the
concerns *and* the near-duplicate fingerprints — was discarded before it reached the window, and
nothing read the dictionary either. The Similar lens had nothing to group on. The scan now stores the
verdict and publishes the focus reading out of it, which is what "triage rides the focus scan" was
supposed to mean.

---

## D-export-1 — What travels out inside an exported file

**Decided with the owner, 25 July 2026. Built.**

Exports re-embedded the source photograph's **GPS fix and the camera body's serial number**, and so
did every frame of a batch. Not by design — `CIImage(contentsOf:)` fills `properties` from the file,
that dictionary survives the whole filter chain, and `writeJPEGRepresentation` encodes it again. The
PNG path does the same through an `eXIf` chunk. Nothing in the UI mentioned it.

This contradicted the app's own reasoning elsewhere: it refuses to draw an inline map because
"MapKit renders by fetching tiles from Apple… a location is the most sensitive single field in the
file". An export that silently republished that field made the refusal decorative.

**Decided: a toggle in the export panel, defaulting to OFF — metadata travels unless you say
otherwise.** That is what every other editor does, and a photographer exporting for a client usually
wants the camera, lens, date and exposure to survive. What was missing was any way to say no, not the
default itself. The toggle is persisted, because stripping location is a property of how someone
works rather than of one file.

`ImageWriter.MetadataPolicy` is the seam, and `.withoutLocation` removes the GPS dictionary plus
`BodySerialNumber`, `CameraOwnerName` and `LensSerialNumber` — the fields that identify a *body* and
an *owner* rather than describe a photograph. Make and Model stay: "shot on an A7" is a photographic
fact, and a serial that appears in every frame you have ever exported is a tracking key.

Done on `properties` rather than by rewriting the written file, so the encode still happens exactly
once — a metadata edit must not cost a second generation of JPEG loss. `ExportMetadataTests` reads
every assertion back off the file through ImageIO, including that the default still carries GPS: a
privacy claim nobody measured is not a claim, and pinning the default means changing it later is a
deliberate act with a failing test attached.

---

## D-model-4 — Ship the weights in the bundle, do not fetch them

**Decided with the owner, 25 July 2026. Loading path built; bundle assembly still to do.**

The perception layer downloaded ~**1.6 GB** (measured, not the ~2–3 GB the code comments claimed)
from huggingface.co on first use: unannounced, and failing *silently* to "Model unavailable —
conservative read" when the network was not there. So a photographer on a plane got quietly worse
edits, from an app whose first promise is "no cloud, no account, no upload".

**Decided: bundle the weights inside the app and update them with the app.** This removes the request
rather than making it politer, and it makes the promise literally true instead of nearly true.

- **Licence.** Apache-2.0 §4 permits redistribution in object form, commercially, inside a closed
  application — provided the licence text travels with the weights, notices are retained, and
  modification (here: 4-bit quantisation, already stated by mlx-community) is declared.
- **Updates: Sparkle with binary deltas.** The weights do not change between most releases, so a
  delta ships the code only — a few MB against 1.7 GB. A full download happens when the model itself
  changes, which is when it is honest to pay for one.
- **Loading.** `ModelConfiguration(directory:)` resolves straight to a path; `loadModelContainer`
  only reaches for a `Downloader` in the `.id` case, so a bundled model means *zero* network calls,
  not cached ones. Order is: `KELVIN_MODEL_PATH` (a local directory, for testing), then the bundled
  directory, then a repo id — so `KELVIN_MODEL` still downloads for an A/B, which is what it is for.
- **Not in git.** 1.6 GB does not belong in every clone. `scripts/stage-model.sh` assembles
  `Vendor/PerceptionModel` (gitignored) from the Hugging Face cache at package time.

### Licence verified against the source, 25 July 2026

The gap is closed. What was checked, so nobody has to take the card's word for it again:

- `mlx-community/Qwen3.5-2B-MLX-4bit` **ships no `LICENSE` file** — the fetch 404s. Its card
  frontmatter and the HF API both declare `license: apache-2.0`, with `base_model: Qwen/Qwen3.5-2B`.
- `Qwen/Qwen3.5-2B` (upstream) **does** publish a `LICENSE`: 11,544 bytes of the genuine "Apache
  License, Version 2.0, January 2004" text, with **zero** occurrences of non-commercial, research-only
  or comparable restriction. That file is now staged beside the weights.
- **No upstream `NOTICE`** exists (probed; not published), so Apache §4(d) has nothing to require.
- The model card is staged too, as the record of the modification Apache §4(b) asks to be stated —
  it documents the 4-bit `mlx_vlm convert` quantisation.

For contrast, and as the reason this is written down: `Qwen/Qwen2.5-VL-3B-Instruct`, the previous
default, declares `license_name: qwen-research` and its `LICENSE` opens "Qwen RESEARCH LICENSE
AGREEMENT". Those weights have been **deleted from the local cache** (2.9 GB) rather than left
sitting where a `KELVIN_MODEL=` experiment could reach for them.

Verified end to end: with `HF_HOME` pointed at an empty directory and `HF_HUB_OFFLINE=1`, a full
`kelvin-perceive` run completed in 26 s against the staged directory — so the bundled path genuinely
loads from disk and cannot be silently falling back to a cache or a download.

---

## D8 — Licence: AGPL-3.0 plus a contributor agreement · **Decided 25 July 2026**

Supersedes the deferral above. The owner's requirement, in their words: *"I don't want a closed
product on my work unless I decided to do so myself in the future."* That sentence has two halves and
they need two different mechanisms.

**AGPL-3.0 handles the first half.** Nobody can take this work, close it, and ship it. AGPL rather
than GPL because the loophole GPL leaves open is exactly the shape of this project's value: a
competitor cannot ship a closed *app*, but under GPL they could take the recipe engine and the
perception pipeline, run them server-side as an "AI photo editing API", and release nothing. AGPL §13
closes that. It is also the licence RapidRAW chose, for the reason D1 already records approvingly —
to prevent absorption into closed software.

**A contributor licence agreement handles the second half**, and this is the part that is easy to get
wrong. Copyleft does not preserve the owner's own option; sole copyright ownership does. The moment a
third-party contribution is merged, relicensing requires that contributor's permission, and after a
dozen PRs the commercial option is gone in practice whether or not anyone intended it. `CLA.md`
therefore takes a licence grant plus an explicit right to relicense, rather than a copyright
assignment: same outcome, reads far less aggressively, and assignment demonstrably deters contributors
on principle.

**Verified before choosing:** every dependency in the graph is MIT or Apache-2.0 — mlx-swift,
mlx-swift-lm, yyjson and EventSource are MIT; the swift-* and huggingface packages are Apache-2.0.
Both are one-way compatible *into* GPLv3/AGPLv3. Note that Apache-2.0 is **incompatible with GPLv2**,
so v3 was the only copyleft available; picking v2 would have been a licence conflict with the
perception backend.

**Two consequences recorded so they are not rediscovered later:**

- **The direction of travel is one-way.** The rights holder can always loosen a licence. Nothing can
  tighten one retroactively — anything published under permissive terms stays available under them
  forever. Starting copyleft preserves every option; starting permissive burns them irreversibly.
- **AGPL conflicts with the Mac App Store.** The FSF's position is that App Store terms are
  incompatible with the GPL family (this is why VLC was removed). App Store distribution therefore
  requires shipping under different terms, which is possible only while all rights are held — i.e. it
  depends on the CLA, not on the licence.

**Chosen identifier: `AGPL-3.0-only`**, not `-or-later`. A future FSF version cannot be read in
advance, and the point of this pairing is that the owner controls the terms.

**Not legal advice, and `CLA.md` says so at the top.** It is a working draft modelled on the Apache
ICLA with a relicensing clause added. Before any commercial edition is actually offered it needs a
solicitor's review, or a formal equivalent generated at harmonyagreements.org.

---

## D11 — Domain: `usekelvin.app` · **Decided 25 July 2026, registered**

Bought before the first binary release, deliberately: a Sparkle appcast URL is compiled into every
copy shipped and checked by every installed copy forever, so choosing it afterwards would mean
abandoning those users' ability to update.

`kelvin.app`, `kelvin.com` and `kelvin.dev` are registered to other parties, so a variant was always
the answer. Chosen over `kelvineditor.com` — cheaper, and the only TLD with a capped renewal increase
— because the cap protects against an annoyance, while the `.com` costs something every time the
project is mentioned aloud: it has to be spelled out and does not contain the product name.

`.app` is HSTS-preloaded, so a certificate failure would take the site and the update feed dark with
no HTTP fallback. A real objection for a hand-managed server; not for one served by Vercel, which
renews certificates automatically.

Ruled out despite being the exact brand match: `kelvin.photography`. It maximises confusion with the
other product using this name, which is the risk D9 accepted and not one worth amplifying.

**This domain is infrastructure now, not marketing.** Keep auto-renew on. If it lapses after a
Sparkle build ships, every installed copy loses the ability to update, and whoever registers it next
can serve their own appcast to this project's users.

---

## D-model-5 — The weights ship inside the app · **Decided 25 July 2026**

Closes the open question in D-model-4 about how alpha users get the model: they do not get it, they
already have it. One artifact, no first-run download, no third party.

The argument that decided it is reproducibility, not privacy. `ModelConfiguration(id:)` resolves
revision `main`, so a shipped build would fetch whatever that repository points at on the day someone
runs it. Every threshold in this project was calibrated against one snapshot. Weights that travel
with the binary cannot drift out from under a release.

Everything else is a bonus: no rate limits, no repository rename breaking installs, no first-run
wait, and "no cloud" becomes literally true rather than true-with-an-asterisk. Hosting costs nothing.

**Enforced, not just intended.** `scripts/package-app.sh` refuses to produce a signed build without
staged weights — otherwise forgetting `make stage-model` would ship an app that reaches for Hugging
Face on a stranger's machine. Source builds still fetch, at a pinned revision.

### Two consequences

- **GitHub caps a release asset at 2 GB.** The bundle is ~1.7 GB, so there is ~300 MB of headroom. A
  larger model would not fit and would force a split-asset design. The packaging script warns.
- **Sparkle binary deltas are now required, not optional.** With weights inside, every update is
  1.7 GB without them. Set this up before the second release.

---

## D12 — An AI upscaler: yes eventually, at export only, and not in v1

**Raised 25 July 2026 (Upscayl mentioned as the reference). Deferred — the architecture is decided,
the timing is not now.**

**Where it goes is not in question, because the existing rules already answer it.** Non-negotiable #3
says generative pixel editing "is a *separate, later* feature that operates on top of a recipe. It is
never part of the base edit path", and D10 puts generative work out of scope for v1. An upscaler is
generative — it invents detail that was never recorded — so it belongs at **export**, applied to the
finished render, and it must never enter the recipe. That is architecturally clean: the recipe stays
a small struct of numbers describing reversible adjustments, and the upscale is a post-process on the
pixels that struct produced. It also composes correctly with the export options added today, since
resize and upscale are the same stage of the pipeline pointing in opposite directions.

**What to build it from, when the time comes.** Not Upscayl itself: that is an Electron application
(AGPL-3.0), and what is wanted is the model underneath it. Real-ESRGAN is the usual answer — BSD-3
for the code, small weights (tens of MB against the perception model's 1.6 GB), and convertible to
Core ML or runnable through MLX, which is already a dependency. **The weights need the D-model-3
treatment before shipping any bytes**: read the actual licence file rather than the repo card, because
some ESRGAN variants were trained on datasets with terms of their own, and this project has already
been bitten once by a model whose licence was written down wrongly.

**Why not now, beyond the rules:**

- **It is the wrong tool for most of this app's input.** A 60 MP RAW does not need upscaling. The real
  uses are a hard crop, a scan, or an old small file — worth having, not worth delaying an alpha for.
- **It sits awkwardly beside the project's central claim.** "The model never emits numbers" is a
  promise about not inventing what cannot be verified. Inventing pixels is defensible when it is
  labelled, optional and off by default; it is corrosive when it is quiet. If it ships, the UI must
  say plainly that detail is being generated rather than recovered.
- **There is no evaluation for it.** `docs/EVALUATION.md` scores recipes against references. Nothing
  in the harness can currently say whether an upscale improved a photograph or fabricated a plausible
  lie over it, and by D6's rule the measurement comes before the feature.

**Shape when built:** an export option, off by default, offering 2× and 4×; applied after the render
and after any long-edge resize; disabled outright when the source is already large, because upscaling
a 60 MP frame is a slower way to make a worse file.

---

## D13 — Applying a look to a shoot writes one record, not four hundred edits · **Decided 28 July 2026**

**Batch apply used to be an export.** It asked for an output folder, re-perceived every frame, and
wrote N edited JPEGs. That worked, and it was the wrong shape for three reasons:

- **One click made four hundred files.** Undo became a deletion sweep, and changing your mind about
  the look became an operation on the whole folder rather than a one-line change.
- **You could not see it.** The look was applied to files on disk that the app then had no opinion
  about — the strip and the canvas still showed whatever they had shown before.
- **It carried the reference photo's sliders.** The old path propagated `manualTweaks()` — the
  offsets you had dialled on one frame — onto every other frame. That is the copying this project
  exists not to do, dressed up as adaptation.

**Now: apply sets, export writes.** Applying a look writes a single small JSON record — the style,
plus a map of the frames given something else — and nothing is rendered. Every photograph resolves
that style against its own histogram, its own scene reading and its own mask stack when it is opened
or exported. Export edited is the one thing that makes files, and it now covers frames the shoot's
look claims as well as frames edited by hand.

**A look here is a style, not a copy of anybody's sliders.** Frame 12 was shot into the sun and frame
13 was not; both are "Natural", and Natural comes out different for each of them. This is the
non-negotiable that the old path quietly violated, and it is why the record stores a style id and
nothing else.

### The precedence rule, which is the part worth remembering

1. A **hand-made edit** wins, always. It is the one thing in the app that is not a guess.
2. Otherwise the frame's **override**, if it was singled out in the strip.
3. Otherwise the **shoot's style**.
4. Otherwise the engine's own ranking, exactly as before shoot looks existed.

A shoot with no look is byte-for-byte the old behaviour, which is what makes this safe to add to
folders people have already worked in.

### Known costs, accepted

- **The folder→folder batch is gone.** There is no longer a way to process a folder without opening
  it. Opening the shoot, applying a look and exporting is the same work with a preview in the middle,
  and it is one less path that can write files into a place nobody looked at.
- **Export is slower for look-carried frames**, because the adaptation happens there instead: a
  decode, a perception pass and two Vision passes per photograph. The export button's tooltip and
  the progress line both say so rather than letting it read as a hang.
- **The record is keyed by folder path**, so moving a shoot orphans its look — the same known limit
  `EditStore` has, recorded here for the same reason.

---

## D14 — Place names: one network call, on by default · **Decided 28 July 2026**

`GeoPoint.swift` said "No reverse geocoding, ever — `CLGeocoder` is a call to Apple's servers, and
this app does not make calls." The owner reversed that deliberately.

**The reasoning, which is narrower than "we allow network now".** The promise this app makes is that
*your photographs are processed on your machine rather than uploaded to be processed*. A rounded
coordinate exchanged for a town name is not that. Nothing about the photograph is sent — not the
pixels, not the filename, not an identifier — and the thing that comes back is the name of a place.

**On by default, with an opt-out** in Settings ▸ Scene reading ▸ Network. Off means `PlaceNames`
never constructs a `CLGeocoder` at all; it is inert, not merely quiet.

### What that bought

The filmstrip's Place grouping showed degrees, which is a heading nobody reads. It now says
"Sunriver, Oregon". The same names pre-fill the export label, which is the token a photographer
actually wants in a filename — see the label added the same day.

### The guards

- **Coordinates are rounded to three decimal places (~110 m) before they are sent.** Finer than a
  place name resolves anyway, coarser than a doorstep, and it collapses a 400-frame shoot in one
  valley to a single request rather than four hundred — which is also the difference between a
  feature and a rate-limit error.
- **One lookup per place, cached to disk.** Turning the switch off offers to forget the cache,
  because keeping a list of everywhere someone has been after they said stop is the wrong kind of
  quiet.
- **Core stays clean.** The lookup lives in `PlaceNames` in the app. `KelvinCore` imports no
  CoreLocation and makes no network call, so the CLI and the evaluation harness remain provably
  offline.
- **Degrees remain the fallback, permanently.** The lookup is asynchronous and can fail; a heading
  that blanks while waiting on a network would be worse than one that reads in degrees.

### What was considered and not chosen

A **bundled offline dataset** (GeoNames-style, a few MB against a 1.6 GB model) would have given
city-level names with no network and no toggle, keeping the Privacy line literally true. It was
rejected for granularity: "Sunriver Resort" is what the place is called, and a nearest-town lookup
would say "Bend" from twenty miles away. If the network claim ever becomes contentious, this is the
fallback that already has a design.

### Consequence

`README.md` said "no upload... because there's no server to talk to" and that the "no cloud" claim
"has no asterisk on it". Both were true and are no longer. The README now lists exactly two network
calls — the update check and this — and says what each sends. **A privacy claim in a public README
is a promise; it gets edited in the same commit that makes it untrue, or not at all.**

### Two things found after the fact

**`CLGeocoder` is deprecated as of macOS 26.0**, in favour of MapKit's newer reverse-geocoding
request. It still works and nothing here changes, but the API this decision rests on has a shelf
life and the replacement is worth taking before the next release rather than after.

**The names are coarser than hoped, and that is the API's limit rather than a bug.** Probed against a
real shoot at Sunriver, Oregon, every field came back: `locality` "Bend", `subLocality` nil,
`areasOfInterest` "Deschutes National Forest", `name` a street address. **"Sunriver" is in none of
them** — its post is addressed to Bend — and full precision returns the same, so rounding is not the
cause. `locality` is the best of that set: a town is what a photographer calls a shoot, where a
national forest is the largest feature containing the point dressed up as the most specific.

The consequence is that a place name is a SUGGESTION and must stay one. It pre-fills the export
label; it never becomes a filename on its own. That the label is editable is what makes a wrong
guess cost a second.

---

## D15 — Photos stay where they are; the slowness was a cache and a blocked main thread · **Decided 29 July 2026**

Reported as "if I want to edit a photo on my NAS it's slow or non-responsive", with the open question
being whether Kelvin needs an import step, a library, or file management of some kind.

**It does not, and that was already decided.** `docs/LANDSCAPE.md` says "Lightroom / Capture One —
the incumbents. Not the competition for v1. Do not try to replace a catalogue system," and CLAUDE.md
spends the entire novelty budget on the recipe IR and the preference loop. Kelvin points at files
where they live and never writes beside them. Building an asset manager to fix read latency would be
a very expensive way to buy a disk cache.

So the NAS problem was diagnosed as what it actually is — **a caching problem and a threading bug** —
and fixed as those.

### What was actually wrong

**Blocking file I/O on the main actor.** `AppState` is `@MainActor`, and `open` did its `stat` and its
directory listing there, `loadPhoto` did the sibling listing and the EXIF read there, and
`signature(for:)` decoded a measurement proxy there — twice per photograph, once to look for a
reusable scene read and once to remember the new one. On an internal SSD all of that is free. On a
share that has gone to sleep or lost its route, a single `stat` blocks in the kernel for the mount's
timeout, and because it is the main thread the window cannot paint and there is no way to cancel.
**That is the beachball, and it happened before Kelvin had read a byte of the photograph.**

**Nothing was cached between launches.** Thumbnails and capture info were read from the originals
every time. Opening a 437-frame shoot was 437 thumbnail reads and 437 EXIF header reads, and the same
874 reads again the next morning.

**The content hash held up the picture.** `loadPhoto` read and SHA-256'd every byte of the file inside
the decode, so a 60 MP RAW was a 60 MB transfer standing in front of a proxy that needs a fraction of
it — to produce a provenance string that nothing on the way to showing a photograph reads. It is now
computed in the background; `recordCurrentPick` waits for it, because a pick recorded against a blank
id is a pick that can never be joined back to a photograph.

### The cache: `~/Library/Caches`, keyed name + size + mtime

`MediaCache` holds thumbnails, capture info and content hashes. Two decisions in it are load-bearing:

**In Caches, not Application Support.** `EditStore` and `PerceptionStore` hold work that cannot be
recomputed, or that costs fifteen seconds a frame to recompute, so they live where macOS will not
touch them. Everything in `MediaCache` rebuilds from the original in milliseconds. Deleting it is
always safe, and the system is allowed to reclaim it under disk pressure. Settings ▸ Cache says so and
offers the button.

**Keyed the way `PerceptionStore` is** — name + size + mtime, not the path — for the reason recorded
there: path keying was measured orphaning 19 of 23 stored reads after an afternoon of tidying, and
reorganising a library is a thing photographers do. It inherits that scheme's collision trade too.

**Thumbnails are PNG, not JPEG,** and that is a correctness decision rather than a size one. Nothing
measures a thumbnail today, so a lossy round trip would be invisible — which is exactly what makes it
a trap. This codebase has already had one photograph resolve to two different candidate sets because
two proxy sizes straddled a threshold; a cache that perturbs pixels is the same bug with a worse
reproduction rate. What lossless does *not* buy: ImageIO returns a JPEG thumbnail as `noneSkipFirst`
and the same image from PNG as `noneSkipLast`, so 76,623 of 76,800 bytes differ while not one pixel
does. Anything comparing two of these must normalise first.

### Measured

126-frame, 7.8 GB shoot of 60 MP Sony ARWs, **local SSD with the files already in the page cache** —
so this is the conservative floor, not the NAS case, where there is no local page cache at all:

| | cold | warm |
|---|---|---|
| EXIF header pass, 126 frames | 820 ms | 13 ms |
| Thumbnails, 26 frames | 637 ms | 7 ms |

The cache for that shoot is **0.5 MB against 7.8 GB of originals**. Budget is 512 MB, trimmed
oldest-first at launch and never on the path that reads an entry.

### Volume awareness

`StorageVolume.isNetwork` is one `statfs`, cached per volume. It does not change what Kelvin computes;
it earns the status line the right to say "on a network volume, so the first read of each frame is
slower". Identical messages for a local disk and a share meant the only available reading of a slow
open was that the app was broken.

**Known gap:** iCloud Drive and other file providers report *local*. A dataless file materialises on
first read and behaves like a very slow local disk, so treating it as a network volume would be the
more useful lie — but `volumeIsLocalKey` is not how you detect it, and guessing from
`~/Library/Mobile Documents` breaks on the next OS. Left as a gap rather than papered over.

### What was deliberately not built

**An opt-in "work on this shoot locally"** — copy the originals to a local staging folder, edit there,
export back. This is the honest version of "import": a performance affordance the user chooses, not a
library that owns their files. Held because the three fixes above may make it unnecessary, and because
it is the one part of this that touches the promise in CLAUDE.md §3 — edits are keyed to a
photograph, and staging changes where the photograph is. That mapping needs deciding before any code
gets written, and it is the owner's call, not an implementation detail.

---

## D16 — Dust detection is deleted; healing becomes a tool you point · **Decided 31 July 2026**

**Status:** done. `DustDetector` is gone, `SpotHeal` replaces it, the app has a heal tool.

### What was wrong

The owner's standing complaint was that dust detection "has never worked". It was measured, and it
had not: on `2026-04-26 Cannon Beach`, four frames shot at f/11 on one body minutes apart returned
**0, 0, 1 and 40 spots**. Sensor dust sits at a fixed position on the sensor stack, so real dust
would have produced nearly the same list four times. That spread is proof the detector was reporting
scene content — and the 40 was the `maxSpots` cap, hit on a portrait of a man on a beach.

The UI on top of it made this worse rather than visible. One switch, "Remove dust spots", patched
whatever the detector had found, all or nothing. At fit zoom a dust spot is a handful of pixels, so
the user could not check the result; and the "Circle the spots on the photo" toggle that was
supposed to let them **drew nothing at all** — `repairSpotOverlay` was written but never attached to
the view tree. So the one control that could have exposed the detector's errors was itself dead.
This is the failure `RegionGrow.minimumCoverage` already names: a control that appears to work and
does nothing.

### The decision

Delete the detection. Keep the repair.

The half of the detector that was always sound is choosing **where to clone from** — search outward
in several directions, score each candidate on how well its colour matches the ring around the spot
and how smooth it is. That survives as `SpotHeal.sourceOffset`. Finding the blemish, the part the
machine was bad at, goes back to the photographer, who could already see it.

**One deliberate change on the way across: smoothness became a cost, not a gate.** The detector
could refuse a candidate it was unsure about — one less automatic fix, no harm done. A manual click
cannot: the user pointed at something and asked for it to go. So the worst available patch still
beats no patch, and the user judges the result.

### What this does not change

`HealSpot` is untouched, and so is the render path. Heals were always **references, not pixels**
(RECIPE-SCHEMA #6) — a normalised centre, radius and source offset — so this is not a schema change
and not generative editing (D10 stands). One click still survives a re-render at export resolution
and still propagates across a shoot. That is what sensor dust needed all along; it just needed to be
driven by someone's eye.

### Measured / verified

- Removing the per-load scan takes a Laplacian-and-integral-image pass off **every** proxy render.
  It was part of what `bench-load` recorded as the second-biggest block.
- `ExifReader.fNumber` went with it: its only caller was the `dust-map` diagnostic, and
  `CaptureInfo.read` already reads the same EXIF key for everything else.
- 562 core + 221 app tests green. Verified on the window, not just in tests: a planted blemish on
  `_DSC6390` is removed in one click, the ring marks it, ⌥-click puts it back, and the heal survives
  a relaunch from disk.

### Left undone, deliberately

No re-editing of a placed spot — no moving it, resizing it, or re-picking its source. Undo and
delete only. This is a touch-up tool; if it turns out people want to nudge a patch, that is a
selection model and canvas handles, and it should be asked for rather than assumed.

## D17 — The app is not sandboxed, and says so · **Recorded 31 July 2026**

**Status:** this records a choice every shipped build has already made, discovered by an audit
rather than by an argument. There is no `.entitlements` file in the repository and `codesign` runs
without one; releases have the hardened runtime and a secure timestamp (both notarisation
prerequisites) and no App Sandbox.

### Why recording it matters

Several comments — `Branding.swift`, `CLAUDE.md`, `package-app.sh` — reason about "the sandbox
container" that macOS keys off the bundle identifier. That reasoning is right as future-proofing
(the identifier must stay frozen precisely so that *if* a container ever exists, it is not
orphaned), but a reader could take it as a claim that the app is sandboxed today. It is not, and a
project whose README leads with a privacy promise should not leave that to inference. The promise
"reads your photographs, writes only its own folders" is enforced by code discipline and tests —
`BatchDestination` refusing the source folder, stores keyed by digest under Application Support —
not by the OS.

### Why unsandboxed is the right call for now

- **Distribution is Developer ID, not the App Store**, so the sandbox is optional. Notarisation and
  the hardened runtime are the bar a direct-download Mac app must clear, and releases clear it.
- **The filmstrip's whole job is walking a photography library across launches.** Sandboxed, every
  folder a user ever opened becomes a security-scoped bookmark to mint, persist, resolve and
  re-authorise when it goes stale — a real tax on exactly the browse-a-shoot loop D15 just made
  fast, paid to defend against an app whose only network traffic is already enumerated in
  SECURITY.md.
- **MLX compiles Metal kernels at runtime.** The hardened runtime already constrains this (the
  comment in `package-app.sh` flags it); the sandbox adds a second layer of the same kind of
  restriction to debug, for a process that touches no network.
- **Sparkle under the sandbox needs its XPC installer service arrangement** — more moving parts in
  the update path, which is the one part of the app that must never break silently.

### What would reopen it

App Store distribution (which requires the sandbox outright), or any feature that starts executing
material it downloads. Neither is planned. If it reopens, the bundle identifier this project froze
in D11 is the name the container will be keyed under — which is why the comments above stay.

## D18 — Preference learning is dropped, and the dead learner with it · **Decided 2 August 2026**

**Status:** decided by the owner. `CLAUDE.md`'s build order lists preference learning as step 9,
the last unbuilt step, and calls the preference loop half of the one-sentence differentiator.
`HANDOFF.local.md` says cross-image learning was removed for corrupting results and is not wanted.
Both could not be true. They are now resolved the second way: **Kelvin does not learn from your
picks, and for the foreseeable future it will not.**

### What is deleted

`Sources/KelvinCore/Engine/PreferenceLearning.swift` in full — `PreferenceProfile`,
`PreferenceLearner.learn`, `RecipeEngine.candidates(…, profile:)` and `applyFieldBias` — with its
two test files. Nothing in the app or the CLI ever called any of it; the only callers were tests,
so this removes a documented public API that had never once run in front of a user.

Leaving it in place was the worse option, and not by a small margin. Its doc comment claimed to
close "the loop that is the whole product", which is exactly the kind of sentence a future reader
trusts. And it carried a latent defect that proves the point: the `profile:` overload called the
base generator without `subjectLuma`, `skyLuma`, `subjectOrigin` or `iso`, so anything built
through it would have been mask-blind and ISO-blind — the same class of error as the eval harness
measuring a path the app does not ship, which once hid months of drift.

### Why, on the numbers

`applyFieldBias` added a damped learned offset to thirteen global fields. That is the model
emitting numbers with extra steps: an unverifiable parameter arriving from the user instead of from
the VLM, which non-negotiable #1 exists to prevent. D13 had already deleted the one other mechanism
that carried a reference frame's slider values around.

And the style half was measured and found worthless. Fed the real pick log (12 picks, soft 7 /
natural 5) the learner yields a soft weight of 0.583 and reorders soft first; on the 77 real pairs,
always-soft against always-natural is 7.5650 / 7.5948 — a global style prior is worth nothing or a
small loss. The log itself could not have trained anything better: `perception_hash` is null on 12
of 12 rows, `subsequent_manual_edits` — which `docs/RECIPE-SCHEMA.md` calls the most valuable field
in the system — is present on 1 of 12, and the normal workflow of applying a look to a shoot and
exporting records **no rows at all**.

### What is kept, and why

`PreferenceStore` and `PreferencePick` stay. Recording which candidate was exported costs nothing,
the store's history-truncating bug was just fixed, and the record is honest. But it is now
explicitly a **log with no reader**, and the release notes say so. If a reader is ever built, the
Settings pane disclosing the log is a prerequisite of that work and not of this decision.

### What replaces it

The thing the loop was for — a photograph opening in the look that suits it — turns out not to need
learning at all. `pick-probe` (`docs/EVALUATION.md`) measured that **shadow structure predicts which
look wins**: frames with more, deeper shadow are the ones where the photographer pulled contrast
down, replicated across both corpora. That is a property of the frame, not of the user, so it
belongs in the engine where every parameter is computed from measurements — which is where this
project already keeps its decisions.

The owner's accompanying call: a photograph **may** open in something other than Natural, but only
above a margin calibrated on the harness, and only if the app says on screen that it chose. Below
that margin the ordering of the other candidates may change and the opening frame may not.

### What would reopen it

Evidence that a per-user signal beats the measured per-frame rule — which is a comparison that can
now actually be run, because `engine-ranked` and the shadow rule give it something to be compared
against. Not before.

---

## D19 — The engine stops reading the model's defect claims · **Decided 7 August 2026**

**Status:** decided, shipped in 0.8.0. `problems[]` had nineteen readers in `RecipeEngine` and
now has none. The field, the parser and the prompt are untouched, so stored reads keep decoding and
nothing in the schema changed. It survives in the scene-summary line the app shows the user, on
the same display-only terms as `notes` — but no engine decision branches on a claim any more.

This does not weaken non-negotiable #1; it is that rule applied one level further out. The rule
exists because a small model cannot estimate a magnitude. What 0.8.0 measured is that on this
corpus it cannot reliably estimate a *defect* either, and a categorical claim about clipping is
still an unverifiable number wearing a word.

### Why, on the numbers

77 real capture/edit pairs, same binary, same pixels, only the perception JSON varying:

| arm | engine-default | engine-best | frames >1 ΔE worse than doing nothing |
|---|---|---|---|
| the shipped model's real reads | 7.670 | 7.027 | **13** |
| the readers deleted — what shipped | 7.466 | 6.74 | **3** |
| doing nothing | 7.887 | — | — |

⚠️ `docs/EVALUATION.md` reports 7.502 / 6.757 for what looks like the same thing. It is not
quite: that arm **empties the field in the input JSON** and leaves the engine's branches
standing, so measured terms that were ORed with a flag still behave slightly differently. This
row is the shipped change — the readers themselves deleted. Both land in the same place and on
the same ruined-frame count; quote whichever you mean and say which it is.

The mean is the wrong instrument and reporting it alone would have hidden this: the read is a
high-variance, zero-mean perturbation (paired difference −0.143, t = −0.93, bootstrap 95% CI
[−0.443, +0.151], sign test 38 better / 39 worse). What the deletion changes is how many
photographs come out **ruined** — 13 to 3 — which no corpus mean will ever show you.

The claims and the measurements were not describing the same photographs. `crushed-shadows`:
claimed on 12 frames, measured on 1, overlap 0. `haze`: 22 / 3 / 0. `blown-highlights`: 0 / 3 / 0.
`ImageStatistics` measures every one of these properties exactly.

Checked leave-one-shoot-out, which is why this lands where the per-frame chooser did not: it
improves on both shoots independently (Wedding 7.6362 → 7.3791, Cannon Beach 7.7438 → 7.6576), so
the gain is not one event's worth of frames.

### What a better model would not fix

A **correct** read is also worth nothing here. A hand-written read of 12 frames, grounded on
measured clipping, lands on top of the constant arm (8.991 vs 8.971) rather than above it. And
replacing scene, lighting, contrast range, direction, intent, count, placement and notes with
fixed constants costs 0.05 ΔE. `subject.present` and `subject.type` are what the perception read
is actually worth — which is the part that steers masks, and the part worth spending on.

### Two consequences worth stating plainly

- The exposure leave-alone guard is now unconditional. It was `!flagged && median >= 0.30 &&
  median <= 0.60`, so an `underexposed-subject` claim — made on 42% of a real corpus — pulled
  ordinary frames back into the rule, and on 17 of 77 the net effect was to **darken** the
  picture. The deletion fixes that by accident.
- `soft-focus` clarity damping is the one capability lost. `FocusMeasure` could restore it as a
  measurement; nobody has priced the per-frame cost.

### What would reopen it, and what was already tried

Deriving these flags from statistics instead was built and measured (7.353) and is **not**
shipped: its held-out evidence was uncontrolled against base rate, the synthetic benchmark
disagreed about where the flags fire, and most of its margin came from the one flag that works by
disabling the guard above. Do not rebuild it against two shoots. A corpus spanning more events is
the prerequisite, not a better prompt.

---

## D20 — A metered face lift is capped, and the cap costs ΔE on purpose · **Decided 7 August 2026**

**Status:** owner decision, shipped in 0.8.1. When `subjectLuma` came from a metered face, the
subject-mask lift caps at 0.25 EV (`faceLiftCapEV`).

### The mechanism, which nobody intended

`LocalMasks` prefers metered **skin** for `subjectLuma` when a face is present, and `subjectMask`
then sizes the lift as half the gap from that value to the **frame median**. So the rule measures
how far a person's skin sits from the average brightness of their own photograph — and a
darker-skinned subject measures further from it *while correctly exposed*. The prescribed lift is
therefore larger for them, and the visible result is skin lightened toward a lighter norm.

Reported from real use on a frame of a person in front of Haystack Rock: skin luma 0.160, frame
median 0.41, giving subject-mask `exposure_ev` +0.56 and shadows +35. `bg-probe` measured this
photographer's own median subject lift at +0.40 EV, so the engine was lifting a face harder than
the photographer does by hand.

Metering rather than classifying was the right instinct — the engine never branches on skin tone
and still does not. But metering only avoids *naming* the tone; it does not stop a frame-relative
target from acting on it.

### Why a cap rather than a better rule

No single photograph can separate "in shadow" from "darker skin". So the engine stops trying to,
and stops short instead: where it knows least, it commits least. 0.25 EV is deliberately under the
photographer's measured median, so the cap can only ever leave a face closer to how it was
captured than to a target.

### The cost, not buried

On the 77 real pairs the cap touches 37 frames — 10 better, **27 worse** — and engine-default goes
7.43 → 7.48. That is expected and accepted: the reference is one photographer's own edits and they
lift subjects harder than the cap allows. The corpus is one photographer and two events, so it
**cannot price the thing being bought**. Ruined frames unchanged at 4, no-op fidelity 77/77.

This is the one place in the project where a measured ΔE regression was shipped deliberately. It
is here so that a future reader tuning for corpus ΔE does not quietly undo it.

### Not fixed, and named so it is not mistaken for done

The `crushed` branch still lifts toward an absolute 0.24 floor, which is the same conflation with
a harder edge. Validating any of this properly needs a face corpus spanning complexions, which
does not exist. `KELVIN_FACE_LIFT_CAP` sweeps the cap and it is in `tuningSignature`.

## D21 — Blocking work never runs on Swift's cooperative pool · **Decided 21 August 2026**

**Status:** decided, in `Integrations/KelvinPerceptionMLX/Sources/KelvinApp/Offload.swift`. Every
Core Image render, RAW decode, Vision request, export write and file-system pass the app makes goes
through a width-limited GCD lane and is *awaited*; nothing in the app blocks a cooperative thread
any more. The one known exception is the model's token loop, which mlx-swift-lm runs on an
unstructured `Task` of its own that inherits no executor preference (tried, measured: the executor
never ran a job); it is bounded to one at a time by the provider actor and `PoolWatchdog` logs a
fault if the pool ever starves again.

### Why

The installed 0.8.1 was found on the owner's Mac with no windows, sitting in the Dock for three and
a half hours, unable to quit and unable to show a window on a Dock click. The main thread was idle.
All ten cooperative-pool threads (one per core) were parked in `-[CIContext lock]` — nine candidate
renders and a foreground decode, all `Task.detached`, behind a read-ahead RAW decode that was itself
`dispatch_sync`-ing into Apple's RawCamera queue. Swift's pool does not grow; once it is full of
blocked threads no `Task {}` in the process runs again, including the ones SwiftUI needs to finish
quitting or build a new window. A `sample` during ordinary fast browsing on a dev build showed 4–7
of the 10 threads blocked inside Core Image in every one-second window — the deadlock was the
unlucky end of a state the app was in constantly.

After the change, the same 60-key arrow burst over 60 MP RAWs: **0** cooperative threads blocked in
Core Image in any sample, and the app reached the last frame. Lanes: decode 1 (Apple's RawCamera
provider queue is serial, and two RAW renders in flight through one context was the deadlock's
shape), render 2 (a context serialises its own renders; more is threads waiting), vision 1 (Vision
crashes when requests race — already documented at the candidate build), export 1, io 4 for the quick
metadata reads an open waits on, thumbnails 4 and the scan (with hashing) bounded as before — the
thumbnails and the hashing were split off after a soak run found them queueing in front of the EXIF
read `loadPhoto` awaits. The decode lane has its own `CIContext` so a decode can never hold a lock the
preview is waiting on. Stale work is declined at the lane door (`latestRequest`): a burst of arrow
presses used to queue a second of decode per frame you had already left.

### The quit path, which was three bugs

1. Pool exhausted → SwiftUI's termination never completes (above).
2. ⌘Q while the model is generating → `exit()` runs MLX's C++ static destructors under a thread
   still inside MLX → `EXC_BAD_ACCESS` in `CustomKernel::eval_gpu` under `__cxa_finalize_ranges`.
   The process died, as a crash report, on every quit that happened during a read.
3. Nothing cancelled the read-ahead or the in-flight read on quit.

`applicationShouldTerminate` now cancels everything, returns `.terminateLater`, waits up to two
seconds for a *generation* to notice (a model load is not waited for — it cannot be interrupted),
and replies; if the model is still inside MLX after that, or if the reply never comes, the process
leaves through `_exit(0)`, which skips the destructors. Measured: ⌘Q mid-load 0.4 s, mid-sweep
1.4 s, and no crash report in any of the three scenarios.

**Do not reintroduce `Task.detached { blocking call }` "just this once".** The pattern was used in
thirty places and every one of them was reasonable on its own.

## D22 — Closing the window quits, and updates ask · **Decided 21 August 2026**

**Status:** decided, shipped with D21. `applicationShouldTerminateAfterLastWindowClosed` is true.
Kelvin is one window; the owner's report "when I click to quit the app it doesn't always quit, or
it's showing that it's running even though it's not really running" described exactly the ghost
this removes — and, that day, literally the deadlock in D21. With the window gone there is nothing
to keep the process for.

Updates: checks stay automatic and become **hourly** (`SUScheduledCheckInterval` 3600, the shortest
Sparkle allows); installing now **asks** (`SUAutomaticallyUpdate` false — the standard "a new
version is available" sheet). The 27 July stance (silent install) meant nobody ever saw an update
happen, and the install waited on a quit the app could not perform. Owner's words: *it needs to
prompt for updates, so it needs to be looking for updates more often.* Both switches remain in
Settings ▸ General; RELEASING.md and the packaging script say the same thing.

## D23 — Views observe properties, not the object; the root never reads a slider · **Decided 21 August 2026**

**Status:** decided, shipped with D21 on the same branch. `AppState` and `PreviewState` are
`@Observable` (the Observation framework, macOS 14 floor — which the app already had) rather than
`ObservableObject`; every stored property that was *not* `@Published` is `@ObservationIgnored`, so
the set of things that can invalidate a view is exactly what it was. The slider sections and the
footer's temperature readout are their own views; the preview is drawn into a `Canvas`.

### Why, on the numbers

The release notes had admitted for three versions that "the edit panel can stutter while a render or
scene read is in flight". Profiled with `make trace` (an automated 200–400 step drag) plus `sample`
of the main thread, the stutter was never the render: it was SwiftUI rebuilding the **whole window**
on every tick of every slider, because `ContentView.body` — which composes the sidebar, the footer
and the filmstrip inline — read `appState.edit`, and under `ObservableObject` every `@Published`
change invalidates every observer anyway.

| step | median stall per tick | what the profile said next |
|---|---|---|
| start | 261 ms | 68% histogram render on the main thread (D21 moved it) |
| histogram off | 187 ms | 23% root body, 22% `applyButtonLabel` → `ShootLook.covers` standardising 874 URLs |
| `@Observable` | 162 ms | 11% `cachedReading` doing a disk read per filmstrip cell |
| + covers fast path, reading memo | 124 ms | root body still per tick — the sliders were inline |
| + slider sections / temperature readout as views | 116 → 60 ms | root body 11× per 200 steps; 37% `sizeThatFits` from the Image swap |
| + Canvas preview | **~57 ms, worst 0.2 s** (was 2.8 s) | Core Animation commit and the dragged slider itself |

### The rule this leaves behind

A view that reads a property that changes per tick must be *small*, and it must not be the root. When
adding a readout of live edit state, give it its own `struct`; the cost of the alternative is the
window. The drag harness prints "root body evaluations during the run" — compare it to the step
count; if they match, something inline is reading the edit.

**Tried and not kept:** a `CALayer` with the render's `CGImage` as `contents` instead of the `Canvas`
— same numbers, more code. `EquatableView` around the slider row — declined by SwiftUI for views
holding dynamic properties (the comment on `ToneSlider` already recorded this).

## D24 — The per-frame opener is built, margin-gated, and ships inert until calibrated · **Built 28 August 2026, awaiting the owner's calibration**

**This implements the ruling D18 already recorded**, not a new decision: a photograph may open in
something other than Natural, but only above a margin calibrated on the harness, and only if the
app says on screen that it chose. What was missing was the machinery and the instrument; both now
exist. What is still missing is the calibration, which needs the owner's corpus — so the rule
ships **disabled**, and every photograph opens exactly where it opened yesterday until
`KELVIN_OPENER` is set.

### Why this is the thing to have built

The harness's own numbers, all previously recorded in `docs/EVALUATION.md`: picking the right
candidate is worth **0.61 ΔE** (`engine-best` 7.027 vs `engine-default` 7.670) against 0.10 for
any roster change, and the opener was structural — `engine-default` *was* `engine-natural` on
100% of frames. `pick-probe` found exactly one measurable thing that separates Soft-wins from
Natural-wins and replicates on both corpora: shadow structure (`shadowRegion` AUC 0.714/0.657,
`shadowMass` 0.669/0.680). That is a property of the frame, not the user, so it belongs in the
engine — which is D18's "what replaces it" paragraph, built.

### The shape

- **`OpeningRule`** (Engine): may suggest one style (`KELVIN_OPENER`, e.g. `soft`) when the
  frame's source statistics clear BOTH floors — `KELVIN_OPENER_REGION` (default 0.30) and
  `KELVIN_OPENER_MASS` (default 0.06). The two-floor AND is the margin; the defaults sit above
  the measured Soft-group means (0.255 / 0.050), so an enabled-but-untuned rule commits least
  where the evidence is thinnest — the same posture as D20's cap. They are starting points for
  calibration, not calibrated values.
- **Precedence unchanged** (D13): a hand edit, a per-frame override and the shoot's look all
  outrank it. The rule refines only step 4, the engine's own ranking, and it is routed through
  `CandidateCurator.resolve` as a request — so a suggestion the curator culls for a frame falls
  back to Natural exactly as before the rule existed. It chooses among the curated set; it never
  changes the set.
- **The app says it chose.** `ShippedCandidates.Composition.openedByMeasurement` carries the
  fact; the app shows a line under the candidates ("Opened in Soft — Kelvin chose it from this
  frame's measured shadow structure") and says the same in the status line. No disclosure, no
  off-Natural open — that was the condition, and it is wired as one flag so it cannot drift.
- **Sweepable without a rebuild**, in `RecipeEngine.tuningSignature` (constant `off` while
  disabled, so floor sweeps with the rule off cannot thrash the resolved-recipe cache).
- **`kelvin-cli opener-probe`** prices any floor grid against an existing eval report without a
  re-render: resulting `engine-default` mean, fire count, helped/hurt, worst single frame. Read
  the worst frame before the mean — D19's lesson is that a zero-mean perturbation can still ruin
  photographs.

### What flipping it on requires, deliberately left to the owner

1. `opener-probe` over the paired corpus to choose candidate floors, held out per
   `docs/EVALUATION.md` "Calibrating a constant".
2. A `KELVIN_OPENER=soft … kelvin-cli eval` confirmation on both corpora — a change that improves
   one at the other's expense is a taste call, not a defect fix.
3. Honestly: a corpus spanning more than two shoots. The signal replicated across both existing
   corpora, but 63 usable frames from one photographer is the same evidence base this project has
   declined to calibrate on twice before (D19's statistics-derived flags, the halo discriminator).
4. Then defaults changed in code, with the evidence cited — not an env var left set on one
   machine.

### What would kill it

The floors failing to replicate on a third shoot, or the confirmation run showing the curator's
veto is doing all the work (fires mostly on frames where Soft was culled anyway). Either outcome
gets recorded here and the rule stays off; the machinery costs nothing while disabled.

## D25 — Soft-focus clarity damping returns as a measurement, switched off until priced · **Built 28 August 2026**

D19 named this the one capability genuinely lost when the model's `problems[]` readers were
deleted, and said `FocusMeasure` could restore it at a per-frame cost nobody had priced. It is
restored exactly that way: `localContrast` damps clarity by the old 0.6 when a
`FocusMeasure.Reading` says the frame is soft — texture and every other lever untouched, and an
*unmeasurable* frame is not damped, because unmeasurable is not blurred (`FocusMeasure`'s own
rule, honoured rather than re-derived).

**`KELVIN_CLARITY_FOCUS=1` turns it on; the default is off**, because the cost question D19 left
open is still open — the reading renders the proxy to a 384-grid and walks it, and that price
belongs to a measurement on the owner's machine (`kelvin-perceive bench-load` already times
`FocusMeasure.read` on the proxy, so the instrument exists). The switch is in `tuningSignature`.

The one rule the wiring enforces, because it is the one that can rot silently: **every path that
generates candidates measures the reading the same way** — `FocusMeasure.engineReading(for:)`, on
the same proxy the frame's statistics were computed on. All eight production call sites (compose,
the app's open and export paths, the CLI's, kelvin-perceive's) go through it, so the canvas, the
export and the harness cannot disagree about whether a frame was damped. A ninth call site that
passes nil while the switch is on would reintroduce exactly the canvas/export divergence
`ShippedCandidates` exists to prevent; go through the helper.

Flipping the default on needs: the bench price, and a corpus check that the damping helps —
which needs soft frames in a corpus, i.e. a blur degradation arm, which does not exist yet.

## D26 — A levels-style range stretch for flat frames · **Proposed** (schema change — needs owner sign-off)

**The gap this closes is already measured and recorded** (D-tone-1, "a real gap, recorded not
tuned away"): with the tone controls behaving truthfully, the engine is measurably *worse than
doing nothing* at recovering a genuinely flat frame — 11.8 ΔE vs 8.9 on the synthetic benchmark,
12.3 vs 9.6 on a real photograph — and `EngineBenchmarkTests` asserts that floor with the gap
cited. The cause is structural, not a constant: `whites`/`blacks` bend the QUARTER tones of a
curve pinned at 0 and 1, so nothing in the recipe can map a compressed 0.235…0.764 range back out
to 0…1. A flat frame gets its midtones redistributed instead of its range restored.

This is a schema change, which CLAUDE.md says never happens without a conversation. This entry is
that conversation's written half.

### Proposal: a new optional field, not a reinterpretation

Two optional numbers on `GlobalAdjustments` — working names `rangeLow` / `rangeHigh`, normalised
input black/white points, absent meaning 0 and 1 — rendered as a linear remap
`(x − low) / (high − low)`, clamped, in the display-referred tone stage **before** contrast, so
the contrast pivot sees the restored range rather than the compressed one.

- **Absent = no-op, by construction.** Old recipes decode unchanged and render byte-identically;
  the all-neutral no-op invariant gains one more case in `NeutralNoOpTests` rather than an
  exception. No stored edit changes meaning, which is what rules out the alternative below.
- **The renderer is trivial and testable** — an affine per-channel remap (`CIColorPolynomial`
  suffices), unlike the `CIToneCurve` endpoint attempt D-tone-1 records: moving the luma curve's
  outer control points made the gap far *worse* (29.9 ΔE) because the spline does not behave as a
  levels stretch, and it was reverted. That dead end is why this needs a first-class field.
- **The engine fires it from measurement only**: when `dynamicRange` is below a flat threshold,
  stretch toward the measured `blackPoint`/`whitePoint` with a recovery fraction and caps, all
  env-sweepable and in `tuningSignature`. It must damp `pointPlacement` the way `curveDamping`
  stops the S-curve double-counting the endpoints — two mechanisms both restoring range is how a
  flat frame becomes a crunched one.

### Rejected alternative: reinterpreting the existing endpoints

No new field, `whites`/`blacks` become a true range stretch. Rejected because it silently
re-renders every stored edit — the same recipes produce different pixels under the new engine,
which breaks the promise that a recipe on disk is a description of a look. A schema *addition*
with a neutral default is the version of this change that leaves existing work alone.

### What decides it worked

The benchmark's flat case dropping below the naive-auto floor it currently cites (the assertion
flips from documenting the gap to pinning the fix), no regression on the paired corpus (a stretch
helps against untouched originals by construction, so the degradation corpus alone cannot
validate it — D-tone-1's own lesson), and `ablate` showing the new lever earning rather than
costing on real pairs. Not proposed: touching clarity/texture/vibrance spaces, which D-tone-1
already scoped out at ~5 ΔE of measured cost.
