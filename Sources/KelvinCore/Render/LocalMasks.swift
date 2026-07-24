import Foundation
import CoreImage

/// One place that segments an image into the local masks the pipeline understands (subject, sky)
/// and measures each region's mean luminance. Both numbers the *engine* needs to size a local
/// correction (`subjectLuma`, `skyLuma`) and the bitmaps the *renderer* needs to apply it come
/// from the same pass — so the app, the CLI, and batch never drift in how a mask is produced.
public enum LocalMasks {

    public struct Measured: Sendable {
        /// Keyed by mask `id`/`type` ("subject", "sky"); ready for `Renderer.render(_:with:maskBitmaps:)`.
        public let bitmaps: [String: CIImage]
        public let subjectLuma: Double?
        public let skyLuma: Double?
    }

    /// Segment subject + sky once and measure them. Missing regions are simply absent (nil luma,
    /// no bitmap), which the engine reads as "nothing local to do here".
    public static func measure(in image: CIImage) -> Measured {
        var bitmaps: [String: CIImage] = [:]
        var subjectLuma: Double?
        var skyLuma: Double?

        if let subject = SubjectMask.person(in: image) {
            bitmaps["subject"] = subject
            subjectLuma = SubjectMask.maskedMeanLuma(image: image, mask: subject)
            // Prefer metered skin brightness when a face is present: it's what the subject-lift
            // decision actually cares about, and metering (not classifying) skin keeps the
            // recovery tone-fair. The whole-person mask still carries the lift.
            let face = FaceSkin.read(in: image)
            if let skin = face.skinLuma { subjectLuma = skin }
        }
        if let sky = SkyMask.detect(in: image) {
            bitmaps["sky"] = sky
            skyLuma = SubjectMask.maskedMeanLuma(image: image, mask: sky)
        }
        return Measured(bitmaps: bitmaps, subjectLuma: subjectLuma, skyLuma: skyLuma)
    }
}
