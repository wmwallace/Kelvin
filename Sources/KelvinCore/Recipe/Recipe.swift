import Foundation

/// A parametric, non-destructive edit — the unit of work in the app (docs/DECISIONS.md D4).
/// Serializes to a JSON sidecar. Matches docs/RECIPE-SCHEMA.md Stage 2.
///
/// Milestone 1 renders `global` only. `curve`, `hsl`, `masks`, `detail`, and `geometry`
/// are modelled and round-trip through JSON from commit one (schema is versioned from the
/// start), but the renderer does not yet apply them. See `Renderer`.
public struct Recipe: Codable, Equatable, Sendable {
    /// Versioned from commit one. Every serialized recipe carries this (CLAUDE.md).
    public var schemaVersion: Int
    public var id: String?
    public var label: String?
    public var provenance: Provenance?
    public var global: GlobalAdjustments
    public var curve: Curve?
    public var hsl: [String: HSLAdjustment]?
    /// Black-and-white conversion with per-hue control. `nil` keeps the photo in colour.
    public var blackAndWhite: BlackAndWhiteMix?
    public var masks: [Mask]?
    public var detail: Detail?
    public var geometry: Geometry?
    /// Non-destructive spot healing (dust, sensor spots, small blemishes). Stored as references
    /// — positions + a source offset — not baked pixels, so it's replayable and batch-portable.
    /// Defaulted so existing constructors are unaffected; the base edit path never sets it.
    public var heal: [HealSpot]? = nil

    public static let currentSchemaVersion = 1

    /// The all-neutral recipe. Rendering it MUST be a byte-identical no-op — this is the
    /// milestone-1 gating invariant (docs/RECIPE-SCHEMA.md invariant #1).
    public static let neutral = Recipe(
        schemaVersion: currentSchemaVersion,
        id: nil,
        label: nil,
        provenance: nil,
        global: .neutral,
        curve: nil,
        hsl: nil,
        masks: nil,
        detail: nil,
        geometry: nil
    )

    public init(
        schemaVersion: Int,
        id: String?,
        label: String?,
        provenance: Provenance?,
        global: GlobalAdjustments,
        curve: Curve?,
        hsl: [String: HSLAdjustment]?,
        masks: [Mask]?,
        detail: Detail?,
        geometry: Geometry?
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.label = label
        self.provenance = provenance
        self.global = global
        self.curve = curve
        self.hsl = hsl
        self.masks = masks
        self.detail = detail
        self.geometry = geometry
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id, label, provenance, global, curve, hsl, masks, detail, geometry, heal
        case blackAndWhite = "black_and_white"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Recipe.currentSchemaVersion
        id = try c.decodeIfPresent(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        provenance = try c.decodeIfPresent(Provenance.self, forKey: .provenance)
        global = try c.decodeIfPresent(GlobalAdjustments.self, forKey: .global) ?? .neutral
        curve = try c.decodeIfPresent(Curve.self, forKey: .curve)
        hsl = try c.decodeIfPresent([String: HSLAdjustment].self, forKey: .hsl)
        blackAndWhite = try c.decodeIfPresent(BlackAndWhiteMix.self, forKey: .blackAndWhite)
        masks = try c.decodeIfPresent([Mask].self, forKey: .masks)
        detail = try c.decodeIfPresent(Detail.self, forKey: .detail)
        geometry = try c.decodeIfPresent(Geometry.self, forKey: .geometry)
        heal = try c.decodeIfPresent([HealSpot].self, forKey: .heal)
    }
}

/// A single non-destructive heal: cover the spot at (`x`,`y`) by sampling a clean patch offset by
/// (`dx`,`dy`). All values are normalised — `x`/`y`/`dx`/`dy` as fractions of width/height (top-left
/// origin, y down), `radius`/`feather` as fractions of the shorter edge — so one heal list applies
/// across any resolution and across a whole shoot (sensor dust sits at a fixed position).
public struct HealSpot: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var radius: Double
    public var dx: Double
    public var dy: Double
    public var feather: Double

    public init(x: Double, y: Double, radius: Double, dx: Double, dy: Double, feather: Double = 0.5) {
        self.x = x; self.y = y; self.radius = radius; self.dx = dx; self.dy = dy; self.feather = feather
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = clamp(try c.decodeIfPresent(Double.self, forKey: .x) ?? 0, to: 0...1)
        y = clamp(try c.decodeIfPresent(Double.self, forKey: .y) ?? 0, to: 0...1)
        radius = clamp(try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0, to: 0...0.5)
        dx = clamp(try c.decodeIfPresent(Double.self, forKey: .dx) ?? 0, to: -1...1)
        dy = clamp(try c.decodeIfPresent(Double.self, forKey: .dy) ?? 0, to: -1...1)
        feather = clamp(try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.5, to: 0...1)
    }

