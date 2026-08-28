import Foundation

/// Which candidate a photograph *opens* in, decided from the frame's own measured light.
///
/// The opener has always been a constant: `CandidateCurator.select` iterates in engine order,
/// Natural is index 0 and exempt from the quality floor, so `engine-default` is `engine-natural`
/// on every frame, structurally (docs/EVALUATION.md, "The opener is a constant"). The harness
/// measured what that costs: picking the right candidate is worth **0.61 ΔE** against 0.10 for
/// any roster change — the single largest measured lever on the table.
///
/// `pick-probe` then measured what a chooser could actually read, and the answer is **shadow
/// structure and nothing else**: a frame with more, deeper shadow is one where the photographer
/// pulled contrast down (Soft wins); a frame with lifted blacks and little shadow is one where
/// Natural was already right. `shadowRegion` separates the two groups at AUC 0.714 on the paired
/// corpus and 0.657 on the degradation corpus; `shadowMass` at 0.669 / 0.680. It replicates in
/// direction and rough magnitude on both corpora, and it is a property of the *frame*, not of the
/// user — which is why it belongs here, in the engine, where every decision is computed from a
/// measurement (D18, "What replaces it").
///
/// The owner's ruling (D18) sets the shape of this rule exactly:
///
///   * a photograph **may** open in something other than Natural,
///   * but only **above a margin calibrated on the harness**,
///   * and only if the app **says on screen that it chose**.
///
/// The first point is the rule below. The second is why `configuration` ships **disabled**: the
/// evidence so far is 63 usable frames from one photographer — enough to know the signal exists,
/// not enough to calibrate a margin on (docs/EVALUATION.md says so in as many words). The floors
/// here are starting points for that calibration, not calibrated values; `kelvin-cli opener-probe`
/// prices any floor pair against an existing eval report without a re-render, and an
/// `KELVIN_OPENER=soft kelvin-cli eval …` run confirms the winner end to end. Flipping the default
/// on is the owner's decision, made on that evidence, in a change that cites it. The third point
/// is the caller's job: `ShippedCandidates.Composition.openedByMeasurement` says when this rule
/// chose, and the app turns that into a visible sentence.
///
/// **This does not touch what the model emits or what the engine computes** — every candidate is
/// generated exactly as before. It decides only which of the already-curated set is shown first,
/// and only when nothing else has a claim: a hand edit, a per-frame override and the shoot's look
/// all outrank it (D13's precedence rule; this rule is a refinement of step 4, the engine's own
/// ranking). If the suggested style was culled or dropped for this frame, curation wins and the
/// photograph opens in Natural, exactly as today.
public enum OpeningRule {

    /// The rule's tunables, separated from the environment so tests and sweeps can pass a
    /// configuration explicitly instead of mutating process state.
    public struct Configuration: Equatable, Sendable {
        /// The style the rule may open into. **Nil is disabled** — the shipped default until the
        /// floors are calibrated on a corpus that can bear the weight. When set, the rule may
        /// suggest exactly this one style; a per-style table is deliberately not offered, because
        /// the only separation the harness has found is Natural-vs-Soft and a rule with more knobs
        /// than evidence is how the halo discriminator died.
        public var styleID: String?

        /// Floor on `ImageStatistics.shadowRegion` — how much of the frame lives below 0.20 luma.
        /// Measured means on the paired corpus: 0.196 where Natural won, 0.255 where Soft won.
        public var shadowRegionFloor: Double

        /// Floor on `ImageStatistics.shadowMass` — how much of the frame is below 0.08 luma, dark
        /// enough that detail is unreadable. Measured means: 0.027 (Natural) vs 0.050 (Soft).
        public var shadowMassFloor: Double

        public init(styleID: String?, shadowRegionFloor: Double, shadowMassFloor: Double) {
            self.styleID = styleID
            self.shadowRegionFloor = shadowRegionFloor
            self.shadowMassFloor = shadowMassFloor
        }
    }

    /// The environment's configuration. `KELVIN_OPENER` names the style ("soft"); unset, empty,
    /// "0" or "off" disables the rule, and disabled is the default. `KELVIN_OPENER_REGION` and
    /// `KELVIN_OPENER_MASS` move the floors. Env-overridable and in `RecipeEngine.tuningSignature`
    /// for the same reason the sky lever is: the floors are there to be swept, and a cache that
    /// did not notice them would serve the previous arm's answers.
    ///
    /// The default floors sit **above** the Soft-group means (0.255 / 0.050), so an enabled but
    /// otherwise-untuned rule fires only on frames deeper in shadow than the average frame Soft
    /// already won — conservative by construction, in the same spirit as `faceLiftCapEV`: where
    /// the evidence is thinnest, commit least.
    public static var configuration: Configuration {
        let env = ProcessInfo.processInfo.environment
        let raw = env["KELVIN_OPENER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let style: String?
        if let raw, !raw.isEmpty, raw != "0", raw != "off" {
            style = raw
        } else {
            style = nil
        }
        return Configuration(
            styleID: style,
            shadowRegionFloor: env["KELVIN_OPENER_REGION"]
                .flatMap(Double.init).map { min(1.0, max(0.0, $0)) } ?? 0.30,
            shadowMassFloor: env["KELVIN_OPENER_MASS"]
                .flatMap(Double.init).map { min(1.0, max(0.0, $0)) } ?? 0.06
        )
    }

    /// The style this frame's measured light suggests opening in, or nil for "Natural, as always".
    ///
    /// Both floors must be met, which is the margin: one statistic near its threshold is a coin
    /// flip, and the finding was always the two together — more shadow *and* deeper shadow. The
    /// statistics are the **source frame's**, measured on the perception proxy, because a chooser
    /// only ever sees the unedited photograph (`pick-probe` measures the same way).
    public static func suggestion(for statistics: ImageStatistics,
                                  given config: Configuration = configuration) -> String? {
        guard let style = config.styleID else { return nil }
        guard statistics.shadowRegion >= config.shadowRegionFloor,
              statistics.shadowMass >= config.shadowMassFloor else { return nil }
        return style
    }

    /// This rule's contribution to `RecipeEngine.tuningSignature`. Constant while disabled, so
    /// sweeping the floors with the rule off cannot thrash anyone's resolved-recipe cache.
    public static func signature(for config: Configuration = configuration) -> String {
        guard let style = config.styleID else { return "off" }
        return "\(style)@\(config.shadowRegionFloor)/\(config.shadowMassFloor)"
    }
}
