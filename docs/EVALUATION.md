# Evaluation

**Built second, immediately after the recipe renderer, and before any model work — deliberately.**

Without a way to answer "is recipe A better than recipe B," every subsequent decision
gets made by looking at a photo and going "hmm, nicer?" That does not converge. It is
the single most skipped piece in projects like this and it is the one that decides
whether this works.

---

## What it does

```
kelvin-cli eval --corpus ./corpus --engine-version 0.1.0 --out report.json
```

For every image in the corpus: run the engine, render the recipe, score the result
against reference edits, aggregate, and print a table. Fast enough to run on every
commit.

## What the report scores — read this before trusting a number

The harness scores **the path the app ships**, and for a long time it did not. `Evaluator`
ran `RecipeEngine.recipe()` — a single-recipe path nothing in the app calls — and built the
candidate set with no mask measurements and rendered it with no mask bitmaps. Three
consequences, all silent, all now fixed in `ShippedCandidates`:

- **Every local edit rendered as nothing.** `Renderer` skips a mask it is handed no bitmap
  for, so the corpus compared the *global half* of a recipe against an expert edit of the
  whole photograph. The sky lever and the subject lift were in the recipe and not in the
  pixels being scored.
- **The recipe under test was not the recipe the app builds.** `subjectLuma`, `skyLuma` and
  `subjectOrigin` were nil, so the engine's local decisions were made without their inputs.
- **Nothing scored the candidate a photographer opens on.** This is how `natural` grew a
  look — whites +28, blacks −24, an S-curve and a per-channel grade on a frame whose own
  perception read was "gloomy" — with a green suite behind it. No number in the report was
  a function of what Natural does.

So the rows mean different things and are not interchangeable:

| row | what it is |
|---|---|
| `engine-default` | **What a photographer opens on** — `CandidateCurator`'s resolution, rendered as export renders it. Read this first. It is the only row whose quality is unconditionally somebody's experience of the app, and the only one that falls when a single style drifts. |
| `engine-best` | The best of the **curated** set. An **oracle** — it picks with the reference in hand, so it cannot fall when one style goes wrong, because another covers for it. A ceiling, never a gate. |
| `engine-<style>` | One row per `CandidateStyle`. Where a taste change to one look shows up. |
| `engine` | `RecipeEngine.recipe()`, the single-recipe path. **The app does not ship it.** Kept because `kelvin-cli engine` produces it and the flat-degradation over-correction is diagnosed on it. |

Below the table, `opened in:` tallies which look each frame resolved to, and
`culled (craft defect):` counts the styles the curator judged **unusable** — below its quality
floor. That second line separates two things a ΔE cannot: a frame the engine has **no good
answer** for, and one it answers **badly**.

⚠️ **Do not report `droppedStyles` as a verdict.** Eight styles compete for four slots, so on a
perfectly healthy photograph exactly four are unshown. The first version of this reporting
printed `curator dropped: airy ×28, cool ×28, rich ×28, warm ×28` across a 28-entry corpus,
which reads as the engine failing four ways on every frame and was entirely the cap. `culled`
is the verdict; `dropped` is arithmetic. Both are in `report.json` per frame, alongside
`defaultStyle` and `curatedStyles`.

Generation and curation happen on the **768 px perception proxy**, because that is where the
app makes those decisions — measuring at two sizes once let the canvas and the exported file
resolve a shoot's style to different candidates, a `subjectLuma` difference of 0.007 moving
an aesthetic score across the curator's 0.55 quality floor. Scoring then happens on the
**frame's own resolution** with masks re-measured there, which is what export writes to disk.

## The corpus

**Build it from your own photographs.** The academic retouching datasets — MIT-Adobe
FiveK, PPR10K — are licensed for non-commercial research only, and that restriction
extends to anything derived from them. The project deliberately does not tune against
either (`CONTRIBUTING.md` records the stance), which means the corpus has to come from
photos you own. That turns out to be a feature, not a workaround.

The trick is that a finished photograph *is* the reference. `corpus-degrade` takes a
folder of good photos and synthesises degraded versions of each — a known underexposure,
a colour cast, flatness — as the sources, keeping the original as the truth:

```
kelvin-cli corpus-degrade --in-dir ~/Pictures/keepers --out-dir ./corpus --long-edge 1600
kelvin-perceive label --in-dir ./corpus/source --out-dir ./corpus/perception
kelvin-cli eval --corpus ./corpus
```

