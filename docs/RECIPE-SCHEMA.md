# Recipe schema

This is the contract between the model and the renderer. Get it right early; it is
expensive to change once sidecar files exist in the wild.

There are two documents, and the split between them is the whole architecture.

---

## Stage 1 — Perception (the model writes this)

The VLM emits **only** this. Categorical judgments, no numbers, no adjustments.

```json
{
  "schema_version": 1,
  "scene": "portrait",
  "subject": {
    "present": true,
    "type": "person",
    "count": "single",
    "placement": "center-left"
  },
  "lighting": {
    "condition": "golden-hour",
    "direction": "back",
    "contrast_range": "high"
  },
  "problems": [
    "underexposed-subject",
    "blown-highlights"
  ],
  "intent": "portrait-flattering",
  "confidence": 0.82,
  "notes": "Backlit subject against bright sky, rim light on hair"
}
```

### Enumerations

Keep these closed. An open vocabulary makes the recipe engine untestable.

| Field | Allowed values |
|---|---|
| `scene` | `portrait`, `landscape`, `street`, `interior`, `macro`, `night`, `event`, `still-life`, `document`, `other` |
| `subject.type` | `person`, `animal`, `object`, `none` |
| `subject.count` | `none`, `single`, `few`, `crowd` |
| `subject.placement` | 9-grid: `upper-left` … `center` … `lower-right`, or `distributed` |
| `lighting.condition` | `golden-hour`, `blue-hour`, `overcast`, `harsh-sun`, `open-shade`, `indoor-tungsten`, `indoor-mixed`, `indoor-daylight`, `night-ambient`, `flash`, `backlit` |
| `lighting.direction` | `front`, `side`, `back`, `top`, `diffuse` |
| `lighting.contrast_range` | `low`, `normal`, `high`, `extreme` |
| `problems` | `underexposed-subject`, `overexposed`, `blown-highlights`, `crushed-shadows`, `color-cast`, `low-contrast`, `flat`, `noise`, `haze`, `tilted-horizon`, `soft-focus`, `mixed-white-balance` |
| `intent` | `natural`, `documentary`, `portrait-flattering`, `dramatic`, `archival`, `product-accurate` |

`notes` is free text and is **never parsed**. It exists for debugging and for showing
the user why the app made a choice. Do not build logic on it.

### Why this shape

Every field is something a 4B model can actually answer by looking at a downsampled
JPEG. None of it requires the model to estimate a magnitude, which is the thing small
models cannot do reliably.

`confidence` gates behaviour: below a threshold, fall back to conservative
scene-agnostic recipes rather than committing to a scene-specific look.

---

## Stage 2 — Recipe (the engine writes this)

Fully numeric. Renderer-agnostic. Serializes to the sidecar.

```json
{
  "schema_version": 1,
  "id": "01J8F2K9XQ4M7N",
  "label": "Natural",
  "provenance": {
    "perception_hash": "sha256:a3f1…",
    "engine_version": "0.1.0",
    "profile_id": null,
    "generated_at": "2026-07-23T18:04:11Z"
  },
  "global": {
    "exposure_ev": 0.35,
    "contrast": 8,
    "highlights": -42,
    "shadows": 30,
    "whites": 5,
    "blacks": -8,
    "temperature_k": 5200,
    "tint": 3,
    "vibrance": 12,
    "saturation": 0,
    "clarity": 6,
    "texture": 0,
    "dehaze": 0,
    "fusion": 55
  },
  "curve": {
    "luma": [[0, 0], [64, 58], [192, 200], [255, 255]],
    "red": null,
    "green": null,
    "blue": null
  },
  "hsl": {
    "orange": { "h": -2, "s": 6, "l": 4 }
  },
  "heal": [
    { "x": 0.42, "y": 0.13, "radius": 0.004, "dx": 0.02, "dy": 0.0, "feather": 0.5 }
  ],
  "masks": [
    {
      "id": "m1",
      "type": "subject",
      "source": "segmentation",
      "invert": false,
      "feather": 12,
      "opacity": 1.0,
      "adjustments": {
        "exposure_ev": 0.45,
        "shadows": 18,
        "clarity": -4
      }
    }
  ],
  "detail": {
    "sharpen": 25,
    "nr_luma": 12,
    "nr_color": 20
  },
  "geometry": {
    "rotate_deg": 0.0,
    "crop": null,
    "lens_correction": true
  }
}
```

### Invariants

These are tests, not suggestions.

1. **Neutral is a no-op.** A recipe with every field at its neutral value must render
   output byte-identical to the unedited proxy. Write this test first.
2. **Every field has a defined neutral.** Numeric adjustments neutral at `0`;
   `temperature_k` neutral at the image's as-shot value; `opacity` neutral at `1.0`;
   nullable fields neutral at `null`.
3. **Recipes are diffable.** Two recipes must produce a meaningful field-level diff.
   This is what makes candidate comparison and preference learning possible.
