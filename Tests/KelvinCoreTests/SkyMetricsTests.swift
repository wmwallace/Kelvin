import XCTest
import CoreImage
@testable import KelvinCore

/// Tests for the sky-region instrument itself.
///
/// Every fixture here is 160×120 — exactly `SkyMetrics.gridEdge` wide with a 4:3 frame — so one
/// image pixel is one grid cell and there is no resampling between what the test draws and what the
/// instrument reads. A test of a measurement should not be measuring an interpolator.
///
/// Note that nothing here asserts what `SkyMask` currently does. This is the instrument, and an
/// instrument calibrated against the thing it is meant to judge measures only its own agreement
/// with it. The mask's own behaviour is `SkyMaskTests`.
final class SkyMetricsTests: XCTestCase {

    private let width = 160, height = 120

    private func image(_ body: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bpr = width * 4
        var bytes = [UInt8](repeating: 0, count: bpr * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bpr + x * 4
                let c = body(x, y)
                bytes[i] = c.0; bytes[i+1] = c.1; bytes[i+2] = c.2; bytes[i+3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// Row 0 is the top of the frame, matching how `rgba8Sampled` reads and how `SkyMask` scores.
    private let horizon = 72                                  // sky is the top 60%
    private let blue: (UInt8, UInt8, UInt8) = (150, 180, 230)
    private let cloud: (UInt8, UInt8, UInt8) = (245, 246, 250)
    private let ground: (UInt8, UInt8, UInt8) = (60, 110, 60)

    private func clearSky() -> CIImage {
        image { _, y in y < horizon ? blue : ground }
    }

    /// Blue with three cumulus banks in it — the frame the whole sky argument is about.
    private func cumulusSky() -> CIImage {
        let banks = [(40, 25, 18), (95, 20, 22), (130, 45, 15)]
        return image { x, y in
            guard y < horizon else { return ground }
            for (cx, cy, r) in banks where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r {
                return cloud
            }
            return blue
        }
    }

    private func grey(_ body: @escaping (Int, Int) -> Double) -> CIImage {
        image { x, y in
            let v = UInt8(max(0, min(255, body(x, y) * 255)))
            return (v, v, v)
        }
    }

    // MARK: - The region

    func testRegionCoversTheSkyAndNotTheGround() throws {
        let region = try SkyMetrics.referenceRegion(in: clearSky())
        XCTAssertFalse(region.isEmpty)
        XCTAssertEqual(region.width, 160)
        XCTAssertEqual(region.height, 120)

        // Coverage is credibility-weighted, not a headcount: this blue scores ~0.59 as sky, over
        // 60% of the frame. What must be true is that the weight is all above the horizon.
        var aboveHorizon = 0.0, belowHorizon = 0.0
        for y in 0..<region.height {
            for x in 0..<region.width {
                let w = region.weights[y * region.width + x]
                if y < horizon { aboveHorizon += w } else { belowHorizon += w }
            }
        }
        XCTAssertGreaterThan(aboveHorizon, 0.9 * Double(width * horizon) * 0.5,
                             "most of the sky's cells should carry real weight")
        XCTAssertEqual(belowHorizon, 0, accuracy: 1e-9, "no weight may fall below the horizon")
    }

    func testRegionKeepsACloudySkyWhole() throws {
        // The defect this instrument exists to see: a cloud is sky. A region that scored clouds
        // the way `SkyMask` does would report the blue between them and call that the sky.
        let region = try SkyMetrics.referenceRegion(in: cumulusSky())
        var cloudWeight = 0.0, cloudCells = 0.0
        let banks = [(40, 25, 18), (95, 20, 22), (130, 45, 15)]
        for y in 0..<horizon {
            for x in 0..<width {
                let isCloud = banks.contains { (cx, cy, r) in
                    (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r
                }
                guard isCloud else { continue }
                cloudCells += 1
                cloudWeight += region.weights[y * width + x]
            }
        }
        XCTAssertGreaterThan(cloudCells, 2000, "fixture should actually contain cloud")
        XCTAssertGreaterThan(cloudWeight / cloudCells, 0.9,
                             "cloud must be counted as sky, at close to full weight")
    }

    func testADarkLineAcrossTheSkyDoesNotEndTheColumn() throws {
        // A wire, a gull, the dark rim of a cloud. Two cells of slack exist for this; without it a
        // single dark row would cut every column and discard the sky beneath it.
        let wired = image { _, y in
            if y == 30 { return (20, 20, 20) }
            return y < horizon ? blue : ground
        }
        let region = try SkyMetrics.referenceRegion(in: wired)
        var below = 0.0
        for y in 31..<horizon { for x in 0..<width { below += region.weights[y * width + x] } }
        XCTAssertGreaterThan(below, 0.4 * Double(width * (horizon - 31)),
                             "the sky below a one-cell dark line is still sky")
    }

    /// The frame the instrument was wrong about on its first run against a real shoot: a heavy
    /// overcast filling the top two thirds. Measured on `_DSC6390` from 2026-04-26 Cannon Beach —
    /// sky luma 0.52…0.67 at saturation 0.05 over sand at luma 0.32, saturation 0.22 — and the
    /// numbers here are that photograph, rounded to 8-bit.
    func testAHeavyOvercastIsSky() throws {
        let overcast = image { _, y in y < horizon ? (155, 158, 162) : (105, 92, 74) }
        let region = try SkyMetrics.referenceRegion(in: overcast)
        XCTAssertFalse(region.isEmpty, "a grey overcast is the commonest sky on this coast")

        var below = 0.0
        for y in horizon..<height { for x in 0..<width { below += region.weights[y * width + x] } }
        XCTAssertEqual(below, 0, accuracy: 1e-9, "and the sand under it is still not sky")

        let reading = try XCTUnwrap(SkyMetrics.read(overcast, in: region))
        XCTAssertGreaterThan(reading.meanLuma, 0.55)
        XCTAssertLessThan(try XCTUnwrap(reading.groundMeanLuma), 0.45)
    }

    func testNoRegionInADarkInteriorFrame() throws {
        let interior = image { _, y in y < horizon ? (44, 40, 38) : (22, 20, 19) }
        let region = try SkyMetrics.referenceRegion(in: interior)
        XCTAssertTrue(region.isEmpty)
        XCTAssertNil(try SkyMetrics.read(interior, in: region),
                     "a frame with no sky yields no sky reading rather than a zero one")
    }

    // MARK: - Reading

    func testSpreadSeesCloudStructureAndAFlatSkyHasNone() throws {
        let flat = clearSky()
        let cumulus = cumulusSky()
        let flatReading = try XCTUnwrap(SkyMetrics.read(flat, in: SkyMetrics.referenceRegion(in: flat)))
        let cumulusReading = try XCTUnwrap(
            SkyMetrics.read(cumulus, in: SkyMetrics.referenceRegion(in: cumulus)))

        XCTAssertLessThan(flatReading.spread, 0.02, "an unbroken blue has no tonal separation")
        XCTAssertGreaterThan(cumulusReading.spread, 0.2, "cloud against blue is tonal separation")
        // Ground is reported separately so a region that has eaten the ground is visible as such.
        XCTAssertLessThan(try XCTUnwrap(flatReading.groundMeanLuma), flatReading.meanLuma - 0.2)
    }

    // MARK: - Divergence, which is the point of the exercise

    func testAGroundOnlyChangePassesTheFrameMetricAndMovesNoSky() throws {
        // This is the reported defect in miniature. Two renders differ only below the horizon; the
        // whole-frame number is comfortably above the divergence floor the harness has been using,
        // and the sky is byte-identical. Before this instrument, that pair scored as two
        // meaningfully different candidates.
        let source = clearSky()
        let region = try SkyMetrics.referenceRegion(in: source)
        let groundDarkened = image { _, y in
            y < horizon ? blue : (ground.0 / 2, ground.1 / 2, ground.2 / 2)
        }
        let d = try XCTUnwrap(SkyMetrics.compare(source, groundDarkened, in: region))

        XCTAssertGreaterThan(d.frameMeanAbsDelta, 0.05,
                             "the frame really has changed — this is not a no-op")
        XCTAssertLessThan(d.skyMeanAbsDelta, 0.005, "and the sky has not moved at all")
        XCTAssertEqual(d.skySpreadDelta, 0, accuracy: 0.005)
    }

    func testASkyOnlyChangeIsMeasuredWhereItHappens() throws {
        let source = clearSky()
        let region = try SkyMetrics.referenceRegion(in: source)
        let skyDarkened = image { _, y in
            y < horizon ? (UInt8(Double(blue.0) * 0.75), UInt8(Double(blue.1) * 0.75),
                           UInt8(Double(blue.2) * 0.75))
                        : ground
        }
        let d = try XCTUnwrap(SkyMetrics.compare(source, skyDarkened, in: region))

        XCTAssertGreaterThan(d.skyMeanAbsDelta, 0.1, "a quarter-stop off the sky is a sky change")
        XCTAssertLessThan(d.skyMeanLumaDelta, -0.1, "and it is signed: the sky went down")
    }

    // MARK: - Scoring a mask against the region

    func testAPerfectMaskScoresAsOne() throws {
        let source = clearSky()
        let region = try SkyMetrics.referenceRegion(in: source)
        let mask = grey { _, y in y < self.horizon ? 1 : 0 }
        let a = try XCTUnwrap(SkyMetrics.agreement(of: mask, with: region))

        XCTAssertGreaterThan(a.meanAlphaInRegion, 0.98)
        XCTAssertLessThan(a.orphanedFraction, 0.02)
        XCTAssertLessThan(a.spillFraction, 0.02)
    }

    func testAMissingMaskIsTotalLossRatherThanASkippedFrame() throws {
        let source = clearSky()
        let region = try SkyMetrics.referenceRegion(in: source)
        let a = try XCTUnwrap(SkyMetrics.agreement(of: nil, with: region))

        XCTAssertEqual(a.meanAlphaInRegion, 0)
        XCTAssertEqual(a.orphanedFraction, 1)
        XCTAssertEqual(a.maskCoverage, 0)
    }

    func testAMaskThatLosesTheCloudsReportsThemAsOrphaned() throws {
        // The shape of the defect, expressed with a mask built to have it rather than by asserting
        // that `SkyMask` currently does — so this test stays true after the mask learns clouds.
        let source = cumulusSky()
        let region = try SkyMetrics.referenceRegion(in: source)
        let banks = [(40, 25, 18), (95, 20, 22), (130, 45, 15)]
        let blueOnly = grey { x, y in
            guard y < self.horizon else { return 0 }
            let onCloud = banks.contains { (cx, cy, r) in
                (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r
            }
            return onCloud ? 0 : 1
        }
        let a = try XCTUnwrap(SkyMetrics.agreement(of: blueOnly, with: region))

        // The banks are ~28% of the sky in this fixture, and that is what should come back.
        XCTAssertGreaterThan(a.orphanedFraction, 0.2)
        XCTAssertLessThan(a.orphanedFraction, 0.4)
        XCTAssertLessThan(a.meanAlphaInRegion, 0.8,
                          "the multiplier every sky adjustment passes through is reduced by exactly this")
    }

    func testAMaskClaimingTheGroundReportsSpill() throws {
        // The failure that loosening `SkyMask`'s thresholds would buy, and the reason the metric
        // reports both directions rather than only what the mask misses.
        let source = clearSky()
        let region = try SkyMetrics.referenceRegion(in: source)
        let everything = grey { _, _ in 1 }
        let a = try XCTUnwrap(SkyMetrics.agreement(of: everything, with: region))

        XCTAssertGreaterThan(a.meanAlphaInRegion, 0.98, "it does cover the sky…")
        XCTAssertGreaterThan(a.spillFraction, 0.3, "…and a third of it is ground")
    }
}
