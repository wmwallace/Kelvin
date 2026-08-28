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
the minimum ΔE across however many references an entry has).

### The second corpus: real before/after pairs

**Build this one too, and read the two together.** The degradation corpus has one structural blind
spot that no amount of care removes: its reference is the *untouched original*, so every stylistic
choice costs ΔE and doing nothing is the strongest possible baseline. Two separate findings have
now died on that — the endpoint rule's 20.7 ΔE turned out to be the look being priced by an
instrument that penalises looks, and the white-balance estimator that *won* the degradation corpus
is the one that should not ship.

`corpus-pairs` builds the complement, where the reference is what the photographer actually wanted:

```
kelvin-cli corpus-pairs --root ~/Pictures/Shoots --out-dir ./corpus-pairs --long-edge 1600
kelvin-perceive label --in-dir ./corpus-pairs/source --out-dir ./corpus-pairs/perception
kelvin-cli eval --corpus ./corpus-pairs
```

It discovers pairs by convention rather than imposing one: any image in an `edited/` folder whose
filename stem matches a capture elsewhere in the same shoot. Lightroom already exports that way.
Second cameras count — one real shoot pairs Sony ARWs and Canon CR2s.

Two things it does that matter more than they look:

- **A cropped export is dropped, not scored.** Once Lightroom has cropped, the two images no longer
  frame the same scene and a per-pixel ΔE measures the crop. This is the one defect that would
  quietly produce plausible numbers. ⚠️ **Orientation is not a crop** — a portrait export of a
  landscape-sensor frame is the same pixels rotated, and comparing width-to-height instead of
  long-to-short threw away 31 of 67 real pairs on the first attempt.
- **One entry per capture.** Exports nest: a real shoot had `Edited/` and inside it `Edited Small/`
  with downscaled copies of the same frames. Both match, and counted twice those frames get double
  weight in every mean.

⚠️ **This inverts the bias rather than removing it.** The reference now carries the photographer's
whole style, so an engine that *under*-edits is penalised exactly where the degradation corpus
rewarded it, and neither corpus is neutral. **A change that improves both is real. A change that
improves one at the other's expense is a taste call, not a defect fix** — and that distinction is
the whole reason to have two.

It also cannot tell "the engine chose differently" from "the engine chose worse". The reference is
one photographer's edit, of their own work, in their own style.

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

**Run it on BOTH corpora, because they disagree about which lever is wrong.** The same ablation over
77 real before/after pairs, where the reference is the photographer's own edit rather than the
untouched original, reports a *net* figure — the damage a lever does minus the ΔE it earns:

| lever | ΔE damage | ΔE it earns | net |
|---|---|---|---|
| **exposure_ev** | 25.1 | 14.1 | **+11.0** |
| contrast | 8.8 | 1.8 | +7.0 |
| shadows | 13.3 | 8.1 | +5.2 |
| vibrance | 4.8 | 0.9 | +3.9 |
| whites | 5.5 | 9.6 | **−4.1** |
| fusion | 0.5 | 5.5 | −5.0 |
| **masks (layer)** | 3.5 | 24.6 | **−21.1** |

Read against the degradation table above, three things change completely:

- **`whites` goes from the worst lever (20.7 damage) to a net positive.** Against an untouched
  original an endpoint push is pure cost; against a real edit it is most of what the photographer
  did too. A lever that looks like the top defect on one instrument can be one of the better ones on
  the other, and that is the clearest argument for keeping both.
- **The mask layer is the most valuable thing the engine does** (−21.1) — local edits are invisible
  to a corpus of global degradations, which never asks for one.
- **`temperatureK` does not appear at all**, because the white-balance gate fires on **0 of 77** real
  captures: Core Image applies the camera's as-shot balance during RAW decode, so a genuine cast is
  rare in real input even though it dominates the degradation corpus.

⚠️ **Read the net figures PER FRAME before treating one as a defect.** Over 77 pairs the worst lever
is 11.0 / 77 = **0.14 ΔE per frame**, where white balance on the degradation corpus was doing
**1.85**. A row can top the table and still be nearly harmless, and `exposure_ev` is exactly that
case — measured directly with `exposure-probe` it agrees with the photographer's own exposure
decision to within 0.06 EV.

```
kelvin-cli exposure-probe --in-dir <corpus>/source --reference-dir <corpus>/reference \
    [--perception-dir <corpus>/perception] [--recipe-dir <dir of per-frame recipes>]
```

