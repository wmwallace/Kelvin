import XCTest
import CoreImage
@testable import KelvinCore

/// Milestone 4, part 1: the model-free perception seam — prompt, parser, proxy, provider.
/// These guard the reliability layer that a small VLM will lean on, before the model exists.
final class PerceptionSeamTests: XCTestCase {

    // MARK: - Prompt is derived from the schema

    /// Every allowed value of every closed enum must appear in the prompt. If someone adds an
    /// enum case and the prompt is still hand-maintained, this fails — proving the prompt is
    /// generated from the enums, not copied.
    func testPromptListsEveryEnumValue() {
        let p = PerceptionPrompt.instruction()
        func assertAll<T: RawRepresentable & CaseIterable>(_ t: T.Type, _: String)
        where T.RawValue == String {
            for c in T.allCases {
                XCTAssertTrue(p.contains(c.rawValue), "prompt is missing '\(c.rawValue)'")
            }
        }
        assertAll(Scene.self, "scene")
        assertAll(SubjectType.self, "subject.type")
        assertAll(SubjectCount.self, "subject.count")
        assertAll(Placement.self, "subject.placement")
        assertAll(Condition.self, "lighting.condition")
        assertAll(Direction.self, "lighting.direction")
        assertAll(ContrastRange.self, "lighting.contrast_range")
        assertAll(Problem.self, "problems")
        assertAll(Intent.self, "intent")
    }

    func testPromptForbidsProseAndNumbers() {
        let p = PerceptionPrompt.instruction().lowercased()
        XCTAssertTrue(p.contains("only") && p.contains("json"))
        XCTAssertTrue(p.contains("categor"), "prompt should tell the model it emits categories, not numbers")
    }

    // MARK: - Parser survives real model chatter

    func testParsesCleanJSON() throws {
        let raw = """
        {"scene":"portrait","subject":{"present":true,"type":"person","count":"single","placement":"center"},
         "lighting":{"condition":"backlit","direction":"back","contrast_range":"high"},
         "problems":["underexposed-subject"],"intent":"portrait-flattering","confidence":0.8}
        """
        let p = try PerceptionParser.parse(raw)
        XCTAssertEqual(p.scene, .portrait)
        XCTAssertEqual(p.subject.type, .person)
        XCTAssertEqual(p.lighting.condition, .backlit)
        XCTAssertEqual(p.problems, [.underexposedSubject])
        XCTAssertEqual(p.intent, .portraitFlattering)
    }

    func testParsesJSONInMarkdownFenceWithProse() throws {
        let raw = """
        Sure! Here is my analysis of the photograph:

        ```json
        {
          "scene": "landscape",
          "subject": {"present": false, "type": "none", "count": "none", "placement": "distributed"},
          "lighting": {"condition": "golden-hour", "direction": "side", "contrast_range": "high"},
          "problems": ["blown-highlights"],
          "intent": "natural",
          "confidence": 0.71,
          "notes": "A wide vista at sunset with a bright sky."
        }
        ```

        Let me know if you'd like anything else!
        """
        let p = try PerceptionParser.parse(raw)
        XCTAssertEqual(p.scene, .landscape)
        XCTAssertEqual(p.lighting.condition, .goldenHour)
        XCTAssertEqual(p.problems, [.blownHighlights])
        XCTAssertEqual(p.confidence, 0.71, accuracy: 0.001)
    }

    /// A brace inside a string value must not truncate the object.
    func testBraceInsideStringDoesNotTruncate() throws {
        let raw = #"{"scene":"street","subject":{"present":true,"type":"person","count":"few","placement":"center"},"lighting":{"condition":"indoor-mixed","direction":"front","contrast_range":"normal"},"problems":[],"intent":"documentary","confidence":0.5,"notes":"a sign reads {OPEN}"}"#
        let p = try PerceptionParser.parse(raw)
        XCTAssertEqual(p.scene, .street)
        XCTAssertEqual(p.notes, "a sign reads {OPEN}")
    }

    /// Unknown enum tokens fall back; unknown problems are dropped (schema-level lenience,
    /// surfaced through the parser).
    func testUnknownTokensAreHandledGracefully() throws {
        let raw = """
        {"scene":"teleportation","subject":{"present":true,"type":"robot","count":"single","placement":"center"},
         "lighting":{"condition":"plasma","direction":"back","contrast_range":"high"},
         "problems":["blown-highlights","time-travel-blur"],"intent":"cyberpunk","confidence":1.5}
        """
        let p = try PerceptionParser.parse(raw)
        XCTAssertEqual(p.scene, .other)                 // unknown → fallback
        XCTAssertEqual(p.subject.type, .none)
        XCTAssertEqual(p.lighting.condition, .indoorDaylight)
        XCTAssertEqual(p.intent, .natural)
        XCTAssertEqual(p.problems, [.blownHighlights])  // stray problem dropped
        XCTAssertEqual(p.confidence, 1.0)               // clamped to 0...1
    }

    func testThrowsWhenNoObjectPresent() {
        XCTAssertThrowsError(try PerceptionParser.parse("I cannot analyze this image."))
    }

    // MARK: - Proxy

    func testProxyCapsLongEdgeAndPreservesAspect() {
        let wide = TestSupport.makeSolidImage(r: 10, g: 20, b: 30, width: 4000, height: 2000)
        let proxy = PerceptionProxy.downsample(wide, maxEdge: 768)
        XCTAssertEqual(max(proxy.extent.width, proxy.extent.height), 768, accuracy: 1.5)
        // 2:1 aspect preserved.
        XCTAssertEqual(proxy.extent.width / proxy.extent.height, 2.0, accuracy: 0.02)
    }

    func testProxyNeverUpscales() {
        let small = TestSupport.makeSolidImage(r: 0, g: 0, b: 0, width: 320, height: 240)
        let proxy = PerceptionProxy.downsample(small, maxEdge: 768)
        XCTAssertEqual(proxy.extent.width, 320, accuracy: 0.5)
        XCTAssertEqual(proxy.extent.height, 240, accuracy: 0.5)
    }

    // MARK: - Provider drives the pipeline end to end (no model)

    func testStaticProviderFeedsEngine() async throws {
        let percept = Perception(
            scene: .landscape,
            subject: .absent,
            lighting: Perception.Lighting(condition: .overcast, direction: .diffuse, contrastRange: .low),
            problems: [.flat], intent: .natural, confidence: 0.9
        )
        let provider: PerceptionProvider = StaticPerceptionProvider(percept)

        let image = TestSupport.makeGradientImage(width: 64, height: 64)
        let read = try await provider.perceive(PerceptionProxy.downsample(image))
        let stats = try ImageStatistics.compute(image)
        let recipe = RecipeEngine.recipe(perception: read, statistics: stats)

        XCTAssertEqual(recipe.label, "Natural")   // proves the whole seam → engine path runs
    }
}
