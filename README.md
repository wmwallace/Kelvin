# Kelvin

**A local-AI photo editor for macOS.** Drop in a photo — RAW, JPEG or PNG. A small vision model reads
the scene. The app hands back three or four fully-formed candidate edits. You pick one, tune it, and
apply it across the rest of the shoot.

Everything that touches your photographs runs on your machine. No cloud, no account, no upload.

<!--
SCREENSHOTS GO HERE, and they are the highest-value thing missing from this file. For a photo editor,
one image of the candidate picker beside a real photograph does more than every paragraph below it.
Three worth having: the candidate picker on a real frame, the mask panel with a subject selected, and
the filmstrip grouped into bursts.
-->

## What makes it different

Existing tools give you one of three things:

- **Deterministic auto-adjust** — one answer, with no reasoning about what the photograph actually is.
- **Style cloning** — genuinely good, but it needs thousands of your own finished edits before it does
  anything at all.
- **Generative editing** — repaints pixels, which is the wrong operation for retouching.

Kelvin does something narrower on purpose: **it reads one photograph semantically, then computes
several defensible interpretations of it and lets you choose.** Your choice is the signal.

The architectural claim underneath that, which is the whole project in one sentence: **the model never
emits numbers.** It returns categorical judgements — scene, subject, lighting condition, what is
technically wrong. Every actual parameter is computed by deterministic, unit-tested code from the
histogram, the EXIF and the mask stack. Ask a 4B-class model for `exposure_ev: +0.37` and it will
invent one confidently, and you will never be able to tell a good hallucination from a bad one.

## Status: pre-alpha, source only

Honest summary of where this is:

**Working** — the recipe format and renderer; the evaluation harness; the recipe engine and candidate
generation; on-device perception through a 4-bit vision model; the editor itself, with the full
adjustment set, a colour mixer, geometry, and a mask kit (subject, sky, radial, graduated, brush,
colour-range, luminance, skin, per-instance subjects); culling with keep/reject flags; a triage scan
that measures sharpness, exposure extremes and near-duplicates; batch apply across a folder;
non-destructive sidecar persistence.

**Not working yet** — there is no *released* binary. `scripts/package-app.sh` produces a working
double-clickable app, but nothing is signed or notarised yet, so macOS will refuse to open it on
anyone else's machine; building from source is the supported route for now. Preference learning
exists in the engine but is not a live loop.

**Not built** — anything generative. See `docs/DECISIONS.md` D10.

There are 369 tests over the core and 85 over the app. CI runs the core suite on every pull request.

## Running it

Requires **macOS 14+** and **Xcode 16.3+**.

```sh
xcodebuild -downloadComponent MetalToolchain    # once — Xcode does not install this by default
make build && make test                        # core: renderer, engine, eval harness
make app                                       # launch the editor
```

Building from source, the first run downloads about **1.6 GB of model weights** from Hugging Face
into `~/.cache/huggingface`, pinned to the exact revision this project was measured against. To skip
that and run the same path a release build takes:

```sh
make stage-model && make app-staged
```

**A released build downloads nothing.** The weights ship inside the app — see [Privacy](#privacy).

Fuller instructions, and the gotchas worth knowing before you file a build issue, are in
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## Privacy

The claim is specific, so here is exactly what it means:

- **Your photographs never leave your machine.** No upload, no account, no telemetry, no analytics, no
  crash reporting. There is no server component to send anything to.
- **Edits are written to sidecars** in Application Support, never next to your originals and never
  into them. The original file is read-only by design.
- **Exports carry the source photograph's metadata by default**, including its GPS position — the same
  behaviour as every other editor. The export panel has a toggle to strip location and camera serial,
  and there are tests that read the written file back to prove it works.
- **A released build makes no network requests at all.** The perception weights ship inside the app,
  so there is no first-run download, no model server, and nothing to be rate-limited by. It works on
  a plane, on day one. That is also why the app is ~1.6 GB.
- **Building from source is the one exception:** an unstaged source build fetches the weights from
  Hugging Face once, pinned to a fixed revision. `make stage-model` avoids even that.

## How it is built

| | |
|---|---|
| Language | Swift 6 |
| UI | SwiftUI |
| RAW decode | Core Image (`CIRAWFilter`) — Apple's decoder and per-camera colour profiles |
| Render | Core Image / Metal |
| Inference | MLX Swift, a 4-bit vision model (Apache-2.0 weights) |
| Persistence | JSON sidecars |

Two packages, deliberately: the root package is the renderer, recipe engine and eval harness, with
**no MLX and no UI** — headless, fast and independently testable. `Integrations/KelvinPerceptionMLX`
holds the SwiftUI app and the vision backend.

Mac-only is a positioning choice, not an oversight. See `docs/DECISIONS.md` D3.

## Documentation

| Document | Read it when |
|---|---|
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Before your first build or patch |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Understanding the pipeline |
| [`docs/RECIPE-SCHEMA.md`](docs/RECIPE-SCHEMA.md) | Touching the data model |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | **Before proposing any architectural change** — most obvious ideas are already in here with reasons |
| [`docs/EVALUATION.md`](docs/EVALUATION.md) | Judging whether an edit is actually better |
| [`CLAUDE.md`](CLAUDE.md) | Working on this with an AI assistant |

## How this was built

Kelvin is written by its owner working with Claude, and the commit history says so — most commits
carry a `Co-Authored-By` trailer, and the messages are long because they record what was measured and
why a decision went the way it did. That history is deliberately kept rather than squashed; it is the
most honest documentation in the repository.

## Contributing

Bug reports and reproductions are genuinely valuable and carry no licensing question. For patches, see
[`CONTRIBUTING.md`](CONTRIBUTING.md) — including the five non-negotiables a change has to respect, and
the reason edits are judged with the evaluation harness rather than by eye.

## Licence

**[AGPL-3.0-only](LICENSE).** Copyleft on purpose: if you build on this and ship it — as an
application or as a hosted service — your source has to be open too. Nobody gets to close this work.

Contributions are covered by a [contributor licence agreement](CLA.md) which leaves your copyright
with you and grants the maintainer the right to relicense. The reasoning, including why that is
necessary rather than merely convenient, is in `docs/DECISIONS.md` D8.

Copyright © 2026 William Wallace.
