import Foundation
import CoreImage
import ImageIO

/// The masks an iPhone already made when it took the photograph.
///
/// The camera runs its own segmentation at capture and stores the results inside the HEIC as
/// auxiliary images: a sky matte on about a quarter of the owner's iPhone photographs (168 of 689
/// measured), and on Portrait-mode shots a person matte, hair and skin. They are computed on the
/// full sensor readout with the depth data to hand, and they are free — which `SkyMask`, a 160-cell
/// classifier, and Vision's person segmentation, run on a 768 px proxy, are not.
///
/// **Used where present, never required.** Most photographs carry none (every Sony ARW, most JPEGs),
/// and those measure exactly as before. A matte is read from the file each time it is needed — the
/// same "regenerated from the original" rule every segmentation mask follows (RECIPE-SCHEMA
/// invariant 6), so nothing about it is stored in a recipe.
public enum CameraMattes {

    /// What a file carries, each already oriented and placed over the photograph's own extent.
    public struct Found: @unchecked Sendable {
        public let sky: CIImage?
        /// The person, hair included: the portrait-effects matte, or the hair matte unioned onto
        /// Vision's person segmentation when that is all there is.
        public let person: CIImage?
        public let hair: CIImage?
        public let skin: CIImage?

        public var isEmpty: Bool { sky == nil && person == nil && hair == nil && skin == nil }
    }

    /// `KELVIN_CAMERA_MATTES=0` ignores them, for an A/B.
    public static let enabled: Bool = ProcessInfo.processInfo.environment["KELVIN_CAMERA_MATTES"] != "0"

    /// The mattes in `url`, or nil when it carries none (or is not a file the camera wrote).
    /// Cheap to call on anything: a file with no auxiliary data answers from its header.
    public static func read(from url: URL) -> Found? {
        guard enabled, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let wanted: [(CFString, CIImageOption)] = [
            (kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte, .auxiliarySemanticSegmentationSkyMatte),
            (kCGImageAuxiliaryDataTypePortraitEffectsMatte, .auxiliaryPortraitEffectsMatte),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, .auxiliarySemanticSegmentationHairMatte),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, .auxiliarySemanticSegmentationSkinMatte),
        ]
        // Header check first: opening a matte that is not there costs a decode for nothing.
        let present = wanted.filter { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0.0) != nil }
        guard !present.isEmpty else { return nil }
        // The photograph's own oriented extent, which every matte is placed over.
        guard let photo = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        func matte(_ option: CIImageOption) -> CIImage? {
            guard present.contains(where: { $0.1 == option }),
                  let m = CIImage(contentsOf: url, options: [option: true, .applyOrientationProperty: true])
            else { return nil }
            return placed(m, over: photo.extent)
        }
        let found = Found(sky: matte(.auxiliarySemanticSegmentationSkyMatte),
                          person: matte(.auxiliaryPortraitEffectsMatte),
                          hair: matte(.auxiliarySemanticSegmentationHairMatte),
                          skin: matte(.auxiliarySemanticSegmentationSkinMatte))
        return found.isEmpty ? nil : found
    }

    /// A matte (stored at a fraction of the photograph's resolution) stretched over it, as a
    /// greyscale mask with alpha 1 — the form every other mask bitmap in `LocalMasks` takes.
    static func placed(_ matte: CIImage, over extent: CGRect) -> CIImage {
        let m = matte.extent
        guard m.width > 0, m.height > 0 else { return matte }
        let fitted = matte
            .transformed(by: CGAffineTransform(translationX: -m.origin.x, y: -m.origin.y))
            .transformed(by: CGAffineTransform(scaleX: extent.width / m.width, y: extent.height / m.height))
            .transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
            .cropped(to: extent)
        // Mattes are single-channel; make them the RGB-equal, opaque greyscale the renderer reads.
        return fitted.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).cropped(to: extent)
    }

    /// The mattes scaled over another image of the same photograph — a proxy, or the full frame.
    public static func scaled(_ found: Found, to extent: CGRect) -> Found {
        func s(_ m: CIImage?) -> CIImage? { m.map { LocalMasks.scale($0, to: extent).cropped(to: extent) } }
        return Found(sky: s(found.sky), person: s(found.person), hair: s(found.hair), skin: s(found.skin))
    }
}
