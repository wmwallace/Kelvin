import XCTest
@testable import KelvinCore

/// "Clamp on deserialization. Never trust a recipe from disk." (docs/RECIPE-SCHEMA.md)
final class RecipeClampingTests: XCTestCase {

    func testOutOfRangeGlobalsAreClamped() throws {
        let json = Data("""
        {
          "schema_version": 1,
          "global": {
            "exposure_ev": 99,
            "contrast": 500,
            "highlights": -900,
            "temperature_k": 50000,
            "tint": -999,
            "vibrance": -300,
            "saturation": 1000
          }
        }
        """.utf8)

        let r = try RecipeIO.decode(json)
        XCTAssertEqual(r.global.exposureEV, 5.0)       // −5…+5
        XCTAssertEqual(r.global.contrast, 100)         // −100…+100
        XCTAssertEqual(r.global.highlights, -100)
        XCTAssertEqual(r.global.temperatureK, 12000)   // 2000…12000
        XCTAssertEqual(r.global.tint, -150)            // −150…+150
        XCTAssertEqual(r.global.vibrance, -100)
        XCTAssertEqual(r.global.saturation, 100)
    }

    func testMissingFieldsDefaultToNeutral() throws {
        let json = Data("""
        { "schema_version": 1, "global": { "exposure_ev": 0.5 } }
        """.utf8)

        let r = try RecipeIO.decode(json)
        XCTAssertEqual(r.global.exposureEV, 0.5)
        XCTAssertEqual(r.global.contrast, 0)
        XCTAssertEqual(r.global.saturation, 0)
        XCTAssertNil(r.global.temperatureK, "temperature_k neutral is as-shot (nil)")
    }

    func testMaskAndDetailFieldsClamp() throws {
        let json = Data("""
        {
          "schema_version": 1,
          "detail": { "sharpen": 250, "nr_luma": -5, "nr_color": 40 },
          "masks": [
            { "id": "m1", "type": "subject", "feather": 999, "opacity": 3.0,
              "adjustments": { "exposure_ev": 0.4 } }
          ]
        }
        """.utf8)

        let r = try RecipeIO.decode(json)
        XCTAssertEqual(r.detail?.sharpen, 100)   // 0…100
        XCTAssertEqual(r.detail?.nrLuma, 0)
        XCTAssertEqual(r.detail?.nrColor, 40)
        XCTAssertEqual(r.masks?.first?.feather, 100)  // 0…100
        XCTAssertEqual(r.masks?.first?.opacity, 1.0)  // 0…1
    }

    /// A mask's adjustments are the same controls as the global ones, applied locally, so a sidecar
    /// cannot smuggle a value the global slider would refuse: `exposure_ev: 40` inside a mask used
    /// to reach `CIExposureAdjust` as forty stops. Same ranges as `Ranges`, same rule.
    func testMaskAdjustmentsClampToTheGlobalRanges() throws {
        let json = Data("""
        {
          "schema_version": 1,
          "masks": [
            { "id": "m1", "type": "subject",
              "adjustments": { "exposure_ev": 40, "contrast": -400, "highlights": 250,
                               "shadows": 101, "saturation": -1000, "vibrance": 60,
                               "temperature_k": 90000, "tint": 900, "future_key": 7 } }
          ]
        }
        """.utf8)

        let a = try XCTUnwrap(RecipeIO.decode(json).masks?.first?.adjustments)
        XCTAssertEqual(a["exposure_ev"], 5.0)
        XCTAssertEqual(a["contrast"], -100)
        XCTAssertEqual(a["highlights"], 100)
        XCTAssertEqual(a["shadows"], 100)
        XCTAssertEqual(a["saturation"], -100)
        XCTAssertEqual(a["vibrance"], 60, "an in-range value is left alone")
        XCTAssertEqual(a["temperature_k"], 12000)
        XCTAssertEqual(a["tint"], 150)
        XCTAssertEqual(a["future_key"], 7, "a key this build does not render is kept, not guessed at")
    }

    // MARK: - Schema version

    /// A recipe from a NEWER build may carry fields this one does not know. Decoding it anyway
    /// would silently drop them and render something its author never made; saving it back would
    /// destroy them. Refused with an error that says why.
    func testARecipeFromANewerSchemaIsRefused() {
        let json = Data("""
        { "schema_version": \(Recipe.currentSchemaVersion + 1), "global": { "exposure_ev": 0.5 } }
        """.utf8)
        XCTAssertThrowsError(try RecipeIO.decode(json)) { error in
            XCTAssertTrue(String(describing: error).contains("schema version"),
                          "the error must say what was wrong, got: \(error)")
        }
    }

    /// Every version this build writes, and an absent one (the oldest files), still decodes.
    func testCurrentAndMissingSchemaVersionsDecode() throws {
        let current = Data("""
        { "schema_version": \(Recipe.currentSchemaVersion), "global": { "exposure_ev": 0.5 } }
        """.utf8)
        XCTAssertEqual(try RecipeIO.decode(current).global.exposureEV, 0.5)
        let absent = Data(#"{ "global": { "exposure_ev": 0.5 } }"#.utf8)
        XCTAssertEqual(try RecipeIO.decode(absent).schemaVersion, Recipe.currentSchemaVersion)
    }

    /// Stored scene reads follow the same rule; a live read (which never carries the key) and a
    /// current one still decode.
    func testAPerceptionFromANewerSchemaIsRefused() throws {
        let newer = Data(#"{ "schema_version": \#(Perception.currentSchemaVersion + 1), "scene": "landscape" }"#.utf8)
        XCTAssertThrowsError(try PerceptionIO.decode(newer))
        let absent = Data(#"{ "scene": "landscape" }"#.utf8)
        XCTAssertEqual(try PerceptionIO.decode(absent).schemaVersion, Perception.currentSchemaVersion)
        let current = Data(#"{ "schema_version": 1, "scene": "landscape" }"#.utf8)
        XCTAssertEqual(try PerceptionIO.decode(current).scene, .landscape)
    }

    func testNeutralRecipeRoundTrips() throws {
        let data = try RecipeIO.data(for: .neutral)
        let decoded = try RecipeIO.decode(data)
        XCTAssertEqual(decoded, .neutral)
        XCTAssertTrue(decoded.global.isNeutral)
    }

    func testSchemaVersionIsPresentAfterEncoding() throws {
        let data = try RecipeIO.data(for: .neutral)
        let string = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(string.contains("\"schema_version\""),
                      "Every serialized recipe must carry a schema version")
    }
}
