# Proposed keyboard shortcuts

A wish list, not a plan. Recorded verbatim from the owner (27 July 2026) so it survives the
conversation it arrived in, then annotated: what Kelvin already binds, what conflicts, and what
describes a feature that does not exist yet.

Most of this vocabulary is Lightroom's, which is the right instinct — a photographer's hands already
know it, and every shortcut that matches one they know is a thing they do not have to learn. The
annotations are only about which of these Kelvin can honestly honour today.

## What Kelvin binds today

| Key | Action |
|---|---|
| `P` | Keep, and advance |
| `X` | Reject, and advance |
| `⌘O` | Open photo or folder |
| `⇧⌘W` | Close photo |
| `⌘Z` / `⇧⌘Z` | Undo / redo |
| hold | Before/after compare |

## The list, annotated

**Ready to adopt** — the action exists and the key is free:

- Next / previous photo — `→` / `←` (already works; not currently documented as a shortcut)
- Show/hide filmstrip — `/`
- Zoom in / out — `⌘=` / `⌘−`
- Toggle last zoom ratio — `Space`
- Select all / none — `⌘A` / `⌘D` (needs the selection model — see batch apply)
- Show/hide original — `\` (currently press-and-hold only; a toggle is a genuine addition)
- Reset all edits — `⌘R`
- Reset a slider — click its name (currently double-click the row; clicking the label is better)
- Histogram / Light / Colour / Effects / Detail — `⌘0`…`⌘4` to focus a panel section
- Masking tool — `M`; brush — `B`; linear — `L`; radial — `R`
- Colour range — `⇧C`; luminance range — `⇧I`
- Brush size up/down — `]` / `[`; feathering — `⇧]` / `⇧[`
- Invert mask — `⌘I`; show/hide overlay — `O`
- Export — `⇧E`

**Conflicts, needing a decision:**

- **Pick `Z` / Reject `X` vs Kelvin's `P` / `X`.** Kelvin's `P` came from "pick"; the list wants `Z`.
  Reject agrees at `X`, but the same list also gives `X` to "switch crop orientation". One of the two
  has to move.
- **`A`** is asked to do both "visualize spots" and "auto mask toggle".
- **`O`** is asked to do both "cycle crop overlay" and "show/hide mask overlay".
- **`D`** is "detail view" under navigation and "depth range" under masking (`⇧D`).

**Describes something Kelvin does not have** — worth keeping as a record of intended direction:

- Grid view, detail view, full-screen detail (`G`, `D`, `F`) — the gallery is a strip, not a grid
- Star ratings `0`–`5` and colour labels `6`–`9` — flags are deliberately binary (see `Flag`)
- Keywords panel (`K`), Info panel (`I`)
- Crop tool (`C`), rotate (`⌘[` / `⌘]`), flip, overlay styles
- Optics (`⌘5`), lens blur (`⌘6`), geometry (`⌘7`) panels
- Presets (`⇧P`) and profiles (`⇧B`) as panels
- Copy / paste edit settings (`⌘C` / `⌘V`) — the batch apply redesign covers the same ground
- Auto tone (`⇧A`), clipping view (`J`), white balance eyedropper (`W`)
- Remove tool modes (content-aware / clone / erase) — ~~`H`~~ **adopted 31 July 2026**: the heal
  tool is a mode now, so `H` toggles it. Only the one mode, and the auto-detection it replaced is
  gone (see `SpotHeal`)
- Depth range masks — needs a depth source Vision does not give us
- Slider nudge on hover with `↑`/`↓`

## Rule for adopting any of these

A shortcut that does nothing is worse than no shortcut, and one that does something unexpected is
worse again. Each key here ships only when the action behind it exists, and the shortcuts sheet
(`Shortcuts` in the header) is updated in the same commit — that sheet is the app's own account of
what it can do, and a stale one teaches people wrong things.