    enum CodingKeys: String, CodingKey { case x, y, radius, dx, dy, feather }
}

public struct Provenance: Codable, Equatable, Sendable {
    public var perceptionHash: String?
    public var engineVersion: String?
    public var profileId: String?
    public var generatedAt: String?

    enum CodingKeys: String, CodingKey {
        case perceptionHash = "perception_hash"
        case engineVersion = "engine_version"
        case profileId = "profile_id"
        case generatedAt = "generated_at"
    }
}

/// Global tone and color. Every field clamps on decode. `temperatureK` is nullable because
/// its neutral is the image's as-shot value, not a fixed number (invariant #2).
public struct GlobalAdjustments: Codable, Equatable, Sendable {
    public var exposureEV: Double
    public var contrast: Double
    public var highlights: Double
    public var shadows: Double
    public var whites: Double
    public var blacks: Double
    public var temperatureK: Double?
    public var tint: Double
    public var vibrance: Double
    public var saturation: Double
    public var clarity: Double
    public var texture: Double
    public var dehaze: Double
    /// Single-image exposure fusion, 0…100. Local tone mapping: opens shadows and holds
    /// highlights without touching midtones — see `ExposureFusion`. Neutral 0.
    public var fusion: Double

    public static let neutral = GlobalAdjustments(
        exposureEV: 0, contrast: 0, highlights: 0, shadows: 0, whites: 0, blacks: 0,
        temperatureK: nil, tint: 0, vibrance: 0, saturation: 0, clarity: 0, texture: 0,
        dehaze: 0, fusion: 0
    )

    public init(
        exposureEV: Double, contrast: Double, highlights: Double, shadows: Double,
        whites: Double, blacks: Double, temperatureK: Double?, tint: Double,
        vibrance: Double, saturation: Double, clarity: Double, texture: Double,
        dehaze: Double, fusion: Double = 0
    ) {
        self.exposureEV = exposureEV
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.temperatureK = temperatureK
        self.tint = tint
        self.vibrance = vibrance
        self.saturation = saturation
        self.clarity = clarity
        self.texture = texture
        self.dehaze = dehaze
        self.fusion = fusion
    }

    enum CodingKeys: String, CodingKey {
        case exposureEV = "exposure_ev"
        case contrast, highlights, shadows, whites, blacks
        case temperatureK = "temperature_k"
        case tint, vibrance, saturation, clarity, texture, dehaze, fusion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposureEV = try c.clampedDouble(.exposureEV, default: 0, in: Ranges.exposureEV)
        contrast = try c.clampedDouble(.contrast, default: 0, in: Ranges.signed100)
        highlights = try c.clampedDouble(.highlights, default: 0, in: Ranges.signed100)
        shadows = try c.clampedDouble(.shadows, default: 0, in: Ranges.signed100)
        whites = try c.clampedDouble(.whites, default: 0, in: Ranges.signed100)
        blacks = try c.clampedDouble(.blacks, default: 0, in: Ranges.signed100)
        temperatureK = try c.clampedOptionalDouble(.temperatureK, in: Ranges.temperatureK)
        tint = try c.clampedDouble(.tint, default: 0, in: Ranges.tint)
        vibrance = try c.clampedDouble(.vibrance, default: 0, in: Ranges.signed100)
        saturation = try c.clampedDouble(.saturation, default: 0, in: Ranges.signed100)
        clarity = try c.clampedDouble(.clarity, default: 0, in: Ranges.signed100)
        texture = try c.clampedDouble(.texture, default: 0, in: Ranges.signed100)
        dehaze = try c.clampedDouble(.dehaze, default: 0, in: Ranges.signed100)
        fusion = try c.clampedDouble(.fusion, default: 0, in: Ranges.unsigned100)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exposureEV, forKey: .exposureEV)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(highlights, forKey: .highlights)
        try c.encode(shadows, forKey: .shadows)
        try c.encode(whites, forKey: .whites)
        try c.encode(blacks, forKey: .blacks)
        try c.encodeIfPresent(temperatureK, forKey: .temperatureK)
        try c.encode(tint, forKey: .tint)
        try c.encode(vibrance, forKey: .vibrance)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(clarity, forKey: .clarity)
        try c.encode(texture, forKey: .texture)
        try c.encode(dehaze, forKey: .dehaze)
        try c.encode(fusion, forKey: .fusion)
    }

    /// True when this recipe would leave the image untouched (used by the renderer to
    /// guarantee a genuine no-op rather than an identity filter pass).
    public var isNeutral: Bool { self == .neutral }
}