It prints the photographer's decision — log2(reference median / capture median), how many stops they
actually moved the frame — beside the engine's, so a rule that has misread *intent* (moving a frame
the opposite way from its photographer) separates from one that merely needs a constant. With
`--recipe-dir` the engine column becomes where the **whole rendered recipe** lands, which is what
catches tone levers double-counting with exposure.

⚠️ **The rows are not additive.** Each is measured against the full recipe with only that one
lever removed, so two levers that fight each other can both look harmless. Rank, do not sum.

⚠️ **Pass the mask bitmaps** (or let it measure them, which is the default). Without them the
renderer skips every local edit and the mask layer's row reads as harmless — the same trap
that made the whole corpus score the global half of a recipe for months.

## What the photographer does to each region

```
kelvin-cli bg-probe --in-dir <corpus>/source --reference-dir <corpus>/reference
```

The per-region companion to `exposure-probe`, built for the background-mask taste call. Per pair it
segments the **capture** (subject, sky, and the derived background), then measures mean luma under
each mask on both the capture and the photographer's finished edit, printing each region's ΔEV and
the differential `backgroundΔEV − subjectΔEV` — how much separation the edit created, and by which
mechanism.

What it showed on the 77 real pairs (1 Aug 2026), and the reading matters more than the medians:
the photographer's separation on person frames is **−0.37 EV of differential, made almost entirely
by lifting the subject (+0.40 median) and pulling the sky (−0.19), while the background itself
stays put (+0.04 median, quartiles −0.08…+0.18)**. Background saturation is a wash (+0.01). On
salient-object frames the differential collapses to −0.06, straddling zero.

⚠️ So the probe *refuted* the obvious default it was built to evaluate: an unconditional
background darken would contradict the photographer's own edits. Separation is subject-relative,
and the levers that produce it already exist. Re-run this before wiring any background rule.

With `--perception-dir` it adds the ENGINE's columns — the default candidate (composed through
`ShippedCandidates.compose`, the path the app ships, rendered with the same masks the
photographer columns are measured under) — so the photographer's lift and the engine's are read
side by side. Measured over the 77 pairs (1 Aug 2026):

| subject ΔEV | p25 | median | p75 |
|---|---|---|---|
| photographer | +0.12 | **+0.40** | +0.58 |
| engine | +0.06 | **+0.14** | +0.33 |

The gap (photographer − engine) splits cleanly: **+0.08 EV median on person frames** — inside
the territory prior probes ruled "not a defect" — and **+0.36 EV on salient-object frames**,
where the engine is deliberately cautious because of the measured halo dead-end (no threshold
separates a good salient mask from a landscape; see the halo work). Background gap +0.01.
So the person-frame lift is calibrated; the salient shortfall is a robustness-vs-taste
tradeoff, not a constant to sweep, and the frames to eyeball are the opposite-direction cases
(photographer lifted, engine darkened: `_DSC6763`, `_DSC6835`).

⛔ **A ninth candidate style ("Separation") was prototyped and died in the harness — read this
before proposing a mask-led style again.** Built on the measured signature (a style-scoped
`subjectLiftBiasEV`), swept at 0.35/0.25/0.15/0.10 over the 77 pairs: every column improved
monotonically as the bias SHRANK (the sky pull carries the value, not the lift), the all-9 oracle
floor genuinely dropped (6.9563 → 6.7907, closest style on 20/77), **and the curated engine-best
never moved a byte** — the style was curated 0/77. Root cause is ORDER, not distance: the curated
four fill from the first styles in engine order (natural/soft/vivid/dramatic are mutually ≥12
apart on 75/77 frames), so a ninth appended style is unreachable whatever the distance function
says. The curator's mask-blindness (its distance read globals only — any mask-led candidate was
invisible) was a real latent bug and IS fixed and kept; the fix flips no current decision. The
unlock paths are all product calls: reorder the roster (displaces an incumbent on ~every frame),
five slots, or the preference loop's rank step once the style can be shown at all. Sweep JSONs in
the ninth session's scratchpad (`eval-pairs-sep-*`, `eval-pairs-cur-*`).

⛔ **The salient gap was then chased to ground, and no engine constant closes it.** Two levers
were built and swept (`KELVIN_SALIENT_LIFT`, which remains as an instrument, and a trigger-band
"slack" for animal reads, which was reverted):

- **Strength is not the lever.** The lift fires on only 2 of the 14 salient frames, and both
  are already at or past the photographer at 1.0×. Raising the scale to 4× moves the salient
  median not at all (+0.36 at every arm) and only overshoots the two firing frames.
