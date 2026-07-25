import XCTest
import CoreImage
@testable import KelvinCore

/// Triage: the cheap staging pass that runs over a whole shoot before anyone starts culling.
///
/// The two halves are tested very differently on purpose.
///
/// **The concern rules** are a pure function of two measurements, so they are exercised with
/// statistics taken from REAL frames of two of the owner's shoots (836 photographs) rather than from
/// anything invented. The interesting assertions are the negative ones: the darkest, brightest and
/// most clipped frames of those shoots are all photographs he kept, and a triage pass that flags
/// them is worse than useless. Their measurements are quoted in the tests so that a future threshold
/// change has to argue with actual photographs instead of with a round number.
///
/// **The fingerprint** is tested on synthetic fields, because a committed test cannot depend on
/// anyone's photo library — but the fixtures were chosen against a specific failure mode this
/// codebase has been bitten by. A difference hash reduces the frame to a 9×8 grid, so both obvious
/// fixtures are useless: a flat patch has nothing to compare (every bit is rounding noise) and a
/// fine checkerboard *aliases into* a flat patch under that reduction, which is the same trap that
/// made an earlier blur test meaningless. What survives the reduction is broad, low-frequency
/// structure at roughly the scale of the grid cells — which is also all a photograph is once it has
/// been reduced to 72 numbers. Hence `field` below.
///
/// Every synthetic result here was checked against real photographs before being trusted, and the
/// measured numbers are quoted beside the assertions.
final class PhotoTriageTests: XCTestCase {

    // MARK: - Fixtures

