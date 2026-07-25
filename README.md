# Kelvin

**A local-AI photo editor for macOS.**

Drop in a photo. A small vision model reads the scene, and Kelvin hands you three or four finished
edits to choose between. Pick one, tune it, apply it across the shoot.

Everything runs on your machine. Your photographs never leave it.

<!--
SCREENSHOTS GO HERE — the highest-value thing missing from this file. For a photo editor, one image
of the candidate picker beside a real photograph does more than every paragraph below it. Worth
having: the candidate picker on a real frame, the mask panel with a subject selected, and the
filmstrip grouped into bursts.
-->

## Why

Most tools give you one answer, or ask you to teach them your style with thousands of past edits
first, or repaint your pixels with a generative model.

Kelvin reads one photograph and offers a few defensible interpretations of it. You pick. That choice
is the point of the whole app.

The idea underneath: **the model never chooses numbers.** It answers categorical questions — what
kind of scene, what the light is doing, what's technically wrong. Every actual value is then computed
by ordinary, tested code from the histogram and the EXIF. Ask a small model for `exposure: +0.37` and
it will invent one, confidently, and you will never know which answers were guesses.

## Status: pre-alpha

**Works:** the editor, with the full adjustment set, colour mixer, geometry and a mask kit (subject,
sky, radial, graduated, brush, colour range, luminance, skin, per-person). On-device scene reading.
Candidate generation. Culling with keep/reject. A scan that measures sharpness, exposure extremes and
near-duplicates. Batch apply across a folder. Non-destructive editing — your originals are never
written to.

**Not yet:** no public release build. Preference learning exists in the engine but isn't wired into a
loop. Nothing generative, on purpose.

465 tests. CI runs on every pull request.

## Running it

macOS 14+, Xcode 16.3+.

```sh
xcodebuild -downloadComponent MetalToolchain   # once — Xcode doesn't install this by default
make build && make test
make app
```

The first run downloads about 1.6 GB of model weights. Released builds include them instead — see
[Privacy](#privacy). [`CONTRIBUTING.md`](CONTRIBUTING.md) has the details and the gotchas.

Opens RAW, JPEG, HEIC, PNG and TIFF.

## Privacy

- **Your photographs never leave your Mac.** No upload, no account, no telemetry, no crash reporting.
  There is no server to send anything to.
- **Released builds make no network requests at all** — the model ships inside the app. Building from
  source downloads the weights once, at a fixed revision.
- **Your originals are never modified.** Edits are stored separately.
- **Exports carry the original photo's metadata by default, including its location.** There is a
  switch in the export panel to strip that, with tests that read the file back to prove it works.

## Built with

Swift 6 and SwiftUI. Core Image for RAW decoding, so camera profiles come from Apple. MLX for
on-device inference with a 4-bit vision model. Edits are stored as small JSON recipes.

Mac-only is a choice, not an oversight — see [`docs/DECISIONS.md`](docs/DECISIONS.md).

## Documentation

| | |
|---|---|
| [CONTRIBUTING](CONTRIBUTING.md) | Before your first build or patch |
| [docs/ARCHITECTURE](docs/ARCHITECTURE.md) | How the pipeline fits together |
| [docs/RECIPE-SCHEMA](docs/RECIPE-SCHEMA.md) | The data model |
| [docs/DECISIONS](docs/DECISIONS.md) | Why things are the way they are — read before proposing changes |
| [docs/EVALUATION](docs/EVALUATION.md) | How edit quality is measured |
| [docs/RELEASING](docs/RELEASING.md) | Building a signed, notarised release |

## Contributing

Bug reports and reproductions are welcome and carry no licensing question. For patches, see
[CONTRIBUTING.md](CONTRIBUTING.md).

Kelvin is written by its owner working with Claude, and the commit history says so. That history is
kept rather than squashed — it records what was measured and why decisions went the way they did.

## Licence

[AGPL-3.0-only](LICENSE). If you build on this and ship it — as an app or as a service — your source
has to be open too.

Contributions are covered by a [contributor licence agreement](CLA.md): you keep your copyright, and
the maintainer keeps the ability to relicense. Reasoning in `docs/DECISIONS.md` (D8).

Copyright © 2026 William Wallace.
