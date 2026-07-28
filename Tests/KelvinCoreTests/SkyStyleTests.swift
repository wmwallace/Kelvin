import XCTest
@testable import KelvinCore

/// A style has to be able to treat a sky differently, or several of these looks mean nothing
/// outdoors.
///
/// `localMasks` took no style, so every candidate emitted a byte-identical sky mask carrying
/// `saturation: +12` and nothing else. Measured on a cumulus landscape, deleting that mask from a
/// finished Dramatic render moved the pixels by a maximum of 4 levels out of 255 — the sky was
/// effectively untreated, and "Dramatic gives no drama" was a precise description of it.
///
/// The global layer cannot stand in: `CIColorControls` pivots contrast at 0.5 and a sky sits near
/// 0.71, so global contrast makes a sky *brighter*. A grad-ND through the sky mask is the move.
final class SkyStyleTests: XCTestCase {

    private func stats(medianLuma: Double = 0.46, blackPoint: Double = 0.02,
                       highlightClip: Double = 0) -> ImageStatistics {
        ImageStatistics(
            meanLuma: medianLuma, medianLuma: medianLuma,
            blackPoint: blackPoint, shadowLevel: 0.1, highlightLevel: 0.85, whitePoint: 0.97,
            highlightClip: highlightClip, shadowClip: 0, chromaA: 0, chromaB: 0
        )
    }

    private func landscape(problems: [Problem] = []) -> Perception {
        Perception(
            scene: .landscape,
            subject: Perception.Subject(present: false, type: .none, count: .none,
                                        placement: .center),
            lighting: Perception.Lighting(condition: .overcast, direction: .diffuse,
                                          contrastRange: .normal),
            problems: problems, intent: .natural, confidence: 0.9
        )
    }

    /// An ordinary, correctly-exposed blue sky — the case the complaint was about. Not blown, not
    /// veiled, so the only thing acting on it is the style.
    private func sky(_ style: CandidateStyle) -> Mask? {
        RecipeEngine.skyMask(landscape(), stats(), skyLuma: 0.68, style: style)
    }

    // MARK: The styles must actually differ

    /// THE BUG, stated once. Two looks that a photographer would describe in opposite terms must
    /// not serialise the same sky.
    func testDramaticAndAiryDoNotEmitTheSameSky() throws {
        let dramatic = try XCTUnwrap(sky(.dramatic))
        let airy = try XCTUnwrap(sky(.airy))
        XCTAssertNotEqual(dramatic.adjustments, airy.adjustments,
                          "every style emitted an identical sky mask; that is the whole defect")
    }

    /// And not just those two — a set of looks that all treat the sky alike is a picker offering
    /// one choice with eight names on it.
    func testTheStylesOfferGenuinelyDifferentSkies() {
        let skies = CandidateStyle.all.compactMap { sky($0)?.adjustments }
        XCTAssertEqual(skies.count, CandidateStyle.all.count)
        let distinct = Set(skies.map { adj in
            adj.keys.sorted().map { "\($0)=\(adj[$0] ?? 0)" }.joined(separator: ",")
        })
        XCTAssertGreaterThanOrEqual(distinct.count, 5,
                                    "only \(distinct.count) distinct skies across eight styles")
    }

    // MARK: Each style's sky is the one its name promises

    /// Dramatic pulls a sky DOWN. That is the grad-ND, and it is the thing that was missing.
    func testDramaticDarkensTheSky() throws {
        let adj = try XCTUnwrap(sky(.dramatic)).adjustments
        let ev = try XCTUnwrap(adj["exposure_ev"])
        XCTAssertLessThan(ev, -0.3, "Dramatic's sky is not being pulled down at all")
        XCTAssertGreaterThan(try XCTUnwrap(adj["contrast"]), 10,
                             "a dramatic sky needs cloud structure, not just darkness")
    }

    /// Airy is the high-key answer and opens a sky UP. If both ends of the range moved the same
    /// direction the field would be a strength control, not a character.
    func testAiryOpensTheSkyRatherThanDarkeningIt() throws {
        let ev = try XCTUnwrap(try XCTUnwrap(sky(.airy)).adjustments["exposure_ev"])
        XCTAssertGreaterThan(ev, 0, "Airy should lift a sky, not pull it down")
    }

    /// The faithful rendering has no opinion, by definition — so it emits the corrective sky and
    /// nothing more. This is what keeps Natural a reference the others depart from.
    func testNaturalAddsNoStyleOfItsOwn() throws {
        let adj = try XCTUnwrap(sky(.natural)).adjustments
        XCTAssertNil(adj["exposure_ev"], "the faithful rendering acquired a sky opinion")
        XCTAssertNil(adj["contrast"])
    }

    /// Vivid is colour-led: it should reach for saturation well before it reaches for darkness.
    func testVividLeadsWithColourNotDarkness() throws {
        let vivid = try XCTUnwrap(sky(.vivid)).adjustments
        let dramatic = try XCTUnwrap(sky(.dramatic)).adjustments
        XCTAssertGreaterThan(try XCTUnwrap(vivid["saturation"]),
                             try XCTUnwrap(dramatic["saturation"]))
        XCTAssertGreaterThan(try XCTUnwrap(vivid["exposure_ev"]),
                             try XCTUnwrap(dramatic["exposure_ev"]))
    }