**Pass `--long-edge`.** The evaluator renders every style on every entry at whatever size the
corpus was written at, so a corpus of 60 MP frames is not something you can run per commit —
which is the point of having it. References and sources are capped together, so the ΔE target
does not move. The middle step is not optional either: without perception labels the report
scores only the baselines and silently omits every engine row.

The engine perceives a degraded source and must recover it toward the original; the
harness scores ΔE against a known-good answer. This measures exactly what the
perception→engine path is for — diagnosing and fixing capture problems — and it is
licence-clean on any photos you own.

The manifest format is corpus-agnostic (`corpus-init` maps any parallel-folder dataset —
sources plus one folder per reference edit — into a `manifest.json`, and scoring takes
the minimum ΔE across however many references an entry has). So a photographer with
their own before/after pairs can eval against their real edits, which is the strongest
reference there is.

Curate for hard cases: mixed indoor lighting, heavy backlight, night, high-ISO, snow and
beach (exposure-meter traps), and skin tones across a range of complexions. Twenty to
fifty images, hand-picked. Corpora stay out of git — they are photographs, and
`.gitignore` already refuses them.

⚠️ **CHECK THE CORPUS ACTUALLY CONTAINS FACES — count them, do not assume.** The first real corpus
was believed to cover skin because three of its nine photographs came out of a folder called
`Studio Portraits`. Counted with Vision, **only 2 of the 9 had a face at all**, and the three
"portraits" were shoreline landscapes — the folder name was not the content. The skin half of the
engine was therefore entirely unmeasured, and what it was hiding was not subtle: on a corpus with
real faces the engine scored **9.90 against 6.85 for doing nothing**, where on the landscape corpus it
was winning. `FaceSkin.detect` gives the count in one line; run it over the references before
trusting a corpus to cover people.

## Calibrating a constant: use held-out photographs, not the corpus

Three of the engine's constants were set from assumptions about what a photograph *should* measure,
and all three were wrong against real finished work — each in a way that silently disabled the rule
it belonged to:

| constant | assumed | measured on real photographs | consequence |
|---|---|---|---|
| white-point target | 0.965 | p99.5 median **0.808**, 1 of 38 reached it | returned its +28 cap on 25 of 38 — stopped discriminating |
| white-balance deadband | 6.0 | \|cast\| median **17.2**, 20 of 20 exceeded it | the "leave it alone" branch never fired |
| `exposureTarget(.interior)` | 0.44 | median luma **0.148**, 0 of 20 reached it | lifts nearly every frame; even brightens over-bright ones |

The shape is always the same: **an absolute target where a relative judgment is needed.** A rule that
returns its extreme on the ordinary case is not measuring anything, however reasonable its constant
looks in isolation.

So the method:

1. **Calibrate on real photographs held OUT of the corpus.** `Shoots/` has plenty; take frames the
   corpus does not use, from more than one shoot, and measure what the statistic actually does on
   finished work.
2. **Choose the value on a property, not on ΔE.** For the white point the property was
   *discrimination* — four ordinary white points must give four different answers. A lower target
   scored **better** on the corpus and was rejected for exactly that reason.
3. **Use the corpus only to confirm nothing got worse.**
4. **Render before and after on real photographs.** A table has never settled a look.
5. **Make it sweepable** — an env override plus an entry in `RecipeEngine.tuningSignature`, so the
   next corpus can re-measure it without a rebuild and a sweep cannot be served the previous arm's
   cached recipes.

Choosing the best-scoring constant is how the engine gets tuned into doing nothing: see the caution
at the end of this document.

## Metrics

No single number is sufficient. Report all of these; do not collapse them.

| Metric | What it catches | Notes |
|---|---|---|
| ΔE2000 vs each reference edit | Overall color and tone distance | Report min across the references, not mean — matching *any* reference is success |
| Histogram clipping delta | Blown highlights, crushed blacks | Regressions here are always bugs |
| Skin-tone ΔE, masked | The failure users notice fastest | Weight this heavily |
| Sky-region luma, spread and divergence | A style that claims to treat a sky and doesn't | `SkyMetrics`; see "Measuring a sky" below |
| White-balance error vs reference median | Systematic color cast | |
| No-op fidelity | Neutral recipe renders identical output | Binary. Must always pass |
| Wall-clock per image | Performance regression | Fail the build on regression |

