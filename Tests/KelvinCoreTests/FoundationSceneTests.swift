import XCTest
@testable import KelvinCore

/// D33: what of the on-device Foundation Model's scene read reaches a `Perception`, and what does
/// not. The model itself is never called here — CI has no image-capable model — so these pin the
/// pure mapping, which is where the decision lives.
final class FoundationSceneTests: XCTestCase {

    private let noFace = FaceSkin.Reading(faceCount: 0, skinLuma: nil, skinHueDegrees: nil,
                                          skinSaturation: nil, skinRange: nil,
                                          skinClipHigh: nil, skinClipLow: nil)

    /// What `VisionPerceptionProvider` returns for every frame: scene `.other`, the constant light.
    private func visionRead() -> Perception {
        VisionPerceptionProvider.perception(from: .init())
    }

    private func stats(chromaA: Double = 0, chromaB: Double = 0) -> ImageStatistics {
        ImageStatistics(meanLuma: 0.46, medianLuma: 0.46, blackPoint: 0.02, shadowLevel: 0.1,
                        highlightLevel: 0.85, whitePoint: 0.97, highlightClip: 0, shadowClip: 0,
                        chromaA: chromaA, chromaB: chromaB)
    }

    // MARK: Indoors

    /// The Thanksgiving living room: SkyMask found a "sky" in it, and with the scene constant at
    /// `.other` the engine treated the room as outdoors and darkened part of it. An indoor judgment
    /// makes the scene `.interior`, and the sky lever's existing outdoor gate does the rest.
    func testIndoorsBecomesInteriorAndTheSkyMaskStops() {
        let read = FoundationSceneRead(indoors: true, skyVisible: false, light: .tungsten)
        let p = FoundationEnrichment.apply(read, to: visionRead(), interior: true, warmLight: true)
        XCTAssertEqual(p.scene, .interior)
        XCTAssertNotNil(RecipeEngine.skyMask(visionRead(), stats(), skyLuma: 0.7, style: .dramatic),
                        "precondition: the constant Vision read lets a found sky through")
        for style in CandidateStyle.all {
            XCTAssertNil(RecipeEngine.skyMask(p, stats(), skyLuma: 0.7, style: style),
                         "\(style.id) still put a sky mask in a room the model judged indoors")
        }
    }

    func testOutdoorsLeavesTheSceneAlone() {
        let read = FoundationSceneRead(indoors: false, skyVisible: true, light: .daylight)
        XCTAssertEqual(FoundationEnrichment.apply(read, to: visionRead()).scene, .other)
    }

    /// A scene something else decided (a hand label, the classifier arm) is never overwritten.
    func testAnExistingSceneIsNeverOverwritten() {
        var base = visionRead(); base.scene = .portrait
        let read = FoundationSceneRead(indoors: true, skyVisible: false, light: .flash)
        XCTAssertEqual(FoundationEnrichment.apply(read, to: base).scene, .portrait)
    }

    func testTheInteriorFillCanBeSwitchedOff() {
        let read = FoundationSceneRead(indoors: true, skyVisible: false, light: .tungsten)
        XCTAssertEqual(FoundationEnrichment.apply(read, to: visionRead(), interior: false).scene, .other)
    }

    // MARK: Light

    /// Golden hour and firelight outdoors are written; the Fix button then stops offering to take
    /// the light out of the photograph.
    func testWarmOutdoorLightReachesTheCastFlag() {
        let warm = stats(chromaA: 4.44, chromaB: 23.26)
        XCTAssertTrue(CraftFix.Reading(stats: warm, face: noFace,
                                       condition: visionRead().lighting.condition)
                        .issues.contains(.colorCast), "precondition: flagged on the constant read")
        for light in [FoundationSceneRead.Light.goldenHour, .firelight, .night] {
            let p = FoundationEnrichment.apply(
                FoundationSceneRead(indoors: false, skyVisible: true, light: light), to: visionRead())
            let reading = CraftFix.Reading(stats: warm, face: noFace, condition: p.lighting.condition)
            XCTAssertFalse(reading.issues.contains(.colorCast), "\(light) should excuse warmth")
        }
    }

    /// Indoors the model called every room tungsten — daylit, flash-lit or lamp-lit (9 of 25 right)
    /// — so an indoor light carries nothing and is never written.
    func testIndoorLightIsNeverWritten() {
        for light in FoundationSceneRead.Light.allCases {
            let p = FoundationEnrichment.apply(
                FoundationSceneRead(indoors: true, skyVisible: false, light: light), to: visionRead())
            XCTAssertEqual(p.lighting.condition, visionRead().lighting.condition, "\(light) indoors")
        }
    }

    /// Only the three lights that measured are written; daylight, overcast, flash, mixed and blue
    /// hour leave the constant alone (blue hour was never answered, so it was never measured).
    func testOnlyMeasuredOutdoorLightsAreWritten() {
        let written: Set<FoundationSceneRead.Light> = [.goldenHour, .firelight, .night]
        for light in FoundationSceneRead.Light.allCases where !written.contains(light) {
            let p = FoundationEnrichment.apply(
                FoundationSceneRead(indoors: false, skyVisible: true, light: light), to: visionRead())
            XCTAssertEqual(p.lighting.condition, .indoorDaylight, "\(light) should not be written")
        }
        XCTAssertEqual(FoundationEnrichment.apply(
            FoundationSceneRead(indoors: false, skyVisible: true, light: .firelight),
            to: visionRead()).lighting.condition, .nightAmbient)
    }

