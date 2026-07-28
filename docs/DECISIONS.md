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
  without pretending to precision the heading is not for.
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
