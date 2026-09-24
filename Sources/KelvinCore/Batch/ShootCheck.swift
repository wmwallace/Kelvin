import Foundation

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

        public init(_ s: ImageStatistics) {
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

        public init(brightness: Double, shadows: Double, highlights: Double, warmth: Double, tint: Double) {
            self.brightness = brightness; self.shadows = shadows; self.highlights = highlights
            self.warmth = warmth; self.tint = tint
        }

        func distance(to o: Signature) -> Double {
            let d = [brightness - o.brightness, shadows - o.shadows, highlights - o.highlights,
                     warmth - o.warmth, tint - o.tint]
            return d.reduce(0) { $0 + $1 * $1 }.squareRoot()
        }
    }

    /// Why a frame was picked, in words the sheet can show under it. Relative to the hero, because
    /// that is the frame the look was chosen on.
    public static func reason(for frame: Signature, hero: Signature) -> String {
        var found: [(Double, String)] = []
        let db = frame.brightness - hero.brightness
        if abs(db) >= 0.6 { found.append((abs(db) / 0.6, db < 0 ? "Much darker" : "Much brighter")) }
        let ds = frame.shadows - hero.shadows
        if abs(ds) >= 0.8 { found.append((abs(ds) / 0.8, ds > 0 ? "Mostly in shadow" : "Far less shadow")) }
        let dh = frame.highlights - hero.highlights
        if dh >= 0.5 { found.append((dh / 0.5, "Bright highlights")) }
        let dw = frame.warmth - hero.warmth
        if abs(dw) >= 0.6 { found.append((abs(dw) / 0.6, dw > 0 ? "Warmer light" : "Cooler light")) }
        let dt = frame.tint - hero.tint
        if abs(dt) >= 0.6 { found.append((abs(dt) / 0.6, dt > 0 ? "Magenta light" : "Green light")) }
        return found.max { $0.0 < $1.0 }?.1 ?? "Like the one you chose"
    }

    /// Up to `count` frames to preview, most different first. The hero is never among them — it is
    /// the frame the look was already seen on. Deterministic: ties break on input order.
    ///
    /// - Parameter minimumDistance: a frame closer than this to everything already picked adds
    ///   nothing a viewer would see, so the pick stops early rather than padding the sheet with
    ///   near-duplicates. A uniform shoot honestly yields one or two frames.
    public static func pick<ID: Hashable>(_ frames: [(id: ID, signature: Signature)], hero: ID,
                                          count: Int = 5, minimumDistance: Double = 0.35) -> [ID] {
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
