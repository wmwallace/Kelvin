import CoreImage

public extension LocalMasks {
    /// A mask measured at one resolution, placed over another.
    ///
    /// Masks are measured on the 768 px perception proxy — the one resolution every path can
    /// afford, so the canvas, the export and the harness agree on them (see `ShippedCandidates`) —
    /// and rendered on whatever is being drawn. Nothing real is lost by the stretch: Vision hands
    /// back a fixed-size buffer whatever it is given, and `SkyMask` classifies on a coarse grid, so
    /// both were already being scaled to the size asked for.
    static func scale(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let from = mask.extent
        guard !from.isInfinite, from.width > 0, from.height > 0,
              !extent.isInfinite, extent.width > 0, extent.height > 0,
              from.size != extent.size else { return mask }
        return mask
            .transformed(by: CGAffineTransform(scaleX: extent.width / from.width,
                                               y: extent.height / from.height))
            .transformed(by: CGAffineTransform(translationX: extent.origin.x - from.origin.x,
                                               y: extent.origin.y - from.origin.y))
            .cropped(to: extent)
    }
}
