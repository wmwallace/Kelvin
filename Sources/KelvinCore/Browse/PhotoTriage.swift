import Foundation
import CoreImage

/// A cheap, offline first pass over a whole shoot: which frames are the same picture taken more
/// than once, and the very short list of faults a histogram can state as fact.
///
/// **This is a separate pass from the focus scan, on purpose.** That scan costs ~85 ms/photo on a
/// JPEG because it does exactly one thing — a Laplacian and a gradient over a 1200 px proxy — and it
/// can run several photos at once because nothing in it touches Vision. Folding staging into it
/// would have cost both properties at once: Vision crashes when two of its requests race (see the
/// commit "Vision passes go back to serial"), so anything using it must serialise. Triage therefore
/// re-uses the same proxy and adds only arithmetic. Measured on one 1200 px proxy: the focus grid
/// costs 46.7 ms, the histogram 10.0 ms and the fingerprint 2.1 ms, so triage is the focus scan plus
/// about a quarter, and it parallelises exactly as well.
///
/// **NOTHING HERE IS A REJECTION.** Every output is a prompt to look, never a decision. That is a
/// product rule, not a stylistic one: an automatic cull is only as good as its worst false positive,
/// and a false positive you were never shown cannot be discovered. There is no `reject` case, no
/// score, and no ranking. The one flag a photographer sets stays theirs.
///
/// ## What survived contact with real photographs
///
/// The first version of this file had seven concerns. Four of them were removed after measuring
/// **836 real frames** — a 437-frame RAW shoot and a 399-frame JPEG shoot, both the owner's, both
/// culled and kept — because every one of them fired on photographs the photographer had kept:
///
///   * **"no tonal range"** (dynamic range < 0.25) fired on 15 frames of the JPEG shoot. All 15 were
///     the same subject: a bald eagle, and later a kite, against a flat overcast sky. That is a
///     genre, not a fault, and it is the same failure `FocusMeasure` documents at length for fog —
///     a low-contrast scene is not a broken one.
///   * **"blown highlights"** (>12% of the frame at 254+) fired on 6 JPEG frames and 5 RAW ones. The
///     JPEG frames are backlit beach portraits against a bright overcast sky, which is what most
///     outdoor portraits look like. Clipping cannot distinguish a blown *sky* from a blown *subject*
///     without knowing what is in the frame — and that is exactly the Vision-shaped judgement this
///     pass is forbidden to make.
///   * **"blocked shadows"** (>35% of the frame below 0.08 luma) fired on 3 RAW frames. The worst,
///     at 36.6%, is a deliberate near-silhouette: two gulls on a dark headland against grey sky.
///
/// What is left is the small set of faults a histogram states without interpreting: nothing in the
/// frame resolved, and the exposure landed so far off that there is no picture to recover. Both are
/// two-condition tests, because every single-number version of them condemned a good photograph.
///
/// The finding worth carrying forward is that **tone is not a fault, it is a choice** — right up
/// until the point where nothing is recorded at all.
public enum PhotoTriage {

    // MARK: - Concerns

    /// One measurable, named observation about a frame. Never a verdict on the photograph.
    ///
    /// `CaseIterable` so a UI legend can enumerate what exists rather than hard-code a list that
    /// drifts — the same reason `AestheticEvaluator.Issue` is.
    public enum Concern: String, Sendable, Equatable, CaseIterable {
        /// Nothing in the frame resolved crisply enough to be worth editing.
        case outOfFocus
        /// Soft, but not hopeless — the borderline tier of the same measurement.
        case softFocus
        /// Dark enough that most of the frame carries no readable detail at all.
        case veryDark
        /// Bright enough that a large part of the frame is pinned at pure white.
        case veryBright

        /// Shown to the user. Phrased as an observation, because that is what it is — no
        /// imperative, no "should", nothing that reads as a decision already taken.
        public var message: String {
            switch self {
            case .outOfFocus: return "nothing came out sharp"
            case .softFocus:  return "looks soft"
            case .veryDark:   return "very dark — most of the frame has no detail"
            case .veryBright: return "very bright — much of the frame is pure white"
            }
        }

        /// Whether an edit can plausibly bring this back.
        ///
        /// Focus cannot be undone: detail that was never recorded is gone, and sharpening a soft
        /// frame only makes a crunchier soft frame (`FocusMeasure`'s opening note). Exposure at this
        /// extreme cannot be undone either in an 8-bit file — though a RAW carries headroom this
        /// measurement, taken on an sRGB proxy, cannot see. That uncertainty is one more reason
        /// every one of these stays a prompt to look rather than anything stronger.
        public var editCanRecover: Bool { false }
    }