/// Tone curves as control-point lists in 0…255 space. Not applied by the M1 renderer.
public struct Curve: Codable, Equatable, Sendable {
    public var luma: [[Double]]?
    public var red: [[Double]]?
    public var green: [[Double]]?
    public var blue: [[Double]]?
}

/// A black-and-white conversion, the way a photographer means it: not "remove the colour" but
/// *choose how each colour becomes a shade of grey*. This is the digital equivalent of the coloured
/// filters film shooters put in front of the lens — a red filter darkens blue sky to near-black and
/// makes clouds leap out; a yellow-green one lifts foliage. Straight desaturation throws that
/// control away and is why naive B&W looks muddy.
///
/// `bands` maps a hue band (`red`/`orange`/…/`magenta`) to −100…100: how much pixels of that hue
/// are darkened or lightened in the grey result. Absent or all-zero still converts to grey, using
/// the plain luminance mix.
public struct BlackAndWhiteMix: Codable, Equatable, Sendable {
    public var bands: [String: Double]

    public init(bands: [String: Double] = [:]) { self.bands = bands }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: Double].self, forKey: .bands) ?? [:]
        bands = raw.mapValues { clamp($0, to: Ranges.signed100) }
    }

    enum CodingKeys: String, CodingKey { case bands }
}

/// Per-color HSL adjustment. Each channel clamps to −100…100.
public struct HSLAdjustment: Codable, Equatable, Sendable {
    public var h: Double
    public var s: Double
    public var l: Double

    public init(h: Double, s: Double, l: Double) {
        self.h = h; self.s = s; self.l = l
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        h = try c.clampedDouble(.h, default: 0, in: Ranges.signed100)
        s = try c.clampedDouble(.s, default: 0, in: Ranges.signed100)
        l = try c.clampedDouble(.l, default: 0, in: Ranges.signed100)
    }

    enum CodingKeys: String, CodingKey { case h, s, l }
}

/// A masked local adjustment. Masks are references (type + params), never bitmaps
/// (invariant #6). Adjustments are kept as a keyed map for M1 since the renderer does not
/// yet apply masks; the typed local-adjustment struct lands with mask rendering.
public struct Mask: Codable, Equatable, Sendable {

    /// Every local adjustment the renderer honours inside a mask, in the order a photographer
    /// works: light first, then colour. THIS IS THE CONTRACT between the renderer and every UI
    /// that offers mask controls.
    ///
    /// It lives here, tested, because the two mask editors in the app had silently drifted apart:
    /// the auto masks (subject, sky) offered all six while every hand-drawn mask — radial,
    /// graduated, brush, colour, luminance, skin, background, subject, instance — could only carry
    /// exposure, contrast and saturation. Half the renderer's local capability was unreachable on
    /// the masks people actually draw, including `shadows`, which the engine's own subject mask
    /// reaches for deliberately as the tone-fair way to open up a face.
    ///
    /// Two hand-written lists cannot disagree if there is only one list.
    public static let adjustmentKeys = [
        "exposure_ev", "highlights", "shadows", "contrast", "saturation", "vibrance"
    ]

    public var id: String
    public var type: String
    public var source: String?
    public var invert: Bool
    public var feather: Double
    public var opacity: Double
    public var adjustments: [String: Double]
    /// For hand-drawn *parametric* masks (radial / linear gradients) the geometry lives here and
    /// the renderer generates the mask from it — no bitmap needed, so it serialises as pure numbers
    /// (non-negotiable #3). Segmentation masks (subject/sky) leave this nil and supply a bitmap.
    public var shape: MaskShape?
    /// A brush mask: the union of soft circular stamps laid down along the user's strokes. Still
    /// pure numbers (like HealSpot) — the renderer composites the stamps into the mask.
    public var stamps: [BrushStamp]?
    /// A selection mask generated FROM the image by colour or luminance range — "adjust the reds",
    /// "adjust the highlights". Parametric (a target + range), the renderer bakes it into a cube.
    /// This is the mask's SOURCE — it says where the region comes from.
    public var selection: MaskSelection?

