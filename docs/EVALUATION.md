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
kelvin-cli corpus-degrade --in-dir ~/Pictures/keepers --out-dir ./corpus
kelvin-cli eval --corpus ./corpus
```

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

- Beats camera JPEG on min-ΔE for **> 80%** of the corpus
- Never clips highlights worse than the camera JPEG on **any** image
- Beats naive-auto on min-ΔE for **> 70%** of the corpus
- No-op fidelity passes at 100%
- The four generated candidates are *meaningfully different* — pairwise ΔE between
  candidates above a floor, so the picker offers a real choice rather than four
  near-identical looks

That last one is easy to lose accidentally and it kills the product concept if lost. Add
it as a test early.

## A caution on the target

"Great results every time" is not achievable and chasing it will stall the project.
Photo quality is subjective; there is no every-time. The workable target is:

> Never worse than the camera JPEG, and a good enough starting point often enough that
> correcting is faster than editing from scratch.

That is measurable, and it is the bar that decides whether people keep using the app.