    // MARK: - Thresholds
    //
    // Measured against 836 real frames from two of the owner's shoots: 437 RAW (a headland, mixed
    // weather, wildlife) and 399 JPEG (a beach day, people, birds, bright overcast). The design rule
    // is `FocusMeasure`'s: a false alarm costs far more than a miss, because a staging pass that
    // cries wolf gets switched off and then catches nothing at all. Every threshold below sits past
    // the most extreme frame either shoot produced, and the measured extreme is quoted beside it.

    /// Median luma below which the frame is called very dark, *and* the fraction of the frame that
    /// must additionally be unreadable for the call to be made.
    ///
    /// BOTH, because a single brightness number cannot tell a mistake from a style. A night shot, a
    /// silhouette and a low-key portrait are all legitimately dark. What is not a style is a frame
    /// whose midpoint is near black *and* where more than half the picture sits below the level
    /// detail survives at (`shadowMass`, 0.08 luma): there is no subject left to recover.
    ///
    /// Measured: the darkest frame across both shoots read median 0.144, and the highest shadow mass
    /// was 0.366 — a deliberate near-silhouette of gulls on a headland, which fails the median test
    /// comfortably. Neither shoot has a frame that satisfies both conditions, which is the point.
    static let veryDarkMedian = 0.10
    static let veryDarkMass = 0.55

    /// The bright mirror, and it needs the pair for the same reason: a high-key portrait on white
    /// and a snow scene both meter bright without anything being wrong.
    ///
    /// This threshold moved after measurement and the reason is worth keeping. It was first set at
    /// median 0.82 / clip 0.20, which fired on `IMG_1759` — a portrait against a bright overcast sky,
    /// median 0.840 with 20.7% of the frame clipped. That is an ordinary backlit beach portrait and
    /// flagging it is precisely the false alarm this pass cannot afford. The measured extremes across
    /// both shoots are median 0.866 and clip 0.280 (different frames), so the pair sits past both.
    static let veryBrightMedian = 0.88
    static let veryBrightClip = 0.40

    // MARK: - Verdict

    /// Everything triage knows about one frame. The raw readings travel with the concerns so a UI
    /// can show the number behind a flag rather than only the flag — this codebase's standing
    /// complaint about automatic judgements is that they are unfalsifiable, and a flag you can click
    /// through to a measurement is not.
    public struct Verdict: Sendable, Equatable {
        /// Ordered worst-first and deduplicated. Empty means nothing measurable is wrong, which is
        /// emphatically NOT the same as "this is a good photograph".
        public let concerns: [Concern]
        public let focus: FocusMeasure.Reading
        public let statistics: ImageStatistics
        public let signature: Signature

        /// True when there is something worth a second look. There is deliberately no opposite
        /// property called `isRejected`, and there should never be one.
        public var needsReview: Bool { !concerns.isEmpty }

        /// One line for a filmstrip badge or a tooltip.
        public var summary: String {
            concerns.isEmpty ? "no measured faults" : concerns.map(\.message).joined(separator: ", ")
        }
    }

    /// Apply the rules above. Split out from the I/O so the whole decision surface is a pure
    /// function of two measurements and can be tested against numbers taken from real photographs
    /// without needing the photographs.
    public static func concerns(for s: ImageStatistics, focus: FocusMeasure.Reading) -> [Concern] {
        var found: [Concern] = []

        // Focus leads: it is the one fault no edit repairs. One tier only — reporting "soft" as well
        // as "not sharp" states one measurement twice.
        if focus.isUnusable { found.append(.outOfFocus) }
        else if focus.isSoft { found.append(.softFocus) }

        if s.medianLuma < veryDarkMedian && s.shadowMass > veryDarkMass { found.append(.veryDark) }
        if s.medianLuma > veryBrightMedian && s.highlightClip > veryBrightClip {
            found.append(.veryBright)
        }
        return found
    }

    // MARK: - Reading a frame

    /// Long edge of the proxy every measurement here is taken on. 1200 because that is what the
    /// focus scan already uses and what `FocusMeasure`'s soft/unusable thresholds were calibrated
    /// against; changing it would silently move every focus verdict in the app.
    public static let proxyEdge = 1200