    /// Narrows whatever region the source produced to pixels that ALSO fall in a colour or
    /// luminance range. The mask's one modifier of substance, alongside `invert`.
    ///
    /// "Skin" used to be a mask type with a bespoke branch in the renderer: skin-coloured pixels
    /// intersected with the person segmentation. That is not a KIND of mask — it is a subject mask
    /// with a colour refinement — and encoding it as a kind meant the intersection existed for
    /// exactly one combination out of the many people want. Generalised, the same machinery
    /// expresses "the highlights within this person", "the reds inside a graduated filter", "the
    /// bright part of the sky", none of which were reachable before.
    ///
    /// Optional, so a sidecar written before it existed decodes unchanged.
    public var refine: MaskSelection?

    /// Optional mask tightness / edge contrast (0…100). Higher tightness sharpens the transition
    /// boundary of soft mask edges. Neutral 0.
    public var tightness: Double?

    public init(
        id: String, type: String, source: String?, invert: Bool,
        feather: Double, opacity: Double, adjustments: [String: Double],
        shape: MaskShape? = nil, stamps: [BrushStamp]? = nil, selection: MaskSelection? = nil,
        tightness: Double? = nil, refine: MaskSelection? = nil
    ) {
        self.id = id; self.type = type; self.source = source; self.invert = invert
        self.feather = feather; self.opacity = opacity; self.adjustments = adjustments
        self.shape = shape; self.stamps = stamps; self.selection = selection
        self.tightness = tightness; self.refine = refine
    }

    /// The colour range that stands for human skin across complexions — hue, never brightness,
    /// which is what keeps it fair. A named constant because it is a claim about people rather
    /// than a tuning value, and it now CONSTRUCTS a refinement instead of hiding in a renderer
    /// branch.
    public static let skinRefinement = MaskSelection(kind: .color, center: 0.06, range: 0.06,
                                                    softness: 0.05)

    /// A skin mask in the general vocabulary: the subject region, narrowed to skin hues — exactly
    /// what the old bespoke `type == "skin"` branch computed.
    public static func skin(id: String, adjustments: [String: Double],
                            refinement: MaskSelection = skinRefinement) -> Mask {
        Mask(id: id, type: "subject", source: "segmentation", invert: false, feather: 0,
             opacity: 1, adjustments: adjustments, refine: refinement)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        feather = try c.clampedDouble(.feather, default: 0, in: Ranges.unsigned100)
        opacity = try c.clampedDouble(.opacity, default: 1, in: Ranges.opacity)
        adjustments = try c.decodeIfPresent([String: Double].self, forKey: .adjustments) ?? [:]
        shape = try c.decodeIfPresent(MaskShape.self, forKey: .shape)
        stamps = try c.decodeIfPresent([BrushStamp].self, forKey: .stamps)
        selection = try c.decodeIfPresent(MaskSelection.self, forKey: .selection)
        refine = try c.decodeIfPresent(MaskSelection.self, forKey: .refine)
        tightness = try c.clampedOptionalDouble(.tightness, in: Ranges.unsigned100)

        // MIGRATION. A sidecar written before `refine` existed says `type: "skin"` and carries the
        // hue range in `selection`, because that is where the bespoke renderer branch looked. It
        // is rewritten into the general form here, on the way in, so exactly ONE shape of mask
        // ever reaches the renderer and an edit saved last week still renders identically.
        //
        // Done at decode rather than at render because a migration in the renderer is a special
        // case that never goes away — this one is over the moment the file is read.
        if type == "skin" {
            refine = refine ?? selection ?? Mask.skinRefinement
            selection = nil
            type = "subject"
            source = source ?? "segmentation"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, type, source, invert, feather, opacity, adjustments, shape, stamps, selection
        case tightness, refine
    }
}

/// A selection generated from the image itself: pixels within a colour (hue) or luminance range.
/// `center`, `range`, `softness` are all normalised 0…1 (hue is 0…1 around the wheel). Parametric,
/// so it serialises as numbers; the renderer bakes it into a colour cube.
public struct MaskSelection: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case color, luminance }
    public var kind: Kind
    public var center: Double
    public var range: Double
    public var softness: Double

    public init(kind: Kind, center: Double, range: Double = 0.08, softness: Double = 0.08) {
        self.kind = kind; self.center = center; self.range = range; self.softness = softness
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .color
        center = clamp(try c.decodeIfPresent(Double.self, forKey: .center) ?? 0.5, to: 0...1)
        range = clamp(try c.decodeIfPresent(Double.self, forKey: .range) ?? 0.08, to: 0...1)
        softness = clamp(try c.decodeIfPresent(Double.self, forKey: .softness) ?? 0.08, to: 0...1)
    }

    enum CodingKeys: String, CodingKey { case kind, center, range, softness }
}