**Report min-across-references, not mean.** When an entry has several reference edits,
averaging them produces a muddy target that no human would choose and that punishes any
confident stylistic choice. The question is "did we land near *a* defensible
interpretation," not "did we hit the centroid."

## Which lever is the error

A ΔE for a whole recipe says a frame came out 9.4 from the finished photograph and says
nothing about *why*. Reason from that alone and you will blame the wrong lever — three
successive theories about one regression were all wrong before this existed, and the first
run of it settled the question in one pass.

```
kelvin-cli ablate --in <source> --reference <finished> --recipe <recipe.json>
```

It renders the recipe, re-renders it with each lever neutralised on its own, and ranks them
by the ΔE that removing each one recovers. Positive means that lever is doing damage. Run
across all 54 entries of a degradation corpus it produced the engine's error budget:

| lever | total ΔE damage | worst frame |
|---|---|---|
| **temperatureK** | **100.0** | **17.11** |
| whites | 20.3 | 2.07 |
| vibrance | 9.1 | 0.92 |
| dehaze | 7.1 | 0.92 |

⚠️ **The rows are not additive.** Each is measured against the full recipe with only that one
lever removed, so two levers that fight each other can both look harmless. Rank, do not sum.

⚠️ **Pass the mask bitmaps** (or let it measure them, which is the default). Without them the
renderer skips every local edit and the mask layer's row reads as harmless — the same trap
that made the whole corpus score the global half of a recipe for months.

## Measuring a sky

Every other metric above is global or skin-masked, and a sky is neither. That gap was not
academic: measured on real frames, Dramatic and Soft diverge by a whole-frame mean |Δluma|
of 0.093 — a comfortable pass on the candidate-divergence criterion below — while their
skies are very nearly the same picture. The harness could not see the thing being argued
about, so the only available verdict on a sky was "does it look right".

```
kelvin-cli sky-metrics --in-dir <shoot> [--limit N] [--perception <p.json>] [--dump-dir <dir>]
```

`SkyMetrics.referenceRegion` builds the region the numbers are taken over. **It is
deliberately not `SkyMask`** — the mask is usually the thing under test, and a mask
measured through itself reports a well-covered sky on exactly the frames where it fails.
The region uses colour plus a per-column walk down from the top edge: no smoothness term,
no flood fill, no fixed positional cutoff, which are the three mechanisms `SkyMask` is
suspected on. `--dump-dir` writes the region and the mask as PNGs, because an instrument
nobody can look at is the same unfalsifiable judgement it replaced.

What it reports, per frame and as a mean:

- **cover / luma / spread / ground** — how much of the frame is sky, how bright it is, its
  tonal separation (p95−p5, which is cloud structure), and the ground for contrast. A
  `ground` reading close to `luma` means the region has swallowed the horizon; those frames
  are flagged and left out of the means rather than quietly averaged in.
- **mask α / orphan / spill** — what `SkyMask` sees of that region. `α` is the multiplier
  every sky adjustment in a recipe actually passes through; `orphan` is the share of the sky
  the mask scores below 0.1; `spill` is the share of the mask lying outside the sky.
- With `--perception`, each candidate style rendered **with its mask bitmaps** (rendering
  without them compares the global half of two recipes and silently discards the local half,
  which is where a sky lever lives), plus every pair's sky-versus-frame divergence. **A pair
  whose sky/frame ratio is about 1.0 is two candidates that differ everywhere except the
  sky.**

### Sweeping the lever without a rebuild

`RecipeEngine.SkyLever` and `SkyMask` both read their constants from the environment, so a
sweep is a shell loop rather than a branch. The sky lever is the one place in the engine
whose numbers are a **taste** call, and they were set from a sweep over a single overcast
coastal shoot — so being able to re-run that sweep cheaply, including all the way back to
the pre-`b0bd667` behaviour, is the point.

| variable | shipped | before `b0bd667` |
|---|---|---|
| `KELVIN_SKY_EV` | 1.4 | 0.45 |
| `KELVIN_SKY_EV_MIN` / `KELVIN_SKY_EV_MAX` | −1.8 / 1.2 | −0.6 / 0.4 |
| `KELVIN_SKY_FEATHER` | 16 | 45 |
| `KELVIN_SKY_BITE` / `KELVIN_SKY_BITE_OPEN` | 16 / 8 | 16 / 8 |
| `KELVIN_SKY_BRIGHT` / `KELVIN_SKY_RAMP` | 0.50 / 0.20 | 0.60 / 0.30 |

