# Kelvin *(working name — see docs/DECISIONS.md D9)*

A local-AI photo editor for macOS.

Drop in a photo — RAW, JPEG, or PNG. A small vision model reads the scene. The app hands
back three or four fully-formed candidate edits. You pick the one you like, it applies
that look to the rest of the shoot, and it learns from your pick.

Everything runs on-device. No cloud, no account, no upload.

---

## Why this exists

Existing tools give you one of three things:

- **Deterministic auto-adjust** — one answer, no reasoning about what the photo actually
  is
- **Style cloning** — genuinely good, but needs 2,500+ of your own finished edits before
  it does anything
- **Generative editing** — repaints pixels, which is the wrong operation for retouching

None of them look at the photograph, understand it, and offer you a choice between
defensible interpretations. That is the gap.

## Status

Pre-alpha. Private. Nothing works yet.

## Documentation

| Document | Read it when |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | Every session. Start here. |
| [`docs/RECIPE-SCHEMA.md`](docs/RECIPE-SCHEMA.md) | Touching the data model |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Touching the pipeline |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Before proposing any architectural change |
| [`docs/EVALUATION.md`](docs/EVALUATION.md) | Before any model work |
| [`docs/LANDSCAPE.md`](docs/LANDSCAPE.md) | Before building something that may exist |
| [`FIRST-SESSION.md`](FIRST-SESSION.md) | Right now, once |

## License

Deliberately not chosen yet. See `docs/DECISIONS.md` D8.