- **The gates are not the lever either.** Fully admitting the silhouetted-birds frame
  (`_DSC6835`) moved it +0.12 EV against its +0.51 gap — the photographer brightened that
  frame's *background* +0.20 too. These are whole-frame lifts of deliberately dark captures:
  §7.3c's standing owner ruling, reached through the mask instrument.
- **What the gap actually is**, frame by frame: perception holes (`subject.present: false` on
  `_DSC6763`; type neither person nor animal on others) — a perception-category question,
  which CLAUDE.md says to ask about, not code around; the person-origin halo gate blocking
  salient-mask lifts on person-labelled frames the photographer lifted hardest
  (`_DSC6307`/`_DSC6308`, +0.80/+0.33) — re-opening that needs a discriminator sharper than
  coverage, which measurement already ruled out once; and the deliberately-dark family above.

## Which illuminant estimate is right

`ablate` says *which lever* is wrong. When the answer is white balance — it has been, twice — the
next question is which of the four estimators to read, and a corpus ΔE cannot answer it because it
mixes two opposite failures: firing on a photograph that wanted leaving alone, and under-correcting
one that genuinely is cast.

```
kelvin-cli wb-probe --in-dir <folder>                                # every estimate, side by side
kelvin-cli wb-probe --in-dir <corpus>/source --reference-dir <corpus>/reference   # + true cast
kelvin-cli wb-probe --in-dir <finished photographs> --cost           # + what firing costs
```

- With `--reference-dir` it measures the **true cast** as the mean-chroma difference between a
  degraded frame and the untouched original it came from — the one place a ground truth exists — and
  prints `recovery`, the share of it each estimator would remove. 1.00 is exact; a negative number is
  a correction pointing the wrong way, which the least-chromatic estimate does on cool casts.
- With `--cost` it renders each estimator's correction and measures how far it moved the frame. Point
  this at **finished photographs**, where the right answer is "did not move at all". A leave-alone
  *rate* is not enough on its own: an estimator that fires often and gently can beat one that fires
  rarely and hard, and only this tells them apart.

Both properties are needed to choose. See the estimator table under "Sweeping the lever" below.

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

The white-balance estimator, its Minkowski order and its deadband sweep too:

| variable | shipped | before |
|---|---|---|
| `KELVIN_WB_ESTIMATOR` | `hybrid` | `neutral`, and `mean` before that |
| `KELVIN_WB_EDGE_P` | 8 | — |
| `KELVIN_WB_DEADBAND` | 6.0 | 6.0 |

`ablate` ranked white balance as the engine's largest single error — 100 ΔE across 54 entries, five
times the next lever, and still the top item after being halved. Four estimators exist and
`KELVIN_WB_ESTIMATOR` selects between them:

| | what it reads | leaves finished work alone | ΔE it moves it by | cast recovered | corpus |
|---|---|---|---|---|---|
| `mean` | whole-frame mean chroma | 18% | 6.18 | 1.07 | 9.36 |
| `neutral` | least-chromatic 15% of pixels | **82%** | **0.68** | 0.48 | 8.81 |
| `edge` | grey-edge: mean local colour *difference* | 34% | 3.65 | **1.06** | **6.96** |
| **`hybrid`** | `neutral` gate, `edge` magnitude | **82%** | 0.86 | **1.06** | 7.56 |

**The first three columns answer different questions and that is the whole point.** "Leaves finished
work alone" and "ΔE it moves it by" are measured over **38 real photographs held out of the corpus**;
"cast recovered" is measured over the corpus's 18 genuinely cast entries as the share of the known
cast the estimate would take out (1.00 is exact).

The whole-frame mean cannot separate "the light was coloured" from "the scene is coloured" — it
counts pixels, so a blue sea votes with its area — and no deadband fixes that because the populations
overlap. The least-chromatic selection fixes the gate and then recovers **less than half** of a cast
it does catch, because in an already-shifted frame the pixels nearest neutral are preferentially the
surfaces whose own colour opposes the shift. Grey-edge averages local colour *differences* instead,
so a flat field contributes nothing however large it is, and it sizes a cast almost exactly.

⚠️ **`edge` alone wins the corpus and is the wrong pick.** Every corpus entry is a *degraded* frame,
so correcting is always right there and the corpus structurally cannot see the cost of firing on
finished work — which for `edge` is 3.65 ΔE per photograph, 59% of the damage `mean` did. `hybrid`
fires on **exactly the frames `neutral` fires on**, so it inherits that restraint by construction and
only changes how much comes out. This is the clearest example in the project of the corpus's timidity
bias pointing the wrong way; see the caution below.

