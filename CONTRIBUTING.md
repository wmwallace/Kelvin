# Contributing

Thanks for looking. This is a small project with strong opinions, and the fastest way to have a
patch accepted is to know what those opinions are before you write it.

## Before you build: the gotchas that will cost you an hour

**You need the Metal toolchain, and Xcode does not install it by default.** Xcode 16 split the Metal
compiler into a separate component. Without it, the perception package fails to build with an error
that looks like a broken toolchain rather than a missing download:

```sh
xcodebuild -downloadComponent MetalToolchain     # ~840 MB, once
```

**The first run downloads ~1.6 GB of model weights** from Hugging Face into `~/.cache/huggingface`,
at a pinned revision, unless you stage them locally (see below). This applies to source builds only —
**released apps ship the weights inside the bundle and make no network requests at all**, which is
enforced: `scripts/package-app.sh` refuses to produce a signed build without staged weights.

**Requirements:** macOS 14+, Xcode 16.3+ (Swift 6.1 for the app package; the core package needs
only Swift 6.0).

### It has to build on an older Xcode than yours, and CI is the judge

Apple gave CoreImage's `CIImage` and `CIContext`, and AppKit's `NSImage`, their `Sendable`
conformances in the macOS 27 SDK. CI builds against the SDK in Xcode 16, where they do not have
them, and under Swift 6 that difference is not cosmetic — it is a dozen hard errors in code that
compiles perfectly on a current Mac.

Two consequences worth knowing before they cost you an afternoon:

- Several files import CoreImage `@preconcurrency`, and a few declarations carry
  `nonisolated(unsafe)`. **A recent Xcode will tell you these are unnecessary and offer to remove
  them.** They are unnecessary *on that SDK only*. Removing them breaks the build for everyone
  else, which has already happened once. Each site says so in a comment.
- A green build on your machine proves less than you would like. If you cannot run the CI SDK
  locally, push to a branch and let CI answer — it is the only place both toolchains are checked.

## Build and test

The repository is two packages, deliberately:

| | What | Cost |
|---|---|---|
| Root package | `KelvinCore` + `kelvin-cli` — the renderer, recipe engine, eval harness. **No MLX, no UI.** | seconds |
| `Integrations/KelvinPerceptionMLX` | The SwiftUI app and the on-device vision model backend | minutes |

```sh
make build && make test      # the core package: 564 tests, ~35s
make app                     # launch the editor
make open PHOTO=~/path/to/photo.ARW    # launch it on one frame

cd Integrations/KelvinPerceptionMLX && swift build && swift test    # the app package: 221 tests
```

`make` builds into `$TMPDIR` rather than `.build`. That is not a preference — this repository may sit
on a file-provider-backed directory (iCloud), such volumes stamp `com.apple.FinderInfo` onto build
products, and `codesign` then refuses to sign the `.xctest` bundle, which breaks `swift test`. Pass
`make BUILD_PATH=/somewhere test` if you want it elsewhere.

To run against a local copy of the weights instead of the Hugging Face cache — the same path a
release build takes:

```sh
make stage-model     # copies the weights + their licence into Vendor/PerceptionModel
make app-staged
```

`stage-model` will refuse if the weights have no `LICENSE` beside them. That is deliberate: bundling
weights is redistribution, and Apache-2.0 requires the licence to travel with them.

## The five rules a patch has to respect

These are load-bearing and predate you; `CLAUDE.md` explains each at length. A PR that violates one
will get a request for changes even if the code is good.

1. **The vision model never emits numbers.** It returns categorical judgements — scene, subject,
   lighting, what is technically wrong. Every actual parameter is computed by deterministic,
   unit-tested code from the histogram, the EXIF and the mask stack. A 4B-class model asked for
   `exposure_ev: +0.37` will invent it confidently, and nobody will ever be able to tell a good
   hallucination from a bad one.
2. **Do not build a RAW pipeline.** Core Image gives us Apple's decoder, demosaicing and per-camera
   colour profiles. That is a year of colour science we are not spending. If you find yourself
   writing a demosaicing algorithm, open an issue instead.
3. **Edits are parametric and non-destructive, always.** The unit of work is a recipe — a small
   struct of numbers — not pixels. The original is never written to.
4. **Proxy-first.** Everything interactive runs on a downsampled proxy; full resolution touches the
   pipeline exactly once, at export.
5. **Boring infrastructure, novel product.** The novelty budget is spent on the recipe format and
   the preference loop. Everything else should be the most proven approach available.

Two more that will save you a round trip:

- **A recipe of all-neutral values must render a byte-identical no-op.** There is a test for it.
- **Never hardcode the product name.** It lives in `Sources/KelvinCore/Branding.swift` and nowhere
  else. Note that "Kelvin" is also the SI unit and appears legitimately throughout the
  colour-temperature code — those are physics, not branding.

## Read this before proposing an architectural change

`docs/DECISIONS.md` records what was already considered and rejected, and why. Most of the obvious
ideas are in there. Disagreeing with one is welcome; not knowing it exists means the discussion
starts from scratch. Also useful: `docs/ARCHITECTURE.md` for the pipeline, `docs/RECIPE-SCHEMA.md`
for the data model, `docs/EVALUATION.md` for how output quality is measured.

## Judging whether an edit looks good

**Do not use your own eye, and do not ask a reviewer to use theirs.** Use the evaluation harness:

```sh
make eval CORPUS=./corpus
```

`docs/EVALUATION.md` explains how to build a corpus from your own photographs — which is the only
licence-clean way to do it. The project deliberately does not tune against MIT-Adobe FiveK or
PPR10K; both are non-commercial-research only, and that restriction extends to derived data.

## Pull requests

- One concern per PR. A rename plus a bug fix plus a refactor is three reviews wearing one hat.
- Tests for behaviour a photographer would notice being broken. That is the bar the existing suite
  is written to, and the test names read as sentences describing the rule.
- `make test` green before you open it. CI runs the core suite on every PR; the MLX job is
  informational for now.
- Say what you measured. This codebase argues with numbers — "18 ms per dab at 1200 stamps" beats
  "felt slow" every time, and it is how the existing comments justify themselves.
- Comments explain **why**, not what. Look at any file for the house style; it is unusual and it is
  intentional.

## Reporting a bug

Include the macOS version, the Mac (Apple Silicon or Intel), the file format that triggered it, and
what you expected instead. If it involves a photograph you cannot share, say so — the shape of the
frame (backlit, high ISO, no clear subject) is usually enough to reproduce it synthetically.

## Licence and the contributor agreement

This project is **AGPL-3.0-only** ([`LICENSE`](LICENSE)). Your contribution is released under the same
terms, and every published release stays under them permanently.

There is also a **contributor licence agreement** ([`CLA.md`](CLA.md)), and it is worth two minutes of
your time to understand why rather than just clicking through it. You keep your copyright. What you
grant is the right for the maintainer to license the project under other terms in future — a
commercial edition, or Mac App Store distribution, whose terms the FSF considers incompatible with the
GPL family. Without that grant, the first merged pull request would permanently foreclose those
options, because relicensing would then require the permission of every contributor who ever
participated.

The AGPL is doing the load-bearing work here: nobody can take this and close it. The agreement exists
so that "nobody" does not accidentally include the person who wrote it.

An automated check will ask you to accept it on your first pull request — one click, recorded once.
Typo and whitespace fixes are exempt.

**If you would rather not sign, you can still help.** Bug reports, reproductions, measurements and
design critique carry no licensing question, and on this project they are often worth more than a
patch.
