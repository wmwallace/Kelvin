import XCTest
@testable import KelvinCore

final class CandidateDescriptionTests: XCTestCase {

    private func recipe(_ id: String, _ edit: (inout GlobalAdjustments) -> Void) -> Recipe {
        var r = Recipe.neutral
        r.id = id
        edit(&r.global)
        return r
    }

    func testTheFaithfulOneDescribesItselfAsSuch() {
        let natural = recipe("natural") { _ in }
        XCTAssertEqual(CandidateDescription.sentence(for: natural, relativeTo: natural),
                       "True to the scene")
    }

    func testTheStrongestChangeIsSaidFirst() {
        let natural = recipe("natural") { _ in }
        let soft = recipe("soft") { g in g.contrast = -30; g.vibrance = -9 }
        XCTAssertEqual(CandidateDescription.phrases(for: soft, relativeTo: natural),
                       ["softer contrast", "quieter colour"])
        XCTAssertEqual(CandidateDescription.sentence(for: soft, relativeTo: natural),
                       "Softer contrast, quieter colour")
    }

    /// Warm is a NEGATIVE Kelvin shift on this engine's axis. Getting the direction backwards would
    /// tell a VoiceOver user the opposite of what the picture does.
    func testALowerTemperatureReadsAsWarmer() {
        let natural = recipe("natural") { g in g.temperatureK = 5600 }
        let warm = recipe("warm") { g in g.temperatureK = 5180 }
        XCTAssertEqual(CandidateDescription.phrases(for: warm, relativeTo: natural), ["warmer"])
    }

    func testSmallDifferencesAreNotClaimed() {
        let natural = recipe("natural") { _ in }
        let nearly = recipe("vivid") { g in g.contrast = 3; g.exposureEV = 0.05 }
        XCTAssertEqual(CandidateDescription.sentence(for: nearly, relativeTo: natural),
                       "Close to Natural")
    }

    func testMonoIsSaidPlainly() {
        let natural = recipe("natural") { _ in }
        var mono = recipe("mono") { g in g.contrast = 20 }
        mono.blackAndWhite = BlackAndWhiteMix(bands: [:])
        XCTAssertEqual(CandidateDescription.phrases(for: mono, relativeTo: natural), ["Black and white"])
    }
}