`KELVIN_WB_EDGE_P` is the grey-edge Minkowski order — 1 is the plain gradient average, higher weights
strong edges more. Recovery plateaus at 1.06 from p=4 and the held-out cost falls monotonically
(1.36 → 0.95 → 0.86 → 0.74 at p=1/4/8/16), so the properties alone would say "as high as it goes";
the corpus is what vetoes it, turning over at p=16 (7.73) while the held-out cost is still improving.
8 sits inside the plateau with the turn beyond it.

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

## What predicts which look wins

```
kelvin-cli eval --corpus ./corpus-pairs --out report.json
kelvin-cli pick-probe --report report.json --corpus ./corpus-pairs
```

The preference loop rests on a question nobody had asked. Two things were already known:
choosing the right candidate is worth about six times what adding more candidates is, and
**perception cannot make that choice** — the scene categories have near-identical
distributions over frames where Soft wins and frames where Natural does. "Portrait,
overcast" does not tell you which one the photographer kept.

So the question narrows: does anything *measurable about the light* separate them? Not the
scene depicted — the frame itself, as a chooser would see it, unedited and with no
reference in hand. `pick-probe` re-reads a report the harness has already written (every
`engine-<style>` row carries a per-frame `minDeltaE`, so each frame's winner is already on
disk and nothing is re-rendered), measures the corpus *sources*, and reports the AUC of
each property between the two groups. 0.50 is a coin flip.

**The answer, as of 2 August 2026: shadow structure separates them, and nothing else does.**

| property | natural | soft | AUC (pairs) | AUC (degradations) |
|---|---|---|---|---|
| `shadowRegion` | 0.196 | 0.255 | 0.714 | 0.657 |
| `shadowMass` | 0.027 | 0.050 | 0.669 | 0.680 |
| `blackPoint` | 0.063 | 0.040 | 0.302 | 0.274 |
| `dynamicRange` | 0.808 | 0.881 | 0.707 | **0.486** |
| `edgeCast` | 2.27 | 2.02 | 0.367 | **0.763** |

The first three are one finding seen from both ends: **a frame with more, deeper shadow is
one where the photographer pulled contrast down (Soft); a frame with lifted blacks and
little shadow is one where Natural was already right.** It replicates on both corpora, in
direction and in rough magnitude, and it is mechanistically sensible, which is more than
this project has previously got out of a threshold hunt (the halo discriminator died at
62% against a coin flip).

The last two rows are the reason the hold-out exists and why the command prints the number
of properties it searched. `dynamicRange` looked like the co-winner on the paired corpus
and is dead on the other. `edgeCast` is the *strongest* property on the degradation corpus
and points the **opposite way** on real pairs — unsurprising once said out loud, because
that corpus injects colour casts by construction, so it is measuring the corpus rather than
anybody's taste. Both are exactly what noise looks like when thirteen properties are
searched at n≈60.

Read the result with its limits attached: one photographer, 63 usable frames on the paired
corpus and 45 on the degradation corpus (only 10 of them Soft wins), and the degradation
corpus is synthetic variants of the same photographs rather than an independent sample. It
is enough to say a per-frame chooser has **something** to read, which was the open
question. It is not enough to calibrate one on.

Useful flags: `--pair natural,soft` to separate a different two (the default is the two
winningest styles), and `--min-margin <ΔE>` to drop frames the two styles effectively tied
on, which are not evidence about either.

## What the perception read is worth, measured three ways

**7 August 2026, 77 real pairs, same binary, same pixels, only the perception JSON varying.**
The corpus manifest carries a per-entry `perception` path, so the same corpus can be scored
under different reads and the difference *is* the model's contribution. Run it before arguing
about the model again.

| arm | engine-default | engine-best | frames >1 ΔE worse than doing nothing |
|---|---|---|---|
| the shipped model's real reads | 7.670 | 7.027 | **13** |
| `problems[]` emptied, all else real | 7.502 | 6.757 | **3** |
| everything constant (scene `.other`, subject absent, lighting `.unknown`, no problems) | 7.527 | 6.785 | 4 |
| perception shuffled between frames | 7.822 | — | 16 |
| doing nothing | 7.887 | — | — |

