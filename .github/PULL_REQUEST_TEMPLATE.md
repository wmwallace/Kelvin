<!--
Keep this short. The questions below are the ones a reviewer would otherwise have to ask, and
answering them up front usually saves a round trip.
-->

## What this changes

<!-- One or two sentences. What behaviour is different afterwards? -->

## Why

<!-- The problem, not the patch. If it fixes something a photographer would hit, describe the
photograph or the workflow: "a burst of six where the third frame is the sharpest", "a RAW with no
GPS", "switching photos while a Fix is still converging". -->

## What you measured

<!-- This codebase argues with numbers. If the change is about performance, quality or a threshold,
give the measurement: before/after timings, a ΔE, an acuity reading, how many frames you tried it
on. "Feels faster" is not reviewable; "18 ms per dab at 1200 stamps, now 0.8 ms" is.

If the change is about whether an edit LOOKS better, use the evaluation harness rather than your
eye — `make eval CORPUS=...`, see docs/EVALUATION.md. -->

## Checks

- [ ] `make test` is green (core package)
- [ ] `cd Integrations/KelvinPerceptionMLX && swift test` is green, if the app or perception layer changed
- [ ] No new hardcoded product name — it lives in `Sources/KelvinCore/Branding.swift`
- [ ] Any new recipe field is added in **all four places** `GlobalAdjustments` requires, or
      `RecipeRoundTripTests` will pass while the field silently never saves
- [ ] Any new control actually affects the render — see `NoDeadControlsTests`
- [ ] No change to `docs/DECISIONS.md` conclusions without saying so below

## Anything you decided that a reviewer might disagree with

<!-- Optional, and the most useful box on this form. Name the trade-off you made and why you made it
that way, especially if you considered and rejected an alternative. -->
