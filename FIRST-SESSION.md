# First session

Delete this file once the first milestone is done.

## Before you start Claude Code

Two things only you can do:

1. **Confirm or reject the stack** (`docs/DECISIONS.md` D3 — Swift + Core Image + Metal
   + MLX). This blocks everything else. If you want cross-platform instead, say so now,
   not in month two.
2. **Decide the corpus** (`docs/EVALUATION.md`). Download MIT-Adobe FiveK, or nominate a
   substitute. The eval harness has nothing to chew on without it.

Optional but cheap: grab the GitHub org and domain for whichever name you land on. Names
in this space are disappearing weekly.

## Paste this into Claude Code to open

> Read CLAUDE.md and everything in docs/, then confirm back to me: the one-sentence
> differentiator, the five non-negotiables, and the build order. Don't write any code
> yet. Then tell me what you'd want clarified before starting milestone 1.

Making it read and restate first is worth the two minutes. It surfaces
misunderstandings before they become commits.

## Milestone 1 — the renderer, no AI

**Definition of done:**

- Swift package that opens a RAW file via Core Image and produces a linear buffer
- `Recipe` type matching `docs/RECIPE-SCHEMA.md`, with `Codable` conformance
- Render function: buffer + recipe → buffer, implementing global tone and color only
  (no masks, no curves yet)
- `kelvin-cli render --in photo.CR3 --recipe r.json --out out.jpg`
- **Test: a neutral recipe renders output identical to the unedited decode.** Write
  this first, before the render function exists.
- Clamping on deserialization for every field in the ranges table

No UI. No model. No masks. Resist all three.

## Milestone 2 — the eval harness

**Definition of done:**

- `kelvin-cli eval --corpus ./corpus --out report.json`
- Implements the metrics table in `docs/EVALUATION.md`
- Implements all three baselines, including naive-auto
- Runs the full corpus in under five minutes
- Prints a table a human can read at a glance

**When milestone 2 works, run the naive-auto baseline and look hard at the number.** It
is the honest early test of whether the architectural premise holds. If a histogram
stretch plus grey-world white balance is already close to the expert edits on most of
the corpus, the interesting problem is narrower than assumed and it is much better to
learn that in week three.

## Milestone 3 — the recipe engine, still no model

Hand-write perception JSON for fifty images. Feed it to a rules-based engine. Get the
numbers good enough to beat the baselines.

Only after this passes does any model work begin. If the mapping from perception to
parameters is not good with *perfect* perception input, adding an imperfect model will
not rescue it.

## Things that will feel urgent and are not

- The UI
- The name
- The license
- Batch processing
- Anything generative
- Cross-platform support

Every one of these is cheaper later. The recipes are the project; everything else is
packaging.