    /// Triage one already-decoded proxy. Pure apart from rasterising the sample grids.
    ///
    /// Pass the **proxy**, not the full-resolution original — consistency between frames matters
    /// more than absolute scale, and every frame goes through the same proxy.
    public static func read(_ proxy: CIImage) -> Verdict? {
        guard let statistics = try? ImageStatistics.compute(proxy) else { return nil }
        let focus = FocusMeasure.read(proxy)
        return Verdict(concerns: concerns(for: statistics, focus: focus),
                       focus: focus,
                       statistics: statistics,
                       signature: signature(of: proxy) ?? .unmeasurable)
    }

    /// Triage one file. **Proxy-first** (non-negotiable #4), and specifically via ImageIO's
    /// decode-to-size, which on a 60 MP JPEG costs 120 ms against 2017 ms for decoding the whole
    /// frame and discarding 98% of it.
    ///
    /// RAW has no such path and never will: ImageIO would answer a RAW file with the camera
    /// manufacturer's embedded preview instead of Apple's decode (see `PerceptionProxy.fromFile`).
    /// So RAW pays for a real decode, and the result is materialised once rather than re-rendered by
    /// each of the three sample grids below. Measured, that difference dominates everything else
    /// here: 14 ms/photo wall on a 399-frame JPEG shoot against 1170 ms/photo on a 437-frame RAW one.
    ///
    /// Returns nil for a file that cannot be read. **Nil is not a fault** — a caller must treat it as
    /// "no opinion", exactly as `FocusMeasure` treats a frame it could not measure.
    ///
    /// Safe to run several at once: nothing in this path touches Vision.
    public static func read(url: URL, fastRAW: Bool = true) -> Verdict? {
        // `measurementProxy` also accepts a RAW file's embedded preview, which `fromFile` refuses.
        // For measurement that is the right trade — see its documentation — and it is the difference
        // between six minutes and thirty seconds on a RAW shoot. `fastRAW: false` forces the slow,
        // fully-decoded path, which is what `triage-compare` uses as its reference.
        if let fast = fastRAW ? PerceptionProxy.measurementProxy(url, maxEdge: proxyEdge)
                              : PerceptionProxy.fromFile(url, maxEdge: proxyEdge) {
            return read(fast)
        }
        guard let full = try? ImageDecoder.decode(url: url) else { return nil }
        let scaled = PerceptionProxy.downsample(full, maxEdge: proxyEdge)
        guard let cg = ImageWriter.exportContext.createCGImage(scaled, from: scaled.extent)
        else { return read(scaled) }
        return read(CIImage(cgImage: cg))
    }

    // MARK: - Near-duplicate signature

    /// A 64-bit perceptual fingerprint of a frame, plus enough context to know when not to trust it.
    ///
    /// This is a **difference hash**: the frame is reduced to a 9×8 grid of luma and each bit records
    /// whether a cell is brighter than the one to its right. Two properties make it right here, and
    /// both were measured rather than assumed:
    ///
    ///  * **It ignores exposure.** Brightening a photograph scales every cell, and scaling cannot
    ///    change which of two neighbours is larger. Measured on seven real photographs at 1200 px,
    ///    pushing ±1 EV moved the fingerprint by 0–3 bits of 64, and applying a full look (contrast
    ///    ×1.25, saturation ×1.4, brightness +0.08) moved it by 0–4. An absolute-level hash — every
    ///    cell against the frame mean — does not survive that, which is why this is not one.
    ///  * **It is only a 9×8 grid.** Grain, focus and small subject movement do not register;
    ///    composition does. Across the same seven photographs all 21 cross-pairs sat 24–40 bits
    ///    apart, mean 32, which is what theory predicts: between unrelated frames every bit is a
    ///    coin flip.
    ///
    /// It is a *composition* fingerprint and nothing more. It cannot say which of two near-identical
    /// frames is the better photograph, and no part of this file pretends otherwise.
    public struct Signature: Sendable, Equatable, Hashable {
        public let bits: UInt64
        /// Mean absolute difference between horizontally adjacent cells of the 9×8 grid — how much
        /// signal the bits were actually derived from.
        ///
        /// A difference hash of a featureless frame is decided by rounding, so two identical blank
        /// frames can hash 30 bits apart while two unrelated blanks hash 2 apart: not merely weak,
        /// actively misleading. This is what lets grouping refuse to answer instead of guessing, the
        /// same way `FocusMeasure.measurable` does.
        public let contrast: Double

        public init(bits: UInt64, contrast: Double) {
            self.bits = bits
            self.contrast = contrast
        }

        /// Nothing to fingerprint. Never groups with anything, including another one of itself.
        public static let unmeasurable = Signature(bits: 0, contrast: 0)

