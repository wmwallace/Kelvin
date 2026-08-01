import Foundation
// @preconcurrency because CoreImage's Sendable annotations differ by SDK: on the macOS 27
// SDK CIImage is Sendable and this is a no-op, while on the SDK shipped with Xcode 16 —
// which is what CI runs — it is not, and Swift 6 mode rejects the stored properties below.
// Without this the project builds on the author's Mac and fails for everybody else.
@preconcurrency import CoreImage

/// One place that segments an image into the local masks the pipeline understands (subject, sky,
/// and their derived complement, background) and measures each region's mean luminance. Both the
/// numbers the *engine* needs to size a local correction (`subjectLuma`, `skyLuma`,
/// `backgroundLuma`) and the bitmaps the *renderer* needs to apply it come from the same pass —
/// so the app, the CLI, and batch never drift in how a mask is produced.
public enum LocalMasks {

    public struct Measured: Sendable {
        /// Keyed by mask `id`/`type` ("subject", "sky", "background"); ready for
        /// `Renderer.render(_:with:maskBitmaps:)`.
        public let bitmaps: [String: CIImage]
        public let subjectLuma: Double?
        public let skyLuma: Double?
        /// Mean luma under the derived background mask — the frame minus subject minus sky.
        public let backgroundLuma: Double?
        /// What produced the subject mask — Vision's person segmentation, or the generic
        /// salient-object fallback. Nil when there is no subject.
        ///
        /// Carried alongside the luma because the engine needs both to justify a lift: the luma says
        /// whether the subject *wants* recovering, and the origin says whether the thing under the
        /// mask is the thing the perception read was talking about. See `RecipeEngine.subjectMask`.
        public let subjectOrigin: SubjectMask.Origin?

        public init(bitmaps: [String: CIImage], subjectLuma: Double?, skyLuma: Double?,
                    subjectOrigin: SubjectMask.Origin? = nil, backgroundLuma: Double? = nil) {
            self.bitmaps = bitmaps
            self.subjectLuma = subjectLuma
            self.skyLuma = skyLuma
            self.subjectOrigin = subjectOrigin
            self.backgroundLuma = backgroundLuma
        }
    }

    /// Segment subject + sky once and measure them. Missing regions are simply absent (nil luma,
    /// no bitmap), which the engine reads as "nothing local to do here".
    public static func measure(in image: CIImage) -> Measured {
        var bitmaps: [String: CIImage] = [:]
        var subjectLuma: Double?
        var skyLuma: Double?
        var subjectOrigin: SubjectMask.Origin?

        if let found = SubjectMask.subjectWithOrigin(in: image) {
            let subject = found.mask
            bitmaps["subject"] = subject
            subjectOrigin = found.origin
            subjectLuma = SubjectMask.maskedMeanLuma(image: image, mask: subject)
            // Prefer metered skin brightness when a face is present: it's what the subject-lift
            // decision actually cares about, and metering (not classifying) skin keeps the
            // recovery tone-fair. The whole-person mask still carries the lift.
            let face = FaceSkin.read(in: image)
            if let skin = face.skinLuma { subjectLuma = skin }
        }
        if var sky = SkyMask.detect(in: image) {
            // Subtract the subject from the sky so sky adjustments never touch a person standing
            // against it — otherwise their bright hair/shoulders, poking into the upper frame,
            // could be caught by the sky mask and get the wrong local edit. sky ← sky × (1−subject).
            if let subject = bitmaps["subject"] {
                let notSubject = subject.applyingFilter("CIColorInvert")
                sky = sky.applyingFilter("CIMultiplyCompositing",
                                         parameters: [kCIInputBackgroundImageKey: notSubject])
                          .cropped(to: image.extent)
            }
            bitmaps["sky"] = sky
            skyLuma = SubjectMask.maskedMeanLuma(image: image, mask: sky)
        }

        // The rest of the frame. Always present, so a recipe mask of `type: "background"` renders
        // with no renderer or engine change the moment it is asked for. Deriving it is a pure CI
        // graph — nothing is evaluated here; the only forced evaluation added to this pass is the
        // small sampled reduction inside `maskedMeanLuma`.
        let background = background(subject: bitmaps["subject"], sky: bitmaps["sky"],
                                    extent: image.extent)
        bitmaps["background"] = background
        let backgroundLuma = SubjectMask.maskedMeanLuma(image: image, mask: background)

        return Measured(bitmaps: bitmaps, subjectLuma: subjectLuma, skyLuma: skyLuma,
                        subjectOrigin: subjectOrigin, backgroundLuma: backgroundLuma)
    }

    /// The derived background: `1 − subject − sky`, pointwise. The three masks partition the
    /// frame — every pixel's mask values sum to exactly 1 — which is the invariant
    /// `MaskPrimitiveTests` pins and every background edit rests on.
    ///
    /// Subtraction rather than the tempting `(1 − subject) × (1 − sky)`: the sky mask is a soft
    /// confidence map, and where a soft subject edge overlaps soft sky the product form leaves a
    /// `subject × sky` residue, so the three would sum past 1 along every boundary. Subtraction
    /// is exact, and it cannot clip negative — `measure` has already multiplied the sky by
    /// `(1 − subject)`, so `subject + sky ≤ 1` everywhere. (`CISubtractBlendMode`, not
    /// `CIAdditionCompositing` + invert: compositing filters add ALPHA too, and the invert
    /// unpremultiplies against that doubled alpha, which turned the background solid white.)
    ///
    /// A missing mask claims nothing, so background is the complement of whatever exists — and
    /// with neither, it is the full white frame. That is correct, not a fallback: "background"
    /// means "everything no other mask claims", and when nothing claims anything, that is the
    /// whole picture.
    static func background(subject: CIImage?, sky: CIImage?, extent: CGRect) -> CIImage {
        var bg = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        for mask in [subject, sky].compactMap({ $0 }) {
            // CISubtractBlendMode: output = background − source, alpha stays 1.
            bg = mask.applyingFilter("CISubtractBlendMode",
                                     parameters: [kCIInputBackgroundImageKey: bg])
                     .cropped(to: extent)
        }
        return bg
    }
}