The white-balance estimator and its deadband sweep too:

| variable | shipped | before |
|---|---|---|
| `KELVIN_WB_ESTIMATOR` | `neutral` (near-neutral pixels) | `mean` (whole-frame grey world) |
| `KELVIN_WB_DEADBAND` | 6.0 | 6.0 |

`ablate` ranked white balance as the engine's largest single error — 100 ΔE across 54 entries, five
times the next lever. The whole-frame mean cannot separate "the light was coloured" from "the scene is
coloured", and no deadband fixes that because the populations overlap. At a deadband of 6 the mean
leaves **23%** of finished photographs alone; the near-neutral estimate leaves **81%**. Sweeping the
deadband (3/4/5/6) does not move the one row that regresses, which is how we know the residual is a
magnitude problem and not a gating one.

The endpoint rule's white-point target sweeps the same way, and for the same reason:

| variable | shipped | before |
|---|---|---|
| `KELVIN_WHITE_TARGET` | 0.88 | 0.965 |

**Calibrated on 38 real photographs held out of the corpus**, because the old value was not a
measurement: p99.5 luma has a median of 0.808 across those frames and only one reached 0.965, so
`pointPlacement` returned its maximum +28 whites on 25 of 38 and could not tell a frame needing +5
from one needing +28. At 0.88 that drops to 8 of 38 while a typical frame still gets +15.

⚠️ **The pick was made on that discrimination property, not on corpus ΔE.** Lower targets score
*better* here — 0.85 measured best of the arms tried — which is precisely the reason not to choose on
ΔE: see the caution below. Calibrate a constant like this on held-out photographs and use the corpus
to check it did not make anything worse.

They reach the app too, so a look can be auditioned on a real photograph and not only in a
table:

```
KELVIN_SKY_EV=0.45 KELVIN_SKY_EV_MIN=-0.6 KELVIN_SKY_EV_MAX=0.4 KELVIN_SKY_FEATHER=45 \
  make open PHOTO=<file>
```

⚠️ **Build through the Makefile before sweeping.** `make bin` and `make open` use
`--scratch-path`, which is **not** where a bare `swift build` writes. Editing a constant,
running `swift build`, then sweeping through `$(make bin)` runs the *previous* binary and
prints two identical arms — which reads exactly like "the parameter has no effect". This
already happened once. If an arm's numbers do not move, check the binary's timestamp before
believing the result; the known-good cross-check is that `KELVIN_SKY_EV=0.45` puts
Dramatic's `← mask` column at −0.040 and its sky spread at 0.112, the values recorded in
`b0bd667`.

## Baselines

Every report compares against these. If the engine cannot beat them, it is not ready.

1. **Camera JPEG** — the manufacturer's own rendering. This is the real floor. A user
   whose photos come out worse than their camera's own JPEG will uninstall immediately.
2. **Neutral recipe** — proves the pipeline is not making things worse.
3. **Naive auto** — histogram stretch plus grey-world white balance. The dumb baseline.
   If the VLM path cannot beat this, the entire architectural premise is wrong.

Baseline 3 is the honest test of whether this project has a reason to exist. Run it early
and take the answer seriously.

## Success criteria for v1

**Read them off `engine-default`.** Every criterion below is a statement about what a
photographer gets, so it is answered by the row that is what a photographer gets — not by
`engine-best`, which chooses with the reference in hand and cannot fail these on the strength
of one good style.

- Beats camera JPEG on min-ΔE for **> 80%** of the corpus
- Never clips highlights worse than the camera JPEG on **any** image
- Beats naive-auto on min-ΔE for **> 70%** of the corpus
- No-op fidelity passes at 100%
- The four generated candidates are *meaningfully different* — pairwise ΔE between
  candidates above a floor, so the picker offers a real choice rather than four
  near-identical looks

That last one is easy to lose accidentally and it kills the product concept if lost. It is
pinned by `CandidateGenerationTests.testPairwiseRenderDivergence`, on the **curated** set
rather than the raw style list — divergence is a property of what the photographer is shown.

## A caution on the target

"Great results every time" is not achievable and chasing it will stall the project.
Photo quality is subjective; there is no every-time. The workable target is:

> Never worse than the camera JPEG, and a good enough starting point often enough that
> correcting is faster than editing from scratch.

That is measurable, and it is the bar that decides whether people keep using the app.