        /// Below this the grid is flat enough that the bit signs are rounding noise.
        ///
        /// 0.004 is one 8-bit level (1/255) on the 0…1 luma scale — the quantisation floor of the
        /// samples themselves, so nothing below it can carry information. The margin is real but
        /// slim and worth stating: over the 836 measured frames the LOWEST contrast any of them
        /// produced was 0.0089, about two levels, on a bald eagle against flat overcast sky. Those
        /// frames still grouped correctly, so the floor is not silencing them — but a frame near it
        /// is exactly the frame whose grouping deserves suspicion.
        public static let contrastFloor = 0.004

        /// Whether the fingerprint carries enough signal to be compared at all.
        public var isMeasurable: Bool { contrast >= Signature.contrastFloor }

        /// Hamming distance: how many of the 64 comparisons two frames disagree on.
        public func distance(to other: Signature) -> Int { (bits ^ other.bits).nonzeroBitCount }
    }

    /// 9 columns because 8 horizontal comparisons per row over 8 rows is what makes 64 bits.
    static let hashColumns = 9
    static let hashRows = 8
    /// Each grid cell is box-averaged from an 8×8 block rather than point-sampled, so one bright
    /// speck cannot decide a bit. Sampling straight down to 9×8 would alias.
    static let hashOversample = 8

    /// Fingerprint a frame. Returns nil only if the image cannot be rasterised at all.
    public static func signature(of image: CIImage) -> Signature? {
        let w = hashColumns * hashOversample, h = hashRows * hashOversample
        guard let data = try? ImageWriter.rgba8Sampled(image, width: w, height: h) else { return nil }

        var cells = [Double](repeating: 0, count: hashColumns * hashRows)
        data.withUnsafeBytes { dp in
            let px = dp.bindMemory(to: UInt8.self)
            for cy in 0..<hashRows {
                for cx in 0..<hashColumns {
                    var sum = 0.0
                    for y in (cy * hashOversample)..<((cy + 1) * hashOversample) {
                        for x in (cx * hashOversample)..<((cx + 1) * hashOversample) {
                            let o = (y * w + x) * 4
                            // Rec.601, matching every other luma in this project, so "brighter"
                            // means here what it means in the histogram.
                            sum += 0.299 * Double(px[o]) + 0.587 * Double(px[o + 1])
                                 + 0.114 * Double(px[o + 2])
                        }
                    }
                    cells[cy * hashColumns + cx] = sum / Double(hashOversample * hashOversample * 255)
                }
            }
        }

        var bits: UInt64 = 0
        var spread = 0.0
        var bit = 0
        for cy in 0..<hashRows {
            for cx in 0..<(hashColumns - 1) {
                let left = cells[cy * hashColumns + cx]
                let right = cells[cy * hashColumns + cx + 1]
                if left > right { bits |= (1 << UInt64(bit)) }
                spread += abs(left - right)
                bit += 1
            }
        }
        return Signature(bits: bits, contrast: spread / Double(bit))
    }

    // MARK: - Grouping

    /// One frame's worth of input to `groups`. `captured` is optional and its absence is a normal
    /// state, not an error — a scan, an export with the EXIF stripped, or simply the moment before
    /// the background date read has landed. Without it the frame is grouped on looks alone, which
    /// is the conservative rule.
    public struct Frame: Sendable, Equatable {
        public let url: URL
        public let signature: Signature
        public let captured: Date?
        public init(url: URL, signature: Signature, captured: Date? = nil) {
            self.url = url
            self.signature = signature
            self.captured = captured
        }
    }

    /// Hamming distance at or below which two frames are the same picture on looks alone.
    ///
    /// Kept tight because the fingerprint alone cannot be trusted further than this. Real evidence:
    /// ±1 EV and a full look move a fingerprint by at most 4 bits, while unrelated photographs sit
    /// 24–40 apart. But the gap between those two populations is *not* empty on a real shoot — the
    /// consecutive-frame distances of a 437-frame RAW shoot form a smooth continuum from 0 to 43
    /// with no natural break — so this is a judgement about cost, not a discovered boundary. A
    /// missed pair leaves two frames side by side in the strip, which is where they were anyway. A
    /// wrong pair collapses two different photographs into one row and hides one of them.
    public static let nearDuplicateDistance = 10

