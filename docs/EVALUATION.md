# Evaluation

**Build this second, immediately after the recipe renderer, and before any model work.**

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

**MIT-Adobe FiveK** is the natural starting point: thousands of RAW files, each
retouched independently by five different expert photographers.

Note what that structure gives you for free — five expert interpretations of the same
photograph is *literally the candidate-previews feature*, pre-labelled. It is both the
evaluation set and the proof that the product concept is coherent. Photographers do
disagree, meaningfully, and the disagreement is the product.

Confirm the licence permits the intended use before building on it.

Supplement with a small in-house set of hard cases: mixed indoor lighting, heavy
backlight, night, high-ISO, snow and beach (exposure-meter traps), and skin tones across
a range of complexions. Twenty to fifty images, hand-curated, checked into the repo as a
regression suite.

## Metrics

No single number is sufficient. Report all of these; do not collapse them.

| Metric | What it catches | Notes |
|---|---|---|
| ΔE2000 vs each expert edit | Overall color and tone distance | Report min across the five experts, not mean — matching *any* expert is success |
| Histogram clipping delta | Blown highlights, crushed blacks | Regressions here are always bugs |
| Skin-tone ΔE, masked | The failure users notice fastest | Weight this heavily |
| White-balance error vs expert median | Systematic color cast | |
| No-op fidelity | Neutral recipe renders identical output | Binary. Must always pass |
| Wall-clock per image | Performance regression | Fail the build on regression |

**Report min-across-experts, not mean.** Averaging five expert edits produces a muddy
target that no human would choose and that punishes any confident stylistic choice. The
question is "did we land near *a* defensible interpretation," not "did we hit the
centroid."

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
