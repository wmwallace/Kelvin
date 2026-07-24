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
