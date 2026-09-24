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

public extension LocalMasks {
    /// The long edge a full-resolution delivery is measured at.
    ///
    /// An export used to measure its masks on the frame itself, at 60 MP, and every measurement
    /// re-ran the RAW decode and rasterised the whole frame to read back a grid of 64–160 cells: six
    /// or so full decodes per photograph before the one that is actually written. Nothing measured
    /// needs that many pixels — Vision's segmentation returns a fixed-size buffer whatever it is
    /// given, the sky is classified on a 160-cell grid, and a mean luma is a mean. So a delivery
    /// decodes ONCE into a 2048 px copy on the GPU, measures there, and stretches the masks back.
    ///
    /// 2048, not the 768 perception proxy, because the proxy rule is about AGREEMENT (the canvas,
    /// the export and the harness must resolve the same recipe, so the recipe is always decided on
    /// the proxy) and this is about EDGES: a mask stretched 12× from 768 shows its steps on a
    /// full-size print, stretched 4.6× from 2048 it does not, and both are feathered afterwards.
    static let deliveryMeasureEdge = 2048

    /// A frame shrunk to `deliveryMeasureEdge` and materialised on the GPU, so everything measured
    /// from it costs one decode of the original between them. Half-float and extended-linear, so
    /// highlights a RAW holds above 1.0 are still there to be measured.
    static func deliveryImage(_ full: CIImage) -> CIImage {
        let small = PerceptionProxy.downsample(full, maxEdge: deliveryMeasureEdge)
        guard small.extent.size != full.extent.size || full.extent.width * full.extent.height > 4_200_000,
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let cg = ImageWriter.exportContext.createCGImage(small, from: small.extent,
                                                               format: .RGBAh, colorSpace: space)
        else { return small }
        return CIImage(cgImage: cg)
    }

    /// Every mask bitmap a delivery renders with, measured on `deliveryImage` and placed over the
    /// full frame. What `measure(in: full).bitmaps` returned, at a fraction of the cost.
    static func measureForDelivery(in full: CIImage, mattes: CameraMattes.Found? = nil) -> [String: CIImage] {
        let small = deliveryImage(full)
        return measure(in: small, mattes: mattes).bitmaps.mapValues { scale($0, to: full.extent) }
    }
}

public extension LocalMasks {
    /// A delivery's masks and the bound subjects it could not find again.
    struct Delivery: @unchecked Sendable {
        public let bitmaps: [String: CIImage]
        /// Reference ids with no match in this frame — the export says so rather than writing their
        /// local edits as nothing (see `SubjectInstances.reidentify`).
        public let unmatched: [String]
    }

    /// Everything a full-resolution delivery renders with: the frame's own subject, sky and
    /// background, plus each bound subject found again by where it was — all measured on ONE
    /// `deliveryImage`, and placed over the full frame. The single-photo export and the batch both
    /// call this, so the two cannot measure a frame differently again.
    ///
    /// `segmenting` is the recipe's masks: each tapped object (`Mask.segment`, D32) is segmented
    /// again from its taps on the same image, since the renderer skips one it is handed no bitmap
    /// for. One whose taps come back empty is reported in `unmatched`, like a lost subject.
    static func measureForDelivery(in full: CIImage,
                                   reidentifying references: [SubjectInstances.Reference],
                                   segmenting masks: [Mask] = []) -> Delivery {
        let small = deliveryImage(full)
        var bitmaps = measure(in: small, mattes: mattes).bitmaps
        var unmatched: [String] = []
        if !references.isEmpty {
            let matched = SubjectInstances.reidentify(SubjectInstances.detect(in: small), as: references)
            bitmaps.merge(matched.bitmaps) { _, fresh in fresh }
            unmatched = matched.unmatched
        }
        let objects = ObjectSegmentation.bitmaps(for: masks, in: small, placedOver: small.extent)
        bitmaps.merge(objects.bitmaps) { _, fresh in fresh }
        unmatched += objects.failed
        return Delivery(bitmaps: bitmaps.mapValues { scale($0, to: full.extent) }, unmatched: unmatched)
    }
}