    // MARK: The corrective work stays shared

    /// Recovering a blown sky is a fix, not a taste. Every style must still do it, or the style
    /// layer has quietly taken over a correction.
    func testEveryStyleStillRecoversABlownSky() throws {
        for style in CandidateStyle.all {
            let adj = try XCTUnwrap(
                RecipeEngine.skyMask(landscape(problems: [.blownHighlights]), stats(),
                                     skyLuma: 0.88, style: style)).adjustments
            XCTAssertLessThan(try XCTUnwrap(adj["highlights"]), 0,
                              "\(style.id) stopped recovering a blown sky")
        }
    }

    /// Indoors there is no sky to have an opinion about, however dramatic the style.
    func testNoSkyMaskIndoorsWhateverTheStyle() {
        let indoor = Perception(
            scene: .portrait,
            subject: Perception.Subject(present: true, type: .person, count: .single,
                                        placement: .center),
            lighting: Perception.Lighting(condition: .indoorDaylight, direction: .diffuse,
                                          contrastRange: .normal),
            problems: [], intent: .natural, confidence: 0.9)
        for style in CandidateStyle.all {
            XCTAssertNil(RecipeEngine.skyMask(indoor, stats(), skyLuma: 0.7, style: style),
                         "\(style.id) put a sky mask on an indoor portrait")
        }
    }

    /// A mask that serialises `{"contrast": 0}` claims an edit that renders as nothing. Drop them.
    func testNoZeroValuedAdjustmentsAreSerialised() throws {
        for style in CandidateStyle.all {
            guard let adj = sky(style)?.adjustments else { continue }
            for (key, value) in adj {
                XCTAssertNotEqual(value, 0, "\(style.id) emitted \(key) = 0")
            }
        }
    }

    /// The style reaches the recipe, not just the mask function — the wiring is the bug's other
    /// half, since `localMasks` is what `candidate` actually calls.
    func testTheStyleReachesTheRecipesSkyMask() throws {
        func skyOf(_ style: CandidateStyle) throws -> Mask {
            let r = RecipeEngine.candidate(perception: landscape(), statistics: stats(),
                                           style: style, skyLuma: 0.68)
            return try XCTUnwrap(r.masks?.first { $0.type == "sky" })
        }
        XCTAssertNotEqual(try skyOf(.dramatic).adjustments, try skyOf(.airy).adjustments,
                          "the style is not reaching the sky mask through `candidate`")
    }

    // MARK: Restraint

    /// A grad-ND is half a stop to a stop in the hand. Nothing here should exceed that — the whole
    /// point of doing this through a mask is that it stays a photographic move.
    ///
    /// **This used to assert on the EV written into the mask, and that is the wrong quantity.** An
    /// EV in a mask is not an EV in the picture: it is scaled by the mask's alpha, blended, and
    /// partly offset by the contrast the same mask carries. Measured, `skyDepth: 1.0` at 1.4 EV
    /// delivers **0.31 of a stop** on the fixture below and **0.41** on real Cannon Beach frames —
    /// so the parameter is roughly three times the effect, and an assertion on the parameter says
    /// almost nothing about whether the result is a photographic move.
    ///
    /// So the bound below is on the parameter as a sanity rail, and the test underneath it measures
    /// what actually reaches the pixels.
    func testNoStyleTakesTheSkyFurtherThanAGradFilterWould() throws {
        for style in CandidateStyle.all {
            guard let adj = sky(style)?.adjustments else { continue }
            if let ev = adj["exposure_ev"] {
                XCTAssertLessThanOrEqual(abs(ev), 1.8, "\(style.id) moved the sky \(ev) EV")
            }
            if let sat = adj["saturation"] {
                XCTAssertLessThanOrEqual(sat, 36, "\(style.id) pushed sky saturation to \(sat)")
            }
        }
    }

    /// What the lever actually delivers, in the units a photographer would state it in.
    ///
    /// Two-sided on purpose. The original bug was a lever that did NOTHING — every candidate
    /// emitted a byte-identical sky mask — so a floor guards against it going inert again, and a
    /// ceiling guards against a grad filter becoming a special effect. A solid synthetic sky gives
    /// the mask close to full alpha, which is the strongest the lever can ever be: no photograph
    /// gets more than this.
    func testTheSkyPullThatReachesThePixelsIsAGradFilter() throws {
        let image = TestSupport.pixels(size: 240) { _, y in
            y < 120 ? (150, 180, 230) : (60, 110, 60)
        }
        let measured = LocalMasks.measure(in: image)
        XCTAssertNotNil(measured.bitmaps["sky"], "no sky mask, so this measures nothing")

        let recipe = RecipeEngine.candidate(perception: landscape(), statistics: stats(),
                                            style: .dramatic, skyLuma: measured.skyLuma ?? 0.68)
        let region = try SkyMetrics.referenceRegion(in: image)
        let withMask = try XCTUnwrap(
            SkyMetrics.read(Renderer.render(image, with: recipe, maskBitmaps: measured.bitmaps),
                            in: region))
        let globalOnly = try XCTUnwrap(
            SkyMetrics.read(Renderer.render(image, with: recipe), in: region))

        // Display-referred luma, so a stop is a factor of 2^(1/2.2) ≈ 1.37 rather than 2.
        // Measured −0.31 here and −0.41 on real frames; the bounds are wide enough that a
        // recalibration does not have to touch this test, and tight enough that a lever going
        // inert (the original bug) or turning into an effect both fail it.
        let delivered = log2(pow(withMask.meanLuma / globalOnly.meanLuma, 2.2))
        XCTAssertLessThan(delivered, -0.15,
                          "the sky lever delivers only \(delivered) stops — it has gone inert again")
        XCTAssertGreaterThan(delivered, -1.0,
                             "the sky lever delivers \(delivered) stops, which is no longer a filter")
    }
}

