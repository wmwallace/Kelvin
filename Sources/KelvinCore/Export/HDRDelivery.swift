import Foundation
@preconcurrency import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// An HDR companion for an edit, written as a HEIC's gain map (D28 — decided 23 September 2026, on
/// the owner's look at samples on an HDR screen: "Images are good").
///
/// **The idea.** Kelvin's renderer is display-referred: its tone curves end at white, so what it
/// produces is an SDR photograph, and every recipe and every corpus number is about that photograph.
/// A RAW, though, holds highlight detail above white, which Apple's decoder releases when asked
/// (`CIRAWFilter.extendedDynamicRangeAmount`). So the HDR rendition is the SDR EDIT given back the
/// RAW'S OWN headroom: the ratio between the frame decoded with and without its extended range is
/// how much brighter than white each highlight really was, and multiplying the edit by that ratio
/// lifts exactly those highlights and leaves everything the edit decided below white as it is.
///
/// Written as one HEIC by `ImageWriter.write(hdr:)`: the SDR edit as the base image, which every
/// viewer shows, plus a gain map that HDR displays apply. Nothing here changes a recipe.
public enum HDRDelivery {

    /// How much of the RAW's extended range to release. Apple's scale: 0 is SDR, 1 is the full
    /// headroom the sensor captured.
    public static let defaultAmount: Float = 1

    /// The ratio map for a RAW — `EDR / SDR` luminance, at most `maxGain`, softly blurred so the
    /// gain map cannot carry pixel-level noise into the highlights. Nil for a file that is not a RAW
    /// or has no headroom to release.
    public static func headroom(for url: URL, amount: Float = defaultAmount,
                                maxGain: Double = 4) -> CIImage? {
        guard ImageDecoder.rawExtensions.contains(url.pathExtension.lowercased()),
              let sdrFilter = CIRAWFilter(imageURL: url), let edrFilter = CIRAWFilter(imageURL: url)
        else { return nil }
        for f in [sdrFilter, edrFilter] where f.isLensCorrectionSupported { f.isLensCorrectionEnabled = true }
        sdrFilter.extendedDynamicRangeAmount = 0
        edrFilter.extendedDynamicRangeAmount = amount
        guard let sdr = sdrFilter.outputImage, let edr = edrFilter.outputImage else { return nil }
        let extent = sdr.extent
        // Luminance of each, replicated to grey, so the gain is one number per pixel and no colour
        // shift rides along with the brightness.
        func luma(_ i: CIImage) -> CIImage {
            let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
            return i.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": weights, "inputGVector": weights, "inputBVector": weights,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0.0005, y: 0.0005, z: 0.0005, w: 0)])
        }
        // edr / sdr, per pixel. CIDivideBlendMode divides the INPUT by the background — measured,
        // the other way round from how it reads: with the operands swapped every gain came out
        // below 1 and clamped away, and a Sunriver frame whose decode peaks at 3.57 got none.
        //
        // And blend modes clamp their result to 1, so a gain of 3 came out as 1. The quotient is
        // therefore taken of an EIGHTH of the EDR value — (edr/8)/sdr stays at or below 1 for every
        // gain up to `maxGain` — and scaled back up afterwards. Built-in filters only: the project
        // has no custom kernels, and this is not the feature to start them.
        let k = maxGain
        func scaled(_ i: CIImage, by f: Double) -> CIImage {
            i.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        }
        let ratio = scaled(scaled(luma(edr), by: 1 / k).applyingFilter("CIDivideBlendMode",
                                             parameters: [kCIInputBackgroundImageKey: luma(sdr)]), by: k)
        let clamped = ratio.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            "inputMaxComponents": CIVector(x: maxGain, y: maxGain, z: maxGain, w: 1)])
        // HIGHLIGHTS ONLY. The EDR decode tone-maps differently all the way down, so the raw ratio is
        // large in the SHADOWS too — dividing by a near-black SDR value — and the first probe put an
        // 8× gain on shade. Headroom is by definition above white, so the gain is released only where
        // the SDR frame is already bright: none below 50% luminance, all of it by 90%.
        //   gain' = 1 + (gain − 1) × w,   w = clamp((L_sdr − 0.5) / 0.4)
        let weight = luma(sdr).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 2.5, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 2.5, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 2.5, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -1.25, y: -1.25, z: -1.25, w: 0)])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        let excess = clamped.applyingFilter("CIColorMatrix", parameters: [
            "inputBiasVector": CIVector(x: -1, y: -1, z: -1, w: 0)])
        let weighted = excess.applyingFilter("CIMultiplyCompositing",
                                             parameters: [kCIInputBackgroundImageKey: weight])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)])
        let radius = Double(min(extent.width, extent.height)) * 0.002
        return weighted.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }

    /// The edit, given the RAW's headroom back.
    public static func hdrCompanion(ofEdit sdrEdit: CIImage, headroom: CIImage) -> CIImage {
        let gain = headroom.extent.size == sdrEdit.extent.size
            ? headroom : LocalMasks.scale(headroom, to: sdrEdit.extent)
        return sdrEdit.applyingFilter("CIMultiplyCompositing",
                                      parameters: [kCIInputBackgroundImageKey: gain])
            .cropped(to: sdrEdit.extent)
    }

    /// The HDR companion of a delivered edit, when the source is a RAW with headroom to give; nil
    /// otherwise, and the export stays SDR. Hand the result to `ImageWriter.write(hdr:)`, which
    /// writes it as the HEIC's gain map under the same metadata, size and colour-space rules as
    /// every other export.
    public static func companion(forEdit sdr: CIImage, from source: URL) -> CIImage? {
        headroom(for: source).map { hdrCompanion(ofEdit: sdr, headroom: $0) }
    }

    /// Whether a file on disk carries an HDR gain map — for the probe, and for a test.
    public static func hasGainMap(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            return true
        }
        if #available(macOS 15, iOS 18, *) {
            return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        }
        return false
    }
}
