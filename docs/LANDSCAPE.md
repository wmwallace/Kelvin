# Landscape

Researched July 2026. Recorded so it does not get re-derived, and so nobody proposes
rebuilding something that already exists and is better.

**Re-verify before any public launch.** This space moved twice during a single week of
research.

---

## Open source

**RapidRAW** — the closest existing project by a wide margin. Rust + Tauri + WGPU +
WGSL, under 20 MB, macOS / Windows / Linux / Android. ~8.6k stars, 2,000+ commits, daily
activity. AGPL-3.0.

Already has: RAW via rawler, GPU pipeline, layered masking with subject/sky/foreground/
depth detection, local CLIP tagging, LaMa inpainting, AI denoise, batch operations,
presets, panorama stitching, optional ComfyUI bridge for generative work.

Does **not** have: semantic reasoning about the photograph, multiple candidate
interpretations, or preference learning. Its "auto" is deterministic auto-adjust.

This is the project to read and to respect. It is also the reason not to compete on
feature count.

**Open Photo AI** (vegidio) — enhancement-focused, will analyze images and suggest
enhancements automatically, batch export. Closer to our auto-suggest idea than RapidRAW,
narrower in scope.

**darktable / RawTherapee / ART** — mature, excellent RAW pipelines. darktable is
competitive with commercial tools on image quality. Its acknowledged weakness is that it
does not hold your hand: it starts with almost no editing applied, so you must learn it
to get good results.

That gap is exactly the one this project addresses. darktable's colour science is decades of
specialist work and not worth re-treading; the contribution here is knowing what a
particular photograph needs.

**Safelight** (anthonyreimche) — open-source RAW editor built like an IDE, announced
June 2026 on pixls.us. Modular, GPL, privacy-focused, GPU pipeline. Newer and smaller
than RapidRAW but occupying adjacent territory. Note: this is why the name is taken.

---

## Commercial

**Imagen AI** — cloud. Builds a "Personal AI Profile" from your previously edited
Lightroom catalogues; roughly 3,000 images recommended. Also sells profiles modelled on
named professional photographers.

**Aftershoot** — local, offline. Culling plus editing. Learns your style from your own
past catalogues, minimum around 2,500 images recommended.

**Both share the same constraint: a cold start.** They
require you to already be a working professional with a large back catalogue of
finished edits. Everyone else gets nothing.

Four-way candidate picks generate a labelled preference pair per interaction. Twenty
picks is a usable signal, not twenty-five hundred.

**Radiant Photo** — the closest commercial analogue to our concept. Analyzes the photo's
object type and applies suitable settings, runs locally without cloud upload, allows
manual adjustment afterward, and deliberately modifies existing pixels rather than
generating new ones. Proprietary.

It has no preference-learning loop and no candidate-selection UI. Read its marketing
before writing ours — it is the closest thing to a competitor for our positioning.

**Lightroom / Capture One** — the incumbents. Not the competition for v1. Do not try to
replace a catalogue system.

---

## Research

VLM-driven retouching is an active academic area. There is a line of work using vision
language models as agents that drive retouching toolchains like Lightroom, automating
exposure, contrast and tone-curve adjustments from language instructions — though these
systems generally rely on fixed tool-invocation pipelines and do not adapt to individual
user preference.

Papers, not shipped software. Worth reading for prior art on the perception-to-parameter
mapping specifically; PerTouch and the surrounding citation graph are a reasonable entry
point.

---

## Where the gap actually is

Nothing shipping, open or closed, does all three of:

1. Semantic understanding of the individual photograph
2. Several genuinely different candidate interpretations, offered as a choice and shown
   large enough to actually make it
3. That choice carried across the shoot, each frame re-measured rather than copied

Existing tools do deterministic auto-adjust (one answer, no reasoning), or style-cloning
that needs thousands of prior edits, or generative pixel editing.

Point 3 used to read "preference learning from that choice, with a low-teens cold start".
That claim is withdrawn — D18 dropped preference learning, and the cold-start number was
never tested. Nothing else in the list moved, and points 1 and 2 are still unmatched: they
are the differentiator, and the learning was only ever one candidate mechanism on top.

That is the whole product. Protect it.