**The world is `real < neutral ≈ oracle`.** A hand-written read of 12 frames — written by
opening each photograph and grounding the read on measured clipping — lands *on top of* the
constant arm (8.991 vs 8.971), not above it. So this is not "the model reads badly and a better
model would fix it": a **correct** read is worth nothing to the engine as currently wired, and the
model's actual read is worse than silence.

⚠️ **Report the tail, not the mean.** On the mean, real vs neutral is not significant — paired
difference −0.143, t = −0.93, bootstrap 95% CI [−0.443, +0.151], sign test 38 better / 39 worse.
The read is a **high-variance, zero-mean perturbation**: all 77 frames move, mean magnitude 0.788
ΔE, max 5.762. What changes is how many photographs come out *ruined* (13 → 3), which no mean
over this corpus will ever show you.

Where the harm concentrates: `problems[]`, the engine's most-read perception field. `crushed-shadows`
alone costs 0.20 ΔE — nearly the engine's entire 0.22 margin over doing nothing. It is claimed on 12
corpus frames of which **nine have exactly 0.00000 measured shadow clipping**, and its overlap with
frames that genuinely clip is at chance (expected 1.9 at n=77, observed 3). `ImageStatistics`
measures every one of these properties exactly; the engine was asking a 2B model instead.

⚠️ The constant arm is not hypothetical — it is byte-identical to `conservativeRead`
(`ContentView.swift:679-684`), a branch the app already ships when the model is unavailable.

### What the read still cannot be replaced on

`subject.present` and `subject.type`. Replacing the other eight fields — scene, lighting condition,
contrast range, direction, intent, count, placement, notes — with fixed constants costs **0.05 ΔE**.
`natural-feature` (added 1 Aug) is the counter-example that earns its keep: it admits sea-stack
frames to the corrective subject lift, and on 24 re-read Cannon Beach frames the subject mask
appeared on 11 and the result is visibly better on 6 of 8 inspected.

## A read that changes is not an edit that changes

⚠️ **Before blaming a prompt change for a quality complaint, measure whether it reached the
picture.** A prompt edit changes `PerceptionStore`'s key (`SHA256(identity-promptSignature)`) and
re-reads the whole library, which *looks* alarming: across the owner's cache, re-reads disagreed on
`problems[]` for 48% of photographs and `subject.type` for 34%.

It did not reach the picture. Rendering 24 of those frames under both their old and new reads, same
binary: pixels moved on 19, and the look a photographer **opens on changed for zero of them**. The
curated four were `[Natural, Soft, Vivid, Dramatic]` in both arms on every frame.

Two lessons, both cheap to forget:

- **`temperature = 0`** (`MLXPerceptionProvider.swift:198`), so "label drift between runs" is not an
  available explanation — the same prompt on the same pixels gives the same answer. Two differing
  reads mean the prompt changed **or the pixels did**.
- **The pixels can differ without anyone touching the photograph.** `kelvin-perceive` perceives
  `downsample(full)` in one step; the app perceives `fromFile(maxEdge: 1200)` and then downsamples
  again. Different resampling, same cache key. The harness and the app can be reading different
  images of the same file, and whichever runs first wins.

## The opener is a constant

`CandidateCurator.select` iterates in engine order; `natural` is index 0 of `CandidateStyle.all`
and is exempt from the quality floor, so it is always `curated.first`, and `resolve` returns
`match ?? curated.first`. **`engine-default` is `engine-natural`.** Every eval run prints
`opened in: natural ×77` and that is structural, not a property of the corpus.

Consequences worth stating plainly before designing anything that assumes otherwise:

- The craft floor, the aesthetic evaluator, the eight-style roster and any per-frame chooser
  cannot change what a photographer sees on opening.
- The app opens on the candidate its **own evaluator ranks second**: Soft outscores Natural on 26 of
  39 corpus frames. Slot 1 is assigned by engine order with no score check.
- Because Natural is `corrective`, seven levers are off on 100% of frames at open — the S-curve, the
  split-tone grade, clarity, texture, most of the endpoint push, most of fusion, and **the entire sky
  graduated-ND**. The sky lever calibrated by sweep at 1.4 EV reaches zero frames on open.
- Picking is worth **0.61 ΔE** (`engine-best` 7.027 vs `engine-default` 7.670) against 0.10 for
  expanding the roster. Ranked by measurement, a per-frame opener beats every roster change,
  every new style and every constant sweep on the table.

### The opener rule exists now, and ships inert