    /// A frame with the structure a difference hash actually reads: broad tonal regions, nothing
    /// finer than a grid cell. `seed` picks a different composition; `shift` slides the same
    /// composition sideways, which is what a photographer panning does.
    ///
    /// **NOT PERIODIC, and that was not the first attempt.** The obvious builder — a sum of two or
    /// three sinusoids — was tried and had to be thrown away: a wave of two cycles across the frame
    /// comes back into phase after half a pan, so the fixture claimed a half-panned frame looked
    /// like where it started (9 bits) and made the anti-chaining test meaningless. It also made
    /// different seeds only 11–17 bits apart, where real photographs measure 24–40. Both are the
    /// same fault this codebase keeps rediscovering: a synthetic fixture whose own structure, rather
    /// than the thing under test, decides the answer.
    ///
    /// So the content is soft blobs at random places — non-repeating, roughly the scale of a grid
    /// cell, which is what a photograph looks like once it has been reduced to 72 numbers. They are
    /// laid out across three frame-widths so that panning brings new content in from the side
    /// instead of wrapping round to old content.
    private func field(seed: Int, shift: Double = 0, size: Int = 240) -> CIImage {
        var state = UInt64(bitPattern: Int64(seed)) &* 6_364_136_223_846_793_005 &+ 1
        func rnd() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) % 100_000) / 100_000.0
        }
        struct Blob { let x, y, sx, sy, a: Double }
        let blobs = (0..<24).map { _ in
            Blob(x: rnd() * 3 - 1, y: rnd(),
                 sx: 0.08 + rnd() * 0.22, sy: 0.08 + rnd() * 0.22,
                 a: rnd() * 0.6 - 0.3)
        }
        let tiltX = rnd() * 0.4 - 0.2, tiltY = rnd() * 0.4 - 0.2

        return TestSupport.pixels(size: size) { px, py in
            let u = Double(px) / Double(size) + shift
            let v = Double(py) / Double(size)
            var y = 0.5 + tiltX * (u - 0.5) + tiltY * (v - 0.5)
            for b in blobs {
                let dx = (u - b.x) / b.sx, dy = (v - b.y) / b.sy
                let r2 = dx * dx + dy * dy
                if r2 < 9 { y += b.a * exp(-r2) }
            }
            let c = UInt8(max(0, min(255, y * 255)))
            return (c, c, c)
        }
    }

    /// Statistics carrying only the numbers the concern rules read. The rest are plausible neutral
    /// values and are genuinely unused: `PhotoTriage.concerns` touches `medianLuma`, `shadowMass`
    /// and `highlightClip`, and nothing else.
    private func stats(median: Double, mass: Double, clip: Double) -> ImageStatistics {
        ImageStatistics(meanLuma: median, medianLuma: median,
                        blackPoint: 0, shadowLevel: 0.05, highlightLevel: 0.9, whitePoint: 0.9,
                        highlightClip: clip, shadowClip: 0, chromaA: 0, chromaB: 0,
                        shadowMass: mass, shadowRegion: mass)
    }

    private func sharp() -> FocusMeasure.Reading { .init(acuity: 4.5, measurable: true) }

    private func frames(_ images: [CIImage], from: Date? = nil,
                        every seconds: TimeInterval = 3600) -> [PhotoTriage.Frame] {
        images.enumerated().map { i, image in
            PhotoTriage.Frame(url: URL(fileURLWithPath: "/shoot/\(i).jpg"),
                              signature: PhotoTriage.signature(of: image) ?? .unmeasurable,
                              captured: from?.addingTimeInterval(Double(i) * seconds))
        }
    }

    // MARK: - The rules, against real frames

    /// THE TEST THAT MATTERS MOST, and the one that shaped the rules. Five real photographs, each
    /// the extreme of its measurement across 836 frames of the owner's work, each one a frame he
    /// kept. If triage flags any of them it is crying wolf on ordinary photography — and a staging
    /// pass that cries wolf gets switched off, at which point it catches nothing at all.
    ///
    /// Two of these five were flagged by an earlier version of this file, which is why the rules
    /// look the way they do now. `IMG_1759` in particular is the whole argument for testing exposure
    /// with two conditions rather than one.
    func testTheExtremeFramesOfTwoRealShootsAreNotFlagged() {
        // _DSC6734 — the darkest frame in a 437-frame RAW shoot. A legitimate low-light photograph.
        XCTAssertEqual(PhotoTriage.concerns(for: stats(median: 0.144, mass: 0.078, clip: 0.000),
                                            focus: sharp()), [])
        // _DSC6746 — the highest shadow mass anywhere in either shoot, 36.6% of the frame below the
        // level detail survives at. It is two gulls on a dark headland against grey sky: a
        // deliberate near-silhouette, and the reason a "blocked shadows" concern was removed.
        XCTAssertEqual(PhotoTriage.concerns(for: stats(median: 0.179, mass: 0.366, clip: 0.000),
                                            focus: sharp()), [])
        // IMG_1856 — the brightest frame in a 399-frame JPEG shoot, median 0.866, clipping nothing.
        XCTAssertEqual(PhotoTriage.concerns(for: stats(median: 0.866, mass: 0.000, clip: 0.000),
                                            focus: sharp()), [])
        // IMG_1759 — a portrait against a bright overcast sky: median 0.840 with 20.7% of the frame
        // pinned at 254+. Both numbers are high and the photograph is fine. This frame is why the
        // bright threshold sits at 0.88/0.40 and not where it started.
        XCTAssertEqual(PhotoTriage.concerns(for: stats(median: 0.840, mass: 0.000, clip: 0.207),
                                            focus: sharp()), [])
        // The most clipped frame in either shoot, 28% at 254+, shot into a bright sky.
        XCTAssertEqual(PhotoTriage.concerns(for: stats(median: 0.500, mass: 0.020, clip: 0.280),
                                            focus: sharp()), [])
    }

    /// The other half: a threshold nothing ever trips is not caution, it is a dead feature. These
    /// are the numbers real photographs produce once the exposure is genuinely gone — measured by
    /// pushing frames from the same two shoots to ±5 EV, which is the histogram shape of a shutter
    /// fired with the lens cap on or a flash misfire, and by some distance the worst either shoot
    /// contains.
    func testFramesWithNoExposureLeftAreCaught() {
        XCTAssertEqual(PhotoTriage.concerns(for: stats(median: 0.02, mass: 0.99, clip: 0.0),
                                            focus: sharp()), [.veryDark])
        XCTAssertEqual(PhotoTriage.concerns(for: stats(median: 0.99, mass: 0.0, clip: 0.95),
                                            focus: sharp()), [.veryBright])
    }

    /// Each of the two exposure rules needs BOTH its conditions, or it condemns a photograph. Pinned
    /// individually so that relaxing one half fails loudly rather than quietly widening the net.
    func testNeitherHalfOfAnExposureRuleFiresAlone() {
        // Dark midpoint, but the detail is there — a low-key portrait.
        XCTAssertEqual(PhotoTriage.concerns(for: stats(median: 0.05, mass: 0.20, clip: 0.0),
                                            focus: sharp()), [])
        // Most of the frame unreadable, but the midpoint is normal — a silhouette against sky.
        XCTAssertEqual(PhotoTriage.concerns(for: stats(median: 0.45, mass: 0.75, clip: 0.0),
                                            focus: sharp()), [])
        // Bright midpoint, nothing clipped — high key on white.
        XCTAssertEqual(PhotoTriage.concerns(for: stats(median: 0.95, mass: 0.0, clip: 0.05),
                                            focus: sharp()), [])
        // Heavy clipping, normal midpoint — a bright sky behind a correctly exposed subject.
        XCTAssertEqual(PhotoTriage.concerns(for: stats(median: 0.50, mass: 0.0, clip: 0.60),
                                            focus: sharp()), [])
    }

    /// Focus leads the list, because it is the one fault no edit repairs, and only one of its two
    /// tiers is ever reported — "soft" and "not sharp" are one measurement, not two.
    func testFocusIsReportedFirstAndInOneTier() {
        let clean = stats(median: 0.45, mass: 0.01, clip: 0.0)
        XCTAssertEqual(PhotoTriage.concerns(for: clean, focus: .init(acuity: 0.8, measurable: true)),
                       [.outOfFocus])
        XCTAssertEqual(PhotoTriage.concerns(for: clean, focus: .init(acuity: 1.6, measurable: true)),
                       [.softFocus])

        let both = PhotoTriage.concerns(for: stats(median: 0.99, mass: 0.0, clip: 0.95),
                                        focus: .init(acuity: 0.8, measurable: true))
        XCTAssertEqual(both, [.outOfFocus, .veryBright],
                       "focus comes first — it is the fault the photographer can do nothing about")
    }

    /// UNMEASURABLE IS NOT BLURRED. A frame with no edges anywhere — a plain sky, a studio backdrop
    /// — gives focus nothing to judge, and `FocusMeasure` deliberately stays silent rather than
    /// guess. Triage must not turn that silence into a flag. This is not hypothetical: four frames
    /// of the measured JPEG shoot are unmeasurable, and all four are a bird against overcast sky.
    func testAFrameWithNoEdgesIsNotCalledOutOfFocus() {
        XCTAssertEqual(PhotoTriage.concerns(for: stats(median: 0.6, mass: 0.0, clip: 0.0),
                                            focus: .init(acuity: 0.0, measurable: false)),
                       [], "no reading was taken, so there is nothing to report")
    }

    // MARK: - Nothing here is a rejection

    /// The owner's rule, pinned as a test rather than left in a comment: frames are flagged for
    /// review so that false positives can be *discovered*, and nothing triage produces may read as a
    /// decision already taken. An audit in the same spirit as `CraftFixAuditTests` — it fails when
    /// someone adds a `reject` case or writes a message with a verdict in it.
    func testNoConcernReadsAsAJudgement() {
        let forbidden = ["reject", "delete", "discard", "bad", "ruin", "fail", "unusable", "worst"]
        for concern in PhotoTriage.Concern.allCases {
            XCTAssertFalse(concern.message.isEmpty, "\(concern) has no message")
            for word in forbidden {
                XCTAssertFalse(concern.message.lowercased().contains(word),
                               "\(concern.rawValue) says \"\(concern.message)\" — triage observes, "
                               + "it does not decide")
                XCTAssertFalse(concern.rawValue.lowercased().contains(word))
            }
        }
        // And an empty verdict does not claim the photograph is good, only that nothing was found.
        let clean = PhotoTriage.Verdict(concerns: [], focus: sharp(),
                                        statistics: stats(median: 0.5, mass: 0, clip: 0),
                                        signature: .unmeasurable)
        XCTAssertFalse(clean.needsReview)
        XCTAssertEqual(clean.summary, "no measured faults")
    }

    // MARK: - The fingerprint

    /// EXPOSURE INVARIANCE — the property that makes the fingerprint useful on a real shoot, where
    /// the same composition is routinely shot at two or three exposures, and where the point of
    /// grouping is to survive the edits applied afterwards.
    ///
    /// A difference hash records which of two neighbouring cells is brighter, and multiplying every
    /// cell by the same factor cannot change that ordering. Measured on seven real photographs at
    /// 1200 px, ±1 EV moved the fingerprint by 0–3 bits of 64 and a full look (contrast ×1.25,
    /// saturation ×1.4, brightness +0.08) by 0–4 — everything far inside the grouping threshold.
    func testAnExposureChangeDoesNotChangeTheFingerprint() throws {
        let base = field(seed: 7)
        let original = try XCTUnwrap(PhotoTriage.signature(of: base))
        for ev in [-1.5, -1.0, -0.5, 0.5, 1.0, 1.5] {
            let moved = try XCTUnwrap(PhotoTriage.signature(
                of: base.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])))
            XCTAssertLessThanOrEqual(original.distance(to: moved), PhotoTriage.nearDuplicateDistance,
                                     "EV \(ev) moved the fingerprint out of its own group")
        }
        // Gamma is non-linear but still monotonic, so the ordering survives it too — which covers a
        // contrast move as well as an exposure one.
        for gamma in [0.6, 1.6] {
            let moved = try XCTUnwrap(PhotoTriage.signature(
                of: base.applyingFilter("CIGammaAdjust", parameters: ["inputPower": gamma])))
            XCTAssertLessThanOrEqual(original.distance(to: moved), PhotoTriage.nearDuplicateDistance,
                                     "gamma \(gamma) moved the fingerprint out of its own group")
        }
    }

    /// The other half of the same claim, and the more important one: different photographs must stay
    /// apart. Grouping two of them together hides one, which is the failure this feature cannot
    /// afford. Measured on the seven real photographs, all 21 cross-pairs sat 24–40 bits apart, mean
    /// 32 — what theory predicts, since between unrelated frames each of the 64 bits is a coin flip.
    func testDifferentScenesDoNotGroup() throws {
        let signatures = try (1...6).map { try XCTUnwrap(PhotoTriage.signature(of: field(seed: $0))) }
        for i in 0..<signatures.count {
            for j in (i + 1)..<signatures.count {
                XCTAssertGreaterThan(signatures[i].distance(to: signatures[j]),
                                     PhotoTriage.burstDistance,
                                     "scenes \(i) and \(j) are close enough to be merged")
            }
        }
    }

    /// A frame with nothing in it must produce no opinion rather than a wrong one. On a
    /// single-colour field every comparison is decided by rounding, so two identical blanks can hash
    /// 30 bits apart while two unrelated blanks hash 2 apart — not merely weak, actively misleading.
    func testAFeaturelessFrameRefusesToBeFingerprinted() throws {
        let blank = TestSupport.makeSolidImage(r: 128, g: 128, b: 128, width: 240, height: 240)
        let signature = try XCTUnwrap(PhotoTriage.signature(of: blank))
        XCTAssertFalse(signature.isMeasurable, "contrast \(signature.contrast)")

        // Two of them do not become a pair, even though they are byte-identical.
        let pair = [PhotoTriage.Frame(url: URL(fileURLWithPath: "/a.jpg"), signature: signature),
                    PhotoTriage.Frame(url: URL(fileURLWithPath: "/b.jpg"), signature: signature)]
        XCTAssertEqual(PhotoTriage.groups(pair).count, 2,
                       "an unmeasurable fingerprint must not group with anything")

        // The floor is not so high that it silences real photographs: over 836 measured frames the
        // lowest contrast any of them produced was 0.0089 — a bald eagle against flat overcast sky —
        // against a floor of 0.004, which is one 8-bit level. A gentle gradient clears it easily.
        let gentle = try XCTUnwrap(PhotoTriage.signature(
            of: TestSupport.makeGradientImage(width: 240, height: 240)))
        XCTAssertTrue(gentle.isMeasurable, "contrast \(gentle.contrast)")
    }

    // MARK: - Grouping

    /// NO CHAINING. The reason each frame is compared against a group's *seed* rather than against
    /// all of its members.
    ///
    /// A photographer panning across a landscape produces a sequence where every frame resembles its
    /// neighbour and the two ends share nothing. Compare against all members — single-linkage
    /// clustering — and the resemblance chains: A joins B, B joins C, and the whole shoot collapses
    /// into one row with one thumbnail standing for all of it. Here the pan is explicit, and the
    /// frames are given timestamps an hour apart so the burst rule cannot mask the effect.
    func testASlowPanDoesNotCollapseIntoOneGroup() throws {
        let images = (0..<32).map { field(seed: 3, shift: Double($0) * 0.03) }
        let pan = frames(images, from: Date(timeIntervalSince1970: 0), every: 3600)

        // Sanity: the pan really is gradual, or the test proves nothing about chaining.
        let steps = zip(pan, pan.dropFirst()).map { $0.signature.distance(to: $1.signature) }
        XCTAssertLessThanOrEqual(steps.max() ?? 99, PhotoTriage.nearDuplicateDistance,
                                 "the pan is not gradual, so chaining is not being tested: \(steps)")
        // And the ends really are different pictures.
        XCTAssertGreaterThan(pan[0].signature.distance(to: pan[16].signature),
                             PhotoTriage.burstDistance,
                             "half a pan should look nothing like where it started")

        let groups = PhotoTriage.groups(pan)
        XCTAssertGreaterThan(groups.count, 1,
                             "single-linkage chaining: a pan swallowed the whole sequence")
        let first = try XCTUnwrap(groups.first { $0.contains(pan[0].url) })
        XCTAssertFalse(first.contains(pan[16].url),
                       "the start and the middle of a pan are not the same picture")
    }

    /// A burst — the same composition shot several times with only tiny drift — is what this feature
    /// exists to collapse.
    func testABurstBecomesOneGroup() {
        let burst = (0..<5).map { field(seed: 11, shift: Double($0) * 0.004) }
        let all = frames(burst + [field(seed: 12)], from: Date(timeIntervalSince1970: 0), every: 3600)
        let groups = PhotoTriage.groups(all)
        XCTAssertEqual(groups.count, 2, "\(groups.map(\.count))")
        XCTAssertEqual(groups.first?.count, 5)
        XCTAssertEqual(groups.last, [all[5].url])
    }

    /// THE BURST RULE, which exists because the fingerprint alone has poor recall on the case
    /// culling cares about most. Measured on a real 399-frame shoot: of consecutive frames taken
    /// within two seconds of each other, only 17% were within 10 bits — the median was 21. Looking
    /// at them shows the hash is not at fault. Two frames of the same man on the same beach two
    /// seconds apart, differing only in where he put his arm, measure 22 bits apart, because a
    /// subject filling the frame occupies a large share of a 9×8 grid.
    ///
    /// So frames taken moments apart are allowed a looser resemblance. The fixture below is that
    /// exact situation: one composition, a large element moved, 14 bits apart — beyond the visual
    /// threshold and inside the burst one.
    func testFramesTakenSecondsApartAreAllowedToLookLessAlike() throws {
        let a = field(seed: 31)
        // A "subject" moved across the middle of the frame: a broad dark band, one grid row high,
        // shifted sideways. Broad because that is what a person is at 9×8; anything smaller would
        // not move a single bit and the test would pass without testing anything.
        func withBand(at x: Double) -> CIImage {
            let e = a.extent
            let band = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05))
                .cropped(to: CGRect(x: e.minX + e.width * x, y: e.minY + e.height * 0.35,
                                    width: e.width * 0.30, height: e.height * 0.30))
            return band.composited(over: a)
        }
        let first = withBand(at: 0.15), second = withBand(at: 0.50)
        let d = try XCTUnwrap(PhotoTriage.signature(of: first))
            .distance(to: try XCTUnwrap(PhotoTriage.signature(of: second)))
        XCTAssertGreaterThan(d, PhotoTriage.nearDuplicateDistance,
                             "the fixture no longer reproduces the situation being tested (\(d) bits)")
        XCTAssertLessThanOrEqual(d, PhotoTriage.burstDistance, "\(d) bits")

        let moment = Date(timeIntervalSince1970: 1_000_000)
        // Two seconds apart: the same setup, so they belong together.
        XCTAssertEqual(PhotoTriage.groups(frames([first, second], from: moment, every: 2)).count, 1)
        // An hour apart: the same rule must NOT reach across a whole afternoon on a 14-bit
        // resemblance, which is well inside the range where merges were observed to be wrong.
        XCTAssertEqual(PhotoTriage.groups(frames([first, second], from: moment, every: 3600)).count, 2)
        // And with no capture date at all — a scan, or a file whose EXIF was stripped — the
        // conservative visual rule is the only one that applies.
        XCTAssertEqual(PhotoTriage.groups(frames([first, second])).count, 2)
    }

    /// The strip has to draw every photograph either way, so grouping returns a complete partition:
    /// each frame in exactly one group, input order preserved between groups and inside them. A
    /// caller wanting only the clusters filters on `count > 1`; a caller laying out the shoot can
    /// use the result directly without reconciling it against the original list.
    func testGroupingIsACompletePartitionInInputOrder() {
        // Four compositions, three frames each, interleaved — so order preservation is testable
        // independently of grouping, and timestamps an hour apart keep the burst rule out of it.
        let all = frames((0..<12).map { field(seed: 20 + ($0 % 4)) },
                         from: Date(timeIntervalSince1970: 0), every: 3600)
        let groups = PhotoTriage.groups(all)
        XCTAssertEqual(groups.flatMap { $0 }.count, all.count, "a frame was lost or duplicated")
        XCTAssertEqual(Set(groups.flatMap { $0 }), Set(all.map(\.url)))
        for group in groups {
            let indices = group.compactMap { url in all.firstIndex { $0.url == url } }
            XCTAssertEqual(indices, indices.sorted(), "input order was not preserved inside a group")
        }
        XCTAssertEqual(groups.count, 4, "four compositions, however they were interleaved")
    }

    // MARK: - Reading a real file

    /// End to end through the file path, which is where the proxy contract lives. The fast ImageIO
    /// route decodes straight to 1200 px instead of decoding the whole frame and discarding 98% of
    /// it — 120 ms against 2017 ms on a 60 MP JPEG — and triage has to reach the same verdict either
    /// way, or a fast folder scan and a slow one would disagree about the same photograph.
    func testReadingAFileAgreesWithReadingTheDecodedImage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("triage-\(UUID().uuidString).png")
        try ImageWriter.write(field(seed: 5), to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fromFile = try XCTUnwrap(PhotoTriage.read(url: url))
        let decoded = try XCTUnwrap(PhotoTriage.read(
            PerceptionProxy.downsample(try ImageDecoder.decode(url: url),
                                       maxEdge: PhotoTriage.proxyEdge)))

        XCTAssertEqual(fromFile.concerns, decoded.concerns)
        XCTAssertLessThanOrEqual(fromFile.signature.distance(to: decoded.signature), 2,
                                 "the two decode paths disagree about the composition")
        XCTAssertEqual(fromFile.statistics.medianLuma, decoded.statistics.medianLuma, accuracy: 0.02)
    }

    /// A file that cannot be read produces no verdict at all. Nil is "no opinion", never a fault —
    /// the same contract `FocusMeasure` uses for a frame it could not measure.
    func testAnUnreadableFileHasNoVerdict() {
        XCTAssertNil(PhotoTriage.read(url: URL(fileURLWithPath: "/nonexistent/not-a-photo.jpg")))
    }
}