/// The subject mask's feather is a fraction of the FRAME, so the number it carries decides how far
/// a local adjustment spills past the silhouette. At 35 it spilled ~380 px on a 60 MP export, which
/// is the halo that was reported.
final class SubjectFeatherTests: XCTestCase {

    private func backlitPortrait() -> Mask? {
        let p = Perception(
            scene: .portrait,
            subject: Perception.Subject(present: true, type: .person, count: .single,
                                        placement: .center),
            lighting: Perception.Lighting(condition: .harshSun, direction: .back,
                                          contrastRange: .high),
            problems: [.underexposedSubject], intent: .natural, confidence: 0.9)
        let s = ImageStatistics(
            meanLuma: 0.62, medianLuma: 0.62, blackPoint: 0.02, shadowLevel: 0.1,
            highlightLevel: 0.9, whitePoint: 0.98, highlightClip: 0.01, shadowClip: 0,
            chromaA: 0, chromaB: 0)
        return RecipeEngine.subjectMask(p, s, subjectLuma: 0.22)
    }

    /// Stated in the units that matter: how far, in pixels of a real export, does the lift bleed?
    func testTheSubjectLiftDoesNotBleedAcrossTheFrame() throws {
        let feather = try XCTUnwrap(backlitPortrait()).feather
        // `Renderer.prepareMask`: radius = feather/100 * minEdge * 0.06.
        let radiusOn60MP = feather / 100.0 * 6336.0 * 0.06
        XCTAssertLessThan(radiusOn60MP, 40,
                          "the subject lift feathers over \(Int(radiusOn60MP)) px on a 60 MP "
                          + "frame — that is the halo")
    }

    /// The floor matters too: a mask upscaled from Vision's fixed 512×384 buffer needs *some*
    /// feather or the boundary shows the upscale's stair-stepping.
    func testTheSubjectEdgeIsStillSoftened() throws {
        XCTAssertGreaterThan(try XCTUnwrap(backlitPortrait()).feather, 2)
    }

    /// The sky's feather is one grid cell of its own mask — no more, no less.
    ///
    /// This asserted `> 30` when the sky mask carried 45, on the reasoning that a horizon genuinely
    /// is a gradual transition. That reasoning holds for a horizon and fails for a sea stack: the
    /// feather is a fraction of the FRAME, so 45 blurs 171 px on a 60 MP export while `SkyMask`'s
    /// own cells are 59 px there — nearly three cells, which rings anything standing up into the
    /// sky with a halo of undarkened sky. Both bounds below are that arithmetic: enough to smooth
    /// one cell's stair-stepping, not enough to reach past it.
    func testTheSkyFeatherIsAboutOneMaskCell() throws {
        let p = Perception(
            scene: .landscape,
            subject: Perception.Subject(present: false, type: .none, count: .none,
                                        placement: .center),
            lighting: Perception.Lighting(condition: .overcast, direction: .diffuse,
                                          contrastRange: .normal),
            problems: [], intent: .natural, confidence: 0.9)
        let s = ImageStatistics(
            meanLuma: 0.46, medianLuma: 0.46, blackPoint: 0.02, shadowLevel: 0.1,
            highlightLevel: 0.85, whitePoint: 0.97, highlightClip: 0, shadowClip: 0,
            chromaA: 0, chromaB: 0)
        let sky = try XCTUnwrap(RecipeEngine.skyMask(p, s, skyLuma: 0.68, style: .dramatic))
        // radius = feather/100 × minEdge × 0.06, against a 160-cell grid on a 6336 px short edge.
        let radiusOn60MP = sky.feather / 100.0 * 6336.0 * 0.06
        let cellOn60MP = 9504.0 / 160.0
        XCTAssertGreaterThan(radiusOn60MP, cellOn60MP * 0.6,
                             "\(Int(radiusOn60MP)) px will not smooth a \(Int(cellOn60MP)) px cell")
        XCTAssertLessThan(radiusOn60MP, cellOn60MP * 1.5,
                          "\(Int(radiusOn60MP)) px reaches past the cell — that is the halo")
    }
}