4. **Recipes are composable.** Applying recipe B on top of recipe A must be
   well-defined. Additive for adjustments, last-wins for curves and masks.
5. **Order of operations is fixed and documented in code**, not implied by JSON key
   order. As implemented in `Renderer.render`:

   heal → white balance → exposure → highlight/shadow → whites/blacks →
   contrast/saturation → dehaze → clarity → vibrance → luma curve → RGB curves →
   HSL → masks → detail → **geometry**.

   Note geometry runs *last*, not first as an earlier draft of this doc said. Framing is
   layered on top of the edit, which buys a useful property: **mask coordinates are in
   source space, so re-cropping never moves your masks.** The cost is that a UI placing a
   mask on a straightened preview must map the click back through the crop —
   `Renderer.sourceNormalized` / `framedNormalized` are that exact inverse pair, and are
   round-trip tested against the renderer.
6. **Masks are references, not bitmaps.** The recipe stores mask *type and parameters*;
   the actual mask is regenerated or cached separately. A sidecar must stay small enough
   to sit in git. This holds for every mask kind — see below.

### Mask kinds

All are parametric, so nothing stores pixels. A mask carries at most one of these; the
renderer generates the coverage from it (or, for segmentation kinds, from a bitmap the
caller supplies for that `id`/`type`).

| Kind | Field | How coverage is produced |
|---|---|---|
| `subject`, `sky` | *(none)* | Caller supplies a segmentation bitmap (Vision person seg / sky detection). `"invert": true` on a subject mask gives **background**. |
| `skin` | `selection` | Skin *hue* ∩ the person segmentation. Requires the segmentation — without it the mask does nothing rather than degrading into a hue selection that would grab skin-toned scenery. Keys on hue, never brightness, so it's fair across complexions. |
| `radial`, `linear` | `shape` | `{kind, cx, cy, radius, angle, softness}` — a soft ellipse or a graduated edge. Normalised, top-left origin. |
| `brush` | `stamps` | `[{x, y, radius, hardness}]` — the union of soft circular dabs along a stroke. A caller may supply a pre-baked stroke under the mask's `id` to avoid recompositing every frame; it must render identically. |
| `color`, `luminance` | `selection` | `{kind, center, range, softness}` baked into a cube that keys hue or luma → white-where-selected. Near-grey pixels are excluded from a colour selection. |

`heal` sits outside `masks`: a list of `{x, y, radius, dx, dy, feather}` spots, each patched
from `(dx, dy)` away. Non-generative and applied first, so downstream tone treats the
repaired area like any other pixels.

**Watch the units — they differ by field.** `Mask.feather` is **0…100**, while `HealSpot.feather`
is **0…1** (a fraction, like its `radius`). Both clamp on decode, so getting it wrong fails
silently: a heal spot written with `feather: 50` clamps to `1.0` and comes back maximally soft.

### Ranges

| Field | Range | Neutral |
|---|---|---|
| `exposure_ev` | −5.0 … +5.0 | 0.0 |
| `contrast`, `highlights`, `shadows`, `whites`, `blacks` | −100 … +100 | 0 |
| `vibrance`, `saturation`, `clarity`, `texture`, `dehaze` | −100 … +100 | 0 |
| `temperature_k` | 2000 … 12000 | as-shot |
| `tint` | −150 … +150 | 0 |
| `hsl.*.h` | −100 … +100 | 0 |
| `sharpen`, `nr_luma`, `nr_color` | 0 … 100 | 0 |
| `feather` | 0 … 100 | 0 |

Clamp on deserialization. Never trust a recipe from disk.

---

## Stage 3 — Preference pair (the UI writes this)

Every time the user picks among candidates, that is a labelled comparison. This is the
asset that compounds.

```json
{
  "schema_version": 1,
  "image_id": "sha256:9c2b…",
  "perception_hash": "sha256:a3f1…",
  "shown": ["01J8F2K9XQ4M7N", "01J8F2K9XQ4M7P", "01J8F2K9XQ4M7Q"],
  "chosen": "01J8F2K9XQ4M7P",
  "subsequent_manual_edits": {
    "exposure_ev": -0.15,
    "vibrance": -5
  },
  "timestamp": "2026-07-23T18:05:02Z"
}
```

`subsequent_manual_edits` is the most valuable field in the entire system. It is the
delta between what the app proposed and what the user actually wanted — a direct,
per-field error signal. Capture it from the first version even if nothing consumes it
yet.

Store these locally. They never leave the machine.

---

## Why this beats the incumbent approach

Commercial tools that learn your style (Imagen, Aftershoot) need on the order of
2,500–3,000 previously edited photos to build a profile. That is a brutal cold start and
it excludes everyone who is not already a working professional with a back catalogue.

Four-way picks produce a labelled preference pair per interaction. Twenty choices is a
usable signal. That is the difference between a tool for wedding photographers and a
tool for everyone.

Do not compromise this schema for short-term convenience. It is the moat.
