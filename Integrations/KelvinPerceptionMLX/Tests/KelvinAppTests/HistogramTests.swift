import XCTest
import CoreImage
import KelvinCore
@testable import KelvinApp

/// The tonal readout, which is the only instrument in the window that claims to measure something.
///
/// It is worth testing precisely because it looks decorative: a histogram that is merely *pretty*
/// and slightly wrong is worse than none, since people make exposure decisions from it. The rules
/// pinned here are the ones that would silently lie — the shared peak that makes casts visible, and
/// the clipping threshold that decides whether a warning means anything.
///
/// `@MainActor` because `HistogramView` is a SwiftUI `View` and therefore main-actor isolated, so
/// `read` cannot be called from a nonisolated context. Omitting it compiled cleanly against the
/// macOS 27 SDK on the author's machine and failed every job in CI — the same local-versus-CI
/// divergence recorded on `PhotoBrowser.thumbnailCG`. Local green is not evidence here.
@MainActor
final class HistogramTests: XCTestCase {

    /// A flat image of one colour, which makes the expected histogram trivial to state.
    private func flat(r: UInt8, g: UInt8, b: UInt8, size: Int = 64) -> CIImage {
        let bpr = size * 4
        var px = [UInt8](repeating: 0, count: bpr * size)
        for i in stride(from: 0, to: px.count, by: 4) {
            px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = 255
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    // MARK: Reading the distribution

    func testNoImageReadsNothing() {
        XCTAssertNil(HistogramReader.read(nil))
    }

    /// Three channels, sixty-four bins each, and every sampled pixel counted exactly once per
    /// channel — the arithmetic the rest of the view divides by.
    func testEveryPixelIsCountedOncePerChannel() throws {
        let r = try XCTUnwrap(HistogramReader.read(flat(r: 128, g: 128, b: 128)))
        XCTAssertEqual(r.channels.count, 3)
        for channel in r.channels {
            XCTAssertEqual(channel.count, 64)
            XCTAssertEqual(channel.reduce(0, +), 100 * 100, accuracy: 1,
                           "the bins should account for every sampled pixel")
        }
    }

    /// A neutral frame puts all three channels in the same bin — which is what makes the additive
    /// blend read as grey, and therefore what makes any colour on screen mean a cast.
    func testANeutralFramePutsEveryChannelInTheSameBin() throws {
        let r = try XCTUnwrap(HistogramReader.read(flat(r: 128, g: 128, b: 128)))
        let peaks = r.channels.map { bins in bins.firstIndex(of: bins.max()!)! }
        XCTAssertEqual(Set(peaks).count, 1, "a grey frame disagreed across channels: \(peaks)")
    }

    /// A cast separates them. If this ever stops holding, the view is drawing three copies of the
    /// same curve and the whole redesign is cosmetic.
    func testAColourCastSeparatesTheChannels() throws {
        let r = try XCTUnwrap(HistogramReader.read(flat(r: 200, g: 120, b: 60)))
        let peaks = r.channels.map { bins in bins.firstIndex(of: bins.max()!)! }
        XCTAssertEqual(Set(peaks).count, 3, "a strong cast collapsed into one bin: \(peaks)")
        XCTAssertGreaterThan(peaks[0], peaks[1], "red should sit brighter than green here")
        XCTAssertGreaterThan(peaks[1], peaks[2], "green should sit brighter than blue here")
    }

    /// ONE peak shared by all three channels. Normalising each channel to its own maximum would
    /// draw every frame as three equal-height curves and flatten out exactly the casts above.
    func testThePeakIsSharedAcrossChannels() throws {
        let r = try XCTUnwrap(HistogramReader.read(flat(r: 200, g: 120, b: 60)))
        let tallest = r.channels.flatMap { $0 }.max()!
        XCTAssertEqual(r.peak, tallest, accuracy: 0.001)
    }

    // MARK: Clipping — the part that has to be trustworthy

    func testPureBlackReportsEveryChannelCrushed() throws {
        let r = try XCTUnwrap(HistogramReader.read(flat(r: 0, g: 0, b: 0)))
        XCTAssertEqual(r.shadowClipped, ["R", "G", "B"])
        XCTAssertTrue(r.highlightClipped.isEmpty)
    }

    func testPureWhiteReportsEveryChannelBlown() throws {
        let r = try XCTUnwrap(HistogramReader.read(flat(r: 255, g: 255, b: 255)))
        XCTAssertEqual(r.highlightClipped, ["R", "G", "B"])
        XCTAssertTrue(r.shadowClipped.isEmpty)
    }

    /// One channel can clip while the frame's brightness looks perfectly healthy. This is the case
    /// the old luma silhouette could not show at all, and the reason the channels are drawn apart.
    func testASingleChannelCanClipOnItsOwn() throws {
        let r = try XCTUnwrap(HistogramReader.read(flat(r: 255, g: 90, b: 90)))
        XCTAssertEqual(r.highlightClipped, ["R"])
    }

    /// **A bright frame that still holds detail is NOT clipping.** The old test was "the last of 64
    /// bins is tall", and the last bin covers four levels — so a photograph with strong but intact
    /// highlights raised the same warning as one with none left. A warning that fires on healthy
    /// frames is one people learn to ignore.
    func testStrongButIntactHighlightsAreNotReportedAsClipped() throws {
        // 252 lands in bin 63 — the very last of the sixty-four, the one the old check keyed on —
        // and still holds three levels of detail below pure white. That is precisely the frame the
        // old rule cried wolf on, so it is the one worth pinning.
        let r = try XCTUnwrap(HistogramReader.read(flat(r: 252, g: 252, b: 252)))
        XCTAssertEqual(r.channels[0].firstIndex(of: r.channels[0].max()!), 63,
                       "the fixture should sit in the topmost bin or it proves nothing")
        XCTAssertTrue(r.highlightClipped.isEmpty,
                      "a frame with detail left at the top was reported as blown")
    }

    /// Same at the bottom: nearly black is not crushed.
    func testNearlyBlackIsNotReportedAsCrushed() throws {
        let r = try XCTUnwrap(HistogramReader.read(flat(r: 6, g: 6, b: 6)))
        XCTAssertTrue(r.shadowClipped.isEmpty)
    }

    // MARK: The tone-colour signature

    /// Half cool shadow, half warm highlight — a split tone, which is exactly what the strip exists
    /// to make nameable at a glance. The dark end must read blue and the bright end amber; if they
    /// ever come back the same, the strip is drawing the tone scale rather than the photograph's
    /// colour and is worth nothing.
    func testTheSignatureSeparatesCoolShadowsFromWarmHighlights() throws {
        let size = 64, bpr = size * 4
        var px = [UInt8](repeating: 0, count: bpr * size)
        for y in 0..<size {
            let cool = y < size / 2
            for x in 0..<size {
                let i = y * bpr + x * 4
                px[i]     = cool ? 30 : 230        // R
                px[i + 1] = cool ? 45 : 170        // G
                px[i + 2] = cool ? 95 : 90         // B
                px[i + 3] = 255
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let r = try XCTUnwrap(HistogramReader.read(CIImage(cgImage: ctx.makeImage()!)))

        let occupied = r.signature.enumerated().filter { $0.element.weight > 0 }
        let dark = try XCTUnwrap(occupied.first)
        let bright = try XCTUnwrap(occupied.last)
        XCTAssertGreaterThan(dark.element.b, dark.element.r, "the shadows should read cool")
        XCTAssertGreaterThan(bright.element.r, bright.element.b, "the highlights should read warm")
    }

    /// A tone the photograph does not contain contributes nothing. A strip that invented a colour
    /// for an empty bin would be drawing something the frame never had.
    func testEmptyTonesStayTransparent() throws {
        let r = try XCTUnwrap(HistogramReader.read(flat(r: 128, g: 128, b: 128)))
        let occupied = r.signature.filter { $0.weight > 0 }
        XCTAssertEqual(occupied.count, 1, "a single flat tone should occupy exactly one bin")
        let clearStops = r.signatureStops.filter { $0.color == .clear }
        XCTAssertEqual(clearStops.count, 63, "every unoccupied bin should draw as nothing")
    }

    /// The lift is what makes shadows legible on a near-black panel — it must raise brightness
    /// while leaving the hue relationship alone, or the strip is showing a colour the frame has not
    /// got.
    func testTheLiftBrightensShadowsWithoutChangingTheirHue() throws {
        let r = try XCTUnwrap(HistogramReader.read(flat(r: 12, g: 18, b: 38)))
        let raw = try XCTUnwrap(r.signature.first { $0.weight > 0 })
        XCTAssertLessThan(raw.b, 0.2, "the fixture really is very dark")
        // Blue stays the dominant channel after the lift, and the result is actually visible.
        let ratioBefore = raw.b / raw.r
        let stop = try XCTUnwrap(r.signatureStops.first { $0.color != .clear })
        let c = NSColor(stop.color).usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(c.blueComponent, 0.5, "a shadow tone came back too dark to see")
        XCTAssertEqual(c.blueComponent / c.redComponent, ratioBefore, accuracy: 0.05,
                       "the lift changed the colour rather than just its brightness")
    }

    /// **An almost-black tone must not come back white.** Caught on screen, not here: the shadow end
    /// of the strip showed a confident white band on a photograph whose shadows were black. A bin
    /// averaging near-zero has a peak around 0.008, and normalising that to full brightness is a
    /// seventy-eight-fold gain applied to 8-bit rounding noise — so the strip stated a colour the
    /// frame did not have, at the exact end of the range people check for crushed blacks.
    func testAnAlmostBlackToneIsNotAmplifiedIntoAColour() throws {
        let r = try XCTUnwrap(HistogramReader.read(flat(r: 2, g: 2, b: 3)))
        let stop = try XCTUnwrap(r.signatureStops.first { $0.color != .clear })
        let c = NSColor(stop.color).usingColorSpace(.sRGB)!
        XCTAssertLessThan(c.brightnessComponent, 0.25,
                          "a black shadow was amplified into a bright band")
    }

    /// And the cap keeps the range readable: a dark tone stays visibly darker than a bright one
    /// rather than every tone being normalised to the same brightness.
    func testDarkTonesStayDarkerThanBrightOnes() throws {
        func brightness(_ v: UInt8) throws -> CGFloat {
            let r = try XCTUnwrap(HistogramReader.read(flat(r: v, g: v, b: v)))
            let stop = try XCTUnwrap(r.signatureStops.first { $0.color != .clear })
            return NSColor(stop.color).usingColorSpace(.sRGB)!.brightnessComponent
        }
        XCTAssertLessThan(try brightness(16), try brightness(200))
    }

    // MARK: Saying it in words

    /// Colour and corner say it first; the caption has to say it too, or the message rests on
    /// colour alone.
    func testTheCaptionNamesTheChannelsAndTheEnd() throws {
        let blown = try XCTUnwrap(HistogramReader.read(flat(r: 255, g: 255, b: 255)))
        XCTAssertTrue(blown.clippingSummary.contains("RGB"))
        XCTAssertTrue(blown.clippingSummary.contains("▲"))
        XCTAssertTrue(blown.tooltip.contains("pure white"))

        let clean = try XCTUnwrap(HistogramReader.read(flat(r: 128, g: 128, b: 128)))
        XCTAssertTrue(clean.clippingSummary.isEmpty, "a clean frame should say nothing at all")
        XCTAssertFalse(clean.tooltip.isEmpty, "the tooltip should still explain what is drawn")
    }
}
