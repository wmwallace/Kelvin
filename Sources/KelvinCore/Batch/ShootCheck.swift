import Foundation
import CoreImage

/// Which frames of a shoot to show a look on BEFORE it is applied to all of them.
///
/// The sentence the product is built around ends "and the chosen one carries across the shoot" — and
/// until now the choice was made on one frame. A look chosen on a well-lit hero can be wrong for the
/// night end of the same shoot, and nobody finds that out until the export, when four hundred files
/// are on disk. The candidates are shown large so the choice is informed; this makes the SECOND half
/// of the sentence informed the same way: a handful of the shoot's frames, chosen to be as unlike the
/// hero and each other as the shoot allows, rendered large in the look about to be applied.
///
/// **Chosen by measurement, not by position.** Every fifth frame of a shoot is mostly the same
/// moment five times. What makes a look fail on a frame is the light it was shot in — how dark, how
/// much of it lives in the shadows, whether something is blown, the colour of the light — and those
/// are exactly what `ImageStatistics` measures. So each frame is placed in that space from a
/// thumbnail it already has, and the picks are the frames farthest from the hero and from each
/// other (greedy farthest-point sampling): the darkest, the brightest, the one against the light,
/// the odd colour — whichever of those this shoot actually contains.
///
/// Thumbnails, because the point is to answer before anything is decoded. The strip keeps a 160-px
/// thumbnail of every frame (`MediaCache`), and a histogram read on one is well inside what these
/// few numbers need.
public enum ShootCheck {

    /// The coordinates a frame is placed at. Each axis is scaled so that one unit is a difference a
    /// look visibly responds to, which is what makes a plain Euclidean distance meaningful across
    /// them.
    public struct Signature: Equatable, Sendable {
        public var brightness: Double
        public var shadows: Double
        public var highlights: Double
        public var warmth: Double
        public var tint: Double
        /// How much colour the frame has at all, 0 for a grey print (see `ShootCheck.colourfulness`).
        /// Named in the reasons and deliberately NOT in `distance`: which frames are picked is D31's
        /// policy, and this exists to stop a picked frame being mislabelled, not to change the pick.
        /// Nil when it was not measured.
        public var colourfulness: Double?

        public init(_ s: ImageStatistics, colourfulness: Double? = nil) {
            self.colourfulness = colourfulness
            // Median luma in stops relative to mid grey, so "twice as dark" is the same step
            // everywhere: 0.46 → 0.23 and 0.10 → 0.05 are both one stop.
            brightness = log2(max(0.01, s.medianLuma) / 0.46)
            // Share of the frame below 0.08 luma. 0.30 apart is night against day (D-exposure,
            // the 0.30 → 0.45 low-key ramp).
            shadows = s.shadowMass / 0.3
            // Clipping and a bright top end: a window, a sky, a lamp.
            highlights = min(1, s.highlightClip * 20) + max(0, s.whitePoint - 0.9) * 5
            // The light's colour, on the estimator the engine uses (`RecipeEngine.castChroma`).
            let cast = RecipeEngine.castChroma(s)
            warmth = cast.b / 12
            tint = cast.a / 12
        }

        public init(brightness: Double, shadows: Double, highlights: Double, warmth: Double, tint: Double,
                    colourfulness: Double? = nil) {
            self.brightness = brightness; self.shadows = shadows; self.highlights = highlights
            self.warmth = warmth; self.tint = tint; self.colourfulness = colourfulness
        }

        func distance(to o: Signature) -> Double {
            let d = [brightness - o.brightness, shadows - o.shadows, highlights - o.highlights,
                     warmth - o.warmth, tint - o.tint]
            return d.reduce(0) { $0 + $1 * $1 }.squareRoot()
        }
    }