/// One dab of the brush: a soft circle, normalised top-left origin. `radius` is a fraction of the
/// smaller image edge; `hardness` (0…1) sets how sharp the edge is. A stroke is many overlapping
/// stamps — still just numbers, so a brush mask serialises like everything else.
public struct BrushStamp: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var radius: Double
    public var hardness: Double

    public init(x: Double, y: Double, radius: Double, hardness: Double = 0.5) {
        self.x = x; self.y = y; self.radius = radius; self.hardness = hardness
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = clamp(try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5, to: 0...1)
        y = clamp(try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5, to: 0...1)
        radius = clamp(try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.08, to: 0.005...1)
        hardness = clamp(try c.decodeIfPresent(Double.self, forKey: .hardness) ?? 0.5, to: 0...1)
    }

    enum CodingKeys: String, CodingKey { case x, y, radius, hardness }
}

/// A parametric mask shape — all coordinates normalised (0…1), top-left origin, matching HealSpot.
/// Radial: a soft-edged ellipse around (cx, cy). Linear: a graduated edge through (cx, cy) at
/// `angle`, transitioning over `softness` — a graduated-ND filter.
public struct MaskShape: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case radial, linear }
    public var kind: Kind
    public var cx: Double
    public var cy: Double
    /// Radial: radius as a fraction of the smaller image edge. Ignored for linear.
    public var radius: Double
    /// Linear: gradient direction in degrees (0 = bright at top). Ignored for radial.
    public var angle: Double
    /// Edge softness (0…1 fraction of the smaller edge) — the feathered transition width.
    public var softness: Double

    public init(kind: Kind, cx: Double, cy: Double, radius: Double = 0.3, angle: Double = 0, softness: Double = 0.25) {
        self.kind = kind; self.cx = cx; self.cy = cy
        self.radius = radius; self.angle = angle; self.softness = softness
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .radial
        cx = clamp(try c.decodeIfPresent(Double.self, forKey: .cx) ?? 0.5, to: 0...1)
        cy = clamp(try c.decodeIfPresent(Double.self, forKey: .cy) ?? 0.5, to: 0...1)
        radius = clamp(try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.3, to: 0.01...2)
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        softness = clamp(try c.decodeIfPresent(Double.self, forKey: .softness) ?? 0.25, to: 0...1)
    }

    enum CodingKeys: String, CodingKey { case kind, cx, cy, radius, angle, softness }
}

/// Sharpen / noise reduction. 0…100 each. Applied by the renderer as a finishing pass
/// (noise reduction then output sharpening); all-zero is a no-op.
public struct Detail: Codable, Equatable, Sendable {
    public var sharpen: Double
    public var nrLuma: Double
    public var nrColor: Double

    public init(sharpen: Double, nrLuma: Double, nrColor: Double) {
        self.sharpen = sharpen; self.nrLuma = nrLuma; self.nrColor = nrColor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sharpen = try c.clampedDouble(.sharpen, default: 0, in: Ranges.unsigned100)
        nrLuma = try c.clampedDouble(.nrLuma, default: 0, in: Ranges.unsigned100)
        nrColor = try c.clampedDouble(.nrColor, default: 0, in: Ranges.unsigned100)
    }

    enum CodingKeys: String, CodingKey {
        case sharpen
        case nrLuma = "nr_luma"
        case nrColor = "nr_color"
    }
}

/// Crop/rotate/lens-correction. Not applied by the M1 renderer.
public struct Geometry: Codable, Equatable, Sendable {
    public var rotateDeg: Double
    public var crop: CropRect?
    public var lensCorrection: Bool

    public init(rotateDeg: Double, crop: CropRect?, lensCorrection: Bool) {
        self.rotateDeg = rotateDeg; self.crop = crop; self.lensCorrection = lensCorrection
    }

    enum CodingKeys: String, CodingKey {
        case rotateDeg = "rotate_deg"
        case crop
        case lensCorrection = "lens_correction"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rotateDeg = try c.decodeIfPresent(Double.self, forKey: .rotateDeg) ?? 0
        crop = try c.decodeIfPresent(CropRect.self, forKey: .crop)
        lensCorrection = try c.decodeIfPresent(Bool.self, forKey: .lensCorrection) ?? false
    }
}

/// Normalized crop rectangle (0…1 of image dimensions).
public struct CropRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}
