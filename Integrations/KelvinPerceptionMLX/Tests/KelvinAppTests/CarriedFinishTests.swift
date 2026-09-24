import XCTest
import KelvinCore
@testable import KelvinApp

/// The hero's finish carried across a shoot (D30): which frames the record hands it to, and that it
/// can never cost the shoot its look. The solve itself is `ResultMatchTests` in the core package.
@MainActor
final class CarriedFinishTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/shoot/\(name)") }

    private func intent(lightness: Double = 4) -> ResultMatch.Intent {
        var i = ResultMatch.Intent()
        i.lightness = lightness
        return i
    }

    func testTheWholeShootCarriesTheHerosFinish() {
        let a = url("a.ARW"), b = url("b.ARW")
        let look = ShootLook().applying("soft", to: [a, b], inShootOf: [a, b])
            .attaching(intent(), source: "a.ARW", to: [a, b], inShootOf: [a, b])
        XCTAssertEqual(look.intent(for: a), intent())
        XCTAssertEqual(look.intent(for: b), intent())
        XCTAssertEqual(look.intentSource, "a.ARW")
    }

    /// An override is a whole choice (D29's rule, carried): a frame singled out gets its own
    /// apply's finish, or none — never the shoot's.
    func testAnOverrideCarriesItsOwnFinishOrNone() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        var look = ShootLook().applying("soft", to: [a, b, c], inShootOf: [a, b, c])
            .attaching(intent(), source: "a.ARW", to: [a, b, c], inShootOf: [a, b, c])
        look = look.applying("vivid", to: [c], inShootOf: [a, b, c])
        XCTAssertNil(look.intent(for: c), "singled out without adjustments: none")
        XCTAssertEqual(look.intent(for: a), intent(), "the rest keep the shoot's")
        look = look.attaching(intent(lightness: -3), source: "c.ARW", to: [c], inShootOf: [a, b, c])
        XCTAssertEqual(look.intent(for: c), intent(lightness: -3))
    }

    func testANewApplyIsANewChoice() {
        let a = url("a.ARW"), b = url("b.ARW")
        let first = ShootLook().applying("soft", to: [a, b], inShootOf: [a, b])
            .attaching(intent(), source: "a.ARW", to: [a, b], inShootOf: [a, b])
        let second = first.applying("vivid", to: [a, b], inShootOf: [a, b])
        XCTAssertNil(second.intent(for: a), "the previous hero's adjustments do not survive a re-apply")
        XCTAssertNil(second.intentSource)
    }

    func testANeutralFinishIsNotRecorded() {
        let a = url("a.ARW")
        let look = ShootLook().applying("soft", to: [a], inShootOf: [a])
            .attaching(ResultMatch.Intent(), source: "a.ARW", to: [a], inShootOf: [a])
        XCTAssertNil(look.intent)
    }

    func testNoStyleNoFinish() {
        let a = url("a.ARW")
        let look = ShootLook(style: nil, intent: intent())
        XCTAssertNil(look.intent(for: a), "a finish only ever rides on a style")
    }

    func testTheRecordRoundTripsAndOldRecordsStillDecode() throws {
        let a = url("a.ARW")
        let look = ShootLook().applying("soft", look: "portra", to: [a], inShootOf: [a])
            .attaching(intent(), source: "a.ARW", to: [a], inShootOf: [a])
        let back = try JSONDecoder().decode(ShootLook.self, from: JSONEncoder().encode(look))
        XCTAssertEqual(back, look)

        let legacy = #"{"version":1,"style":"soft","overrides":{},"appliedAt":"2026-08-22T01:42:02Z"}"#
        let old = try JSONDecoder().decode(ShootLook.self, from: Data(legacy.utf8))
        XCTAssertEqual(old.style, "soft")
        XCTAssertNil(old.intent)
    }

    /// A finish that no longer decodes costs the carry, never the shoot's look.
    func testAnUnreadableFinishCostsOnlyTheCarry() throws {
        let broken = #"{"version":1,"style":"soft","lookId":"portra","intent":{"lightness":"bright"}}"#
        let look = try JSONDecoder().decode(ShootLook.self, from: Data(broken.utf8))
        XCTAssertEqual(look.style, "soft")
        XCTAssertEqual(look.lookId, "portra")
        XCTAssertNil(look.intent)
    }

    func testSwitchingTheCarryOffHidesItWithoutForgettingIt() {
        let a = url("a.ARW")
        let s = AppState()
        s.folderPhotos = [a]
        s.shootLook = ShootLook().applying("soft", to: [a], inShootOf: [a])
            .attaching(intent(), source: "a.ARW", to: [a], inShootOf: [a])
        let was = s.carryAdjustments
        defer { s.carryAdjustments = was }
        s.carryAdjustments = false
        XCTAssertNil(s.effectiveIntent(for: a))
        XCTAssertNotNil(s.shootLook?.intent, "the record keeps it")
        s.carryAdjustments = true
        XCTAssertEqual(s.effectiveIntent(for: a), intent())
    }
}