    /// Mean per-pixel chroma — `max(r, g, b) − min(r, g, b)` over 8-bit sRGB, as a fraction of full
    /// scale — read on a thumbnail. A black-and-white file reads near zero whatever its brightness,
    /// which is the one thing none of the signature's other axes can see: its cast (`warmth`,
    /// `tint`) is zero, but so is a neutral colour frame's.
    ///
    /// Measured on the strip's thumbnails of the "Photography samples" folder: the two monochrome
    /// JPEGs read 0.016 and 0.024, every colour frame 0.13 – 0.41.
    public static func colourfulness(_ image: CIImage) -> Double? {
        let e = image.extent
        guard !e.isInfinite, e.width >= 1, e.height >= 1 else { return nil }
        let scale = min(1, 160 / max(e.width, e.height))
        let w = max(1, Int(e.width * scale)), h = max(1, Int(e.height * scale))
        guard let data = try? ImageWriter.rgba8Sampled(image, width: w, height: h) else { return nil }
        var sum = 0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: p.count - 3, by: 4) {
                let r = p[i], g = p[i + 1], b = p[i + 2]
                sum += Int(max(r, g, b) - min(r, g, b))
            }
        }
        return Double(sum) / Double(w * h) / 255
    }

    /// Below this a frame is black and white; above `colourAbove` it plainly has colour. The gap
    /// between them is where a foggy or pastel colour frame sits, and neither label is claimed there.
    static let monochromeBelow = 0.05
    static let colourAbove = 0.08

    /// A picked frame closer than this to everything already shown adds nothing a viewer would see.
    /// Shared by `pick` and `reason`, so a frame the picker chose as different is never labelled as
    /// alike.
    public static let minimumDistance = 0.35

    /// Why a frame was picked, in words the sheet can show under it. Relative to the hero, because
    /// that is the frame the look was chosen on.
    ///
    /// Every word here has to be true of the frame under it. The fallback used to be "Like the one
    /// you chose" whenever no single axis crossed its threshold — which is most of the frames a
    /// mixed folder yields, since the picker takes anything 0.35 away in COMBINED distance and a
    /// frame can be that far by being somewhat different in several ways at once. Reported on a
    /// black-and-white dog under a Natural chosen on a colour car. So: monochrome is named first,
    /// a difference past half its threshold is named in a milder word, and likeness is only claimed
    /// of a frame that is genuinely within the picker's own "adds nothing" distance.
    public static func reason(for frame: Signature, hero: Signature) -> String {
        if let f = frame.colourfulness, let h = hero.colourfulness {
            // First, because it is the first thing the eye sees and the one a colour look cannot
            // touch: vibrance and saturation do nothing to grey, and a grade only tints it.
            if f < monochromeBelow, h >= colourAbove { return "Black and white" }
            if h < monochromeBelow, f >= colourAbove { return "In colour" }
        }
        // (how far past its threshold, the word when it is past, the word when it is halfway there)
        var found: [(Double, String, String)] = []
        let db = frame.brightness - hero.brightness
        found.append((abs(db) / 0.6, db < 0 ? "Much darker" : "Much brighter",
                      db < 0 ? "A little darker" : "A little brighter"))
        let ds = frame.shadows - hero.shadows
        found.append((abs(ds) / 0.8, ds > 0 ? "Mostly in shadow" : "Far less shadow",
                      ds > 0 ? "More shadow" : "Less shadow"))
        let dh = frame.highlights - hero.highlights
        if dh > 0 { found.append((dh / 0.5, "Bright highlights", "Brighter highlights")) }
        let dw = frame.warmth - hero.warmth
        found.append((abs(dw) / 0.6, dw > 0 ? "Warmer light" : "Cooler light",
                      dw > 0 ? "Slightly warmer light" : "Slightly cooler light"))
        let dt = frame.tint - hero.tint
        found.append((abs(dt) / 0.6, dt > 0 ? "Magenta light" : "Green light",
                      dt > 0 ? "Slightly magenta light" : "Slightly green light"))
        if let top = found.max(by: { $0.0 < $1.0 }) {
            if top.0 >= 1 { return top.1 }
            if top.0 >= 0.5 { return top.2 }
        }
        return frame.distance(to: hero) < minimumDistance ? "Like the one you chose" : "Slightly different light"
    }

    /// Up to `count` frames to preview, most different first. The hero is never among them — it is
    /// the frame the look was already seen on. Deterministic: ties break on input order.
    ///
    /// - Parameter minimumDistance: a frame closer than this to everything already picked adds
    ///   nothing a viewer would see, so the pick stops early rather than padding the sheet with
    ///   near-duplicates. A uniform shoot honestly yields one or two frames.
    public static func pick<ID: Hashable>(_ frames: [(id: ID, signature: Signature)], hero: ID,
                                          count: Int = 5, minimumDistance: Double = ShootCheck.minimumDistance) -> [ID] {
        guard count > 0 else { return [] }
        let heroSignature = frames.first { $0.id == hero }?.signature
        let pool = frames.filter { $0.id != hero }
        guard !pool.isEmpty else { return [] }
        var chosen: [(id: ID, signature: Signature)] = []
        // Distance to the nearest of (hero + chosen). Without a hero signature, seed with the frame
        // farthest from the shoot's centre, so the first pick is still the most unusual frame.
        var anchors: [Signature] = heroSignature.map { [$0] } ?? []
        if anchors.isEmpty {
            let n = Double(pool.count)
            let centre = Signature(
                brightness: pool.map(\.signature.brightness).reduce(0, +) / n,
                shadows: pool.map(\.signature.shadows).reduce(0, +) / n,
                highlights: pool.map(\.signature.highlights).reduce(0, +) / n,
                warmth: pool.map(\.signature.warmth).reduce(0, +) / n,
                tint: pool.map(\.signature.tint).reduce(0, +) / n)
            anchors = [centre]
        }
        var remaining = pool
        while chosen.count < count, !remaining.isEmpty {
            var best = -1.0, bestIndex = 0
            for (i, f) in remaining.enumerated() {
                let d = anchors.map { f.signature.distance(to: $0) }.min() ?? 0
                if d > best { best = d; bestIndex = i }
            }
            if best < minimumDistance, !chosen.isEmpty || heroSignature != nil { break }
            let f = remaining.remove(at: bestIndex)
            chosen.append(f)
            anchors.append(f.signature)
        }
        return chosen.map(\.id)
    }
}