    func testTheLightFillCanBeSwitchedOff() {
        let p = FoundationEnrichment.apply(
            FoundationSceneRead(indoors: false, skyVisible: true, light: .goldenHour),
            to: visionRead(), warmLight: false)
        XCTAssertEqual(p.lighting.condition, .indoorDaylight)
    }

    /// Nothing else the model says reaches the read: subject, intent, problems and notes are
    /// Vision's, untouched.
    func testOnlySceneAndLightAreEverTouched() {
        var base = visionRead()
        base.notes = "Vision's words"
        let p = FoundationEnrichment.apply(
            FoundationSceneRead(indoors: true, skyVisible: true, light: .goldenHour), to: base)
        XCTAssertEqual(p.subject, base.subject)
        XCTAssertEqual(p.intent, base.intent)
        XCTAssertEqual(p.problems, base.problems)
        XCTAssertEqual(p.notes, base.notes)
        XCTAssertEqual(p.confidence, base.confidence)
    }

    // MARK: Mapping and identity

    /// Every word the model may answer lands on a `Condition` that already exists — no new
    /// perception category.
    func testEveryLightMapsOntoTheExistingVocabulary() {
        for light in FoundationSceneRead.Light.allCases {
            for indoors in [true, false] {
                let c = FoundationSceneRead(indoors: indoors, skyVisible: false, light: light).condition
                XCTAssertTrue(Condition.allCases.contains(c))
            }
        }
        XCTAssertEqual(FoundationSceneRead(indoors: true, skyVisible: false, light: .firelight).condition,
                       .indoorTungsten)
        XCTAssertEqual(FoundationSceneRead(indoors: false, skyVisible: false, light: .firelight).condition,
                       .nightAmbient)
    }

    /// Where the model cannot run, the enriched provider IS the Vision provider — same identifier,
    /// so the Vision reads already in `PerceptionStore` keep being served.
    func testWithoutTheModelTheIdentifierIsVisions() {
        let provider = EnrichedPerceptionProvider()
        if EnrichedPerceptionProvider.enrichmentActive {
            XCTAssertTrue(provider.identifier.hasPrefix(provider.base.identifier + "+apple-fm-scene-"))
            XCTAssertNotEqual(provider.identifier, provider.base.identifier)
        } else {
            XCTAssertEqual(provider.identifier, provider.base.identifier)
        }
    }

    /// The stored judgment round-trips, under the snake_case keys every other scene field uses.
    func testTheReadRoundTrips() throws {
        let read = FoundationSceneRead(indoors: false, skyVisible: true, light: .goldenHour)
        let data = try JSONEncoder().encode(read)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"sky_visible\""))
        XCTAssertEqual(try JSONDecoder().decode(FoundationSceneRead.self, from: data), read)
    }
}

/// D34: the model's sky judgment, carried in `Perception.sky` and read only by the sky lever.
final class SkyJudgmentTests: XCTestCase {
    private func vision() -> Perception {
        Perception(scene: .other,
                   subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
                   lighting: .unknown, problems: [], intent: .natural, confidence: 0.9)
    }
    private func stats() -> ImageStatistics {
        ImageStatistics(meanLuma: 0.5, medianLuma: 0.5, blackPoint: 0.02, shadowLevel: 0.1,
                        highlightLevel: 0.9, whitePoint: 0.95, highlightClip: 0.0, shadowClip: 0,
                        chromaA: 0, chromaB: 0)
    }

    func testTheJudgmentIsWrittenFromTheRead() {
        let none = FoundationEnrichment.apply(FoundationSceneRead(indoors: false, skyVisible: false, light: .daylight),
                                              to: vision())
        XCTAssertEqual(none.sky, Perception.SkyJudgment.notVisible)
        let seen = FoundationEnrichment.apply(FoundationSceneRead(indoors: false, skyVisible: true, light: .daylight),
                                              to: vision())
        XCTAssertEqual(seen.sky, .visible)
        let off = FoundationEnrichment.apply(FoundationSceneRead(indoors: false, skyVisible: false, light: .daylight),
                                             to: vision(), sky: false)
        XCTAssertNil(off.sky)
    }

    func testNoSkyJudgedMeansNoSkyMaskWhateverSkyMaskFound() {
        var p = vision()
        XCTAssertNotNil(RecipeEngine.skyMask(p, stats(), skyLuma: 0.8), "unjudged: SkyMask's sky stands")
        p.sky = Perception.SkyJudgment.notVisible
        XCTAssertNil(RecipeEngine.skyMask(p, stats(), skyLuma: 0.8))
        p.sky = .visible
        XCTAssertNotNil(RecipeEngine.skyMask(p, stats(), skyLuma: 0.8))
    }

    func testAReadStoredBeforeTheFieldIsUnjudged() throws {
        let json = #"{"schema_version":1,"scene":"other","intent":"natural","confidence":0.9}"#
        XCTAssertNil(try JSONDecoder().decode(Perception.self, from: Data(json.utf8)).sky)
        let odd = #"{"schema_version":1,"scene":"other","sky":"maybe"}"#
        XCTAssertNil(try JSONDecoder().decode(Perception.self, from: Data(odd.utf8)).sky,
                     "an unknown value is unjudged, not an error")
    }
}
