import Foundation

/// Candidate generation from a frame's local measurements taken **as one value**.
///
/// `RecipeEngine.candidates` takes the four things `LocalMasks.measure` returns as four loose,
/// defaulted parameters, and every caller copies them across by hand. That is how D20's face-lift
/// cap came to exist only in the eval harness: `ShippedCandidates.compose` passed
/// `subjectLumaIsSkin`, the app's canvas and export did not, the flag defaulted to `false`, and the
/// product shipped the uncapped lift the decision record says it removed. Nothing failed, because
/// forgetting a defaulted argument is not an error.
///
/// These overloads make that mistake unrepresentable: hand over the `Measured` and every field of
/// it reaches the engine. Production callers go through here; `scripts/check-loose-masks.sh` fails
/// the build if one copies the fields across by hand again.
public extension RecipeEngine {

    /// Every style for a frame, with its local measurements passed whole.
    static func candidates(
        perception p: Perception,
        statistics s: ImageStatistics,
        masks m: LocalMasks.Summary,
        iso: Double? = nil,
        perceptionHash: String? = nil,
        generatedAt: String? = nil,
        focus: FocusMeasure.Reading? = nil
    ) -> [Recipe] {
        candidates(perception: p, statistics: s,
                   subjectLuma: m.subjectLuma, skyLuma: m.skyLuma, subjectOrigin: m.subjectOrigin,
                   iso: iso, perceptionHash: perceptionHash, generatedAt: generatedAt,
                   subjectLumaIsSkin: m.subjectLumaIsSkin, focus: focus)
    }

    /// One style for a frame, with its local measurements passed whole.
    static func candidate(
        perception p: Perception,
        statistics s: ImageStatistics,
        style: CandidateStyle,
        masks m: LocalMasks.Summary,
        iso: Double? = nil,
        focus: FocusMeasure.Reading? = nil
    ) -> Recipe {
        candidate(perception: p, statistics: s, style: style,
                  subjectLuma: m.subjectLuma, skyLuma: m.skyLuma, subjectOrigin: m.subjectOrigin,
                  iso: iso, subjectLumaIsSkin: m.subjectLumaIsSkin, focus: focus)
    }
}

public extension LocalMasks {

    /// The scalar half of `Measured`: everything the engine reads, without the bitmaps.
    ///
    /// Split out because the app keeps a frame's measurements in its session cache long after the
    /// bitmaps have been rescaled onto the edit proxy, and a restored frame has to regenerate
    /// exactly what the first open did. Carrying this one value, rather than four fields that
    /// each have to be remembered, is what keeps the two in step.
    struct Summary: Sendable, Equatable {
        public let subjectLuma: Double?
        public let skyLuma: Double?
        public let subjectOrigin: SubjectMask.Origin?
        public let subjectLumaIsSkin: Bool

        public init(subjectLuma: Double?, skyLuma: Double?,
                    subjectOrigin: SubjectMask.Origin?, subjectLumaIsSkin: Bool) {
            self.subjectLuma = subjectLuma
            self.skyLuma = skyLuma
            self.subjectOrigin = subjectOrigin
            self.subjectLumaIsSkin = subjectLumaIsSkin
        }

        /// Nothing measured: no subject, no sky. What the engine sees for a frame Vision found
        /// nothing in.
        public static let none = Summary(subjectLuma: nil, skyLuma: nil,
                                         subjectOrigin: nil, subjectLumaIsSkin: false)
    }
}

public extension LocalMasks.Measured {
    var summary: LocalMasks.Summary {
        .init(subjectLuma: subjectLuma, skyLuma: skyLuma,
              subjectOrigin: subjectOrigin, subjectLumaIsSkin: subjectLumaIsSkin)
    }
}