`OpeningRule` is the per-frame opener the numbers above argue for, built to D18's ruling: a
photograph may open in something other than Natural only above a margin, and only with the app
saying on screen that it chose. It reads the two properties `pick-probe` found and nothing else —
`shadowRegion` and `shadowMass`, both floors required — and it is consulted only when nothing
outranks the engine's own ranking (a hand edit, an override and the shoot's look all win, per D13).
A suggestion the curator drops for a frame falls back to Natural silently.

**It is disabled by default** (`KELVIN_OPENER` unset), because the margin has not been calibrated —
the evidence is 63 usable frames from one photographer, which this document already calls enough to
know the signal exists and not enough to calibrate on. Calibrating it is two steps:

```
kelvin-cli eval --corpus ./corpus-pairs --out report.json
kelvin-cli opener-probe --report report.json --corpus ./corpus-pairs        # price the floors
KELVIN_OPENER=soft KELVIN_OPENER_REGION=<r> KELVIN_OPENER_MASS=<m> \
    kelvin-cli eval --corpus ./corpus-pairs                                 # confirm end to end
```

`opener-probe` re-reads an existing report (no re-render) and prices every floor pair: the
resulting `engine-default` mean, fire count, helped/hurt, and the worst single frame — read the
worst frame before the mean, for D19's reason. The confirmation run goes through the shipped path,
where curation keeps its veto, and its `opened in:` line shows the rule firing. Hold the floors
out per "Calibrating a constant" above; a corpus spanning more than two shoots is the honest
prerequisite for shipping a default-on value. The floors are in `RecipeEngine.tuningSignature`
(constant "off" while disabled), so a sweep cannot be served another arm's cached resolutions.

**Calibrated 28 August 2026; it stays off.** The paired corpus says yes at every floor (defaults
7.48 → 7.44, 6 frames fired, worst +1.6); the degradation hold-out says no at every floor (8.09 →
8.18, 7 fired, worst +3.0 on a `dull` degradation). One photographer's signal, not a rule — see
D24's calibration table. `opener-probe` was corrected before these numbers were taken: it now
honours curation's veto (`curatedStyles` from the report) and measures shadow structure on the
perception proxy, the way the rule does.

## Highlights are computed open-loop

`highlightRecovery` sizes itself from **`s.highlightClip` on the source** — `min(66, clip * 400)` —
and nothing re-measures after the recipe is composed. Every `highlightClip` reference in
`RecipeEngine` reads the input statistic; the exposure lever never consults highlights at all.

So on a backlit frame the engine lifts global exposure to rescue the subject, sized against the
*unlifted* input, and the highlights go where they go. Measured on the default candidate: a backlit
interior goes **0.673% → 8.311%** of pixels at ≥254, a tungsten interior 3.007% → 7.354%. A window
with cloud detail in the original renders as paper white.

This is the same finding `bg-probe` reached from the other side: the photographer makes that
separation by lifting the **subject** (+0.40 EV median) while the background stays put (+0.04). A
global lift cannot express that, and the blown window is what it costs.

**Half-closed, 7 August 2026.** `highlightHeadroom` predicts where p99.5 lands after exposure,
contrast and the endpoints, and buys the overshoot back in `highlights`. Measured as clipped-pixel
fraction against each frame's own source — the right instrument here, because the criterion is
per-frame worst case and a corpus mean cannot see it:

| | guard off | guard on |
|---|---|---|
| worst regression over source | +2.003pp | **+1.073pp** |
| frames worse by >1pp | 2 of 4 | 1 of 4 |
| frames with headroom | +0.000pp | +0.000pp |

Corpus: engine-default 7.47 → 7.44, 12 frames better / 2 worse, ruined frames unchanged at 3, no-op
77/77. By eye the window regains readable blind slats where it was paper white, and nothing outside
the highlight region moves.

⚠️ **Still only half.** It is a PREDICTION, not a measurement of the render, and it cannot recover
what a global lift already destroyed — the remaining +1.07pp needs the subject lifted by a MASK
rather than by exposure, which is what the photographer does. The constants (`KELVIN_CLIP_CEILING`,
`KELVIN_HEADROOM_GAIN`, `KELVIN_HEADROOM_CAP`) were chosen on that clipping property, not on ΔE.

⚠️ `highlights` is consequently the one corrective lever that is NOT shared across candidates: the
guard has to read each style's own contrast and endpoints, or it under-protects the style that
lifts hardest. `CandidateGenerationTests` pins the surviving invariant — monotone, not identical.

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