    /// The looser distance allowed between frames taken moments apart, and the gap that counts as
    /// "moments".
    ///
    /// THE FINGERPRINT ALONE HAS POOR RECALL ON THE CASE CULLING CARES ABOUT MOST, and this is the
    /// fix. Measured on the 399-frame beach shoot: of consecutive frames shot within 2 seconds of
    /// each other, only 17% were within 10 bits — the median was 21. Inspecting them shows why, and
    /// that the hash is not at fault: two frames of the same person on the same beach two seconds
    /// apart, differing only in where he put his arm, measure 22 bits apart, because a subject
    /// filling the frame occupies a large share of a 9×8 grid. They are unmistakably the same
    /// picture to a photographer and unmistakably different to the hash.
    ///
    /// Capture time is the cheap second signal that closes the gap, and it is already read for the
    /// filmstrip's ordering. The rule is: a frame joins a group either by looking very alike
    /// (`nearDuplicateDistance`), or by arriving within `burstGap` of that group's most recent frame
    /// AND looking alike enough (`burstDistance`).
    ///
    /// Both numbers were set by inspecting the pairs each admits:
    ///
    ///   * **18 bits.** At 24 the rule merged a headland with two people on a beach, and a kite in
    ///     the sky with two people on a beach — 2 of 6 sampled pairs were plainly wrong. At 18, all
    ///     8 sampled pairs were correct (the same eagle a second later, the same group portrait
    ///     mid-shuffle). The wrong merges lived between 20 and 24, so 18 is under them.
    ///   * **8 seconds.** 55% of that shoot's consecutive intervals are under 2 s and 83% under 8 s;
    ///     8 s is a working photographer's cadence within one setup, and the gap is measured against
    ///     the group's most recent frame so a long burst chains through it while a return to the
    ///     same spot ten minutes later does not.
    ///
    /// Effect on the 399-frame shoot: 331 groups → 273, and frames placed in a group of more than
    /// one 100 → 197. Two of the largest groups were checked frame by frame and are correct.
    public static let burstDistance = 18
    public static let burstGap: TimeInterval = 8

    /// Partition a shoot into groups of the same picture.
    ///
    /// **Every input appears in exactly one output group**, singletons included, and input order is
    /// preserved both between groups and inside them. A complete partition rather than "here are the
    /// duplicates", because the filmstrip has to draw the whole shoot either way; a caller that
    /// wants only the clusters filters on `count > 1`.
    ///
    /// Each frame is compared against the **seed** of each existing group — the frame that started it
    /// — never against every member. That is deliberate. Comparing against all members is
    /// single-linkage clustering, where A resembles B and B resembles C chains A to C even when A and
    /// C share nothing, and a slow pan across a landscape would swallow a whole shoot into one row
    /// with one thumbnail standing for all of it. Seeding bounds every group to one composition's
    /// worth of drift. (The time half of the rule is the one exception, and it is measured against
    /// the group's most recent frame rather than its seed, so a long burst stays together in time
    /// while still having to look like its seed.)
    ///
    /// Cost is O(frames × groups) 64-bit XORs — under half a million integer operations for a
    /// 437-frame shoot, which is free next to reading a single file header.
    ///
    /// **Pass the shoot in capture order** (`PhotoOrder.sorted`). Grouping is order-dependent by
    /// construction: a different order seeds different groups. Time order makes the seed the first
    /// frame of a burst, which is the frame a photographer expects to stand for it, and it is what
    /// the time half of the rule assumes.
    public static func groups(_ frames: [Frame],
                              within limit: Int = nearDuplicateDistance,
                              burstWithin: Int = burstDistance,
                              burstGap gap: TimeInterval = burstGap) -> [[URL]] {
        var seeds: [Signature] = []
        var members: [[URL]] = []
        var latest: [Date?] = []

        for frame in frames {
            // A fingerprint with no signal in it is not compared to anything — see `contrastFloor`.
            // It becomes its own group, which is the honest answer: unknown, not unique.
            guard frame.signature.isMeasurable else {
                seeds.append(.unmeasurable)
                members.append([frame.url])
                latest.append(frame.captured)
                continue
            }
            var best = -1
            var bestDistance = Int.max
            for (i, seed) in seeds.enumerated() where seed.isMeasurable {
                let d = frame.signature.distance(to: seed)
                guard d < bestDistance else { continue }
                var admissible = d <= limit
                if !admissible, d <= burstWithin,
                   let mine = frame.captured, let theirs = latest[i] {
                    admissible = abs(mine.timeIntervalSince(theirs)) <= gap
                }
                if admissible { best = i; bestDistance = d }
            }
            if best >= 0 {
                members[best].append(frame.url)
                if let captured = frame.captured { latest[best] = captured }
            } else {
                seeds.append(frame.signature)
                members.append([frame.url])
                latest.append(frame.captured)
            }
        }
        return members
    }
}
