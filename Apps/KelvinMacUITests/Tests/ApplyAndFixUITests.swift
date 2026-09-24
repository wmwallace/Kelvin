import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The flows that have gone wrong in front of the owner, driven through the real app: a look applied
/// to a shoot (and the check it shows first), and a Fix that must always say what it did. These
/// exist because both failures were silent — nothing crashed, a button just did nothing — and the
/// only way to catch a silent control is to press it.
///
/// Every test works on its own throwaway shoot of generated photographs, so nothing of anyone's
/// library is read or written. Records the app keeps (the shoot look, edits) are keyed by that
/// throwaway path and are inert once it is gone.
@MainActor
final class ApplyAndFixUITests: XCTestCase {

    private var shoot: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        shoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-ui-shoot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        // Twelve frames, darkest to brightest, a bright sky over a dark foreground in the middle ones
        // — enough spread for the shoot check to find frames unlike the first.
        for i in 0..<12 {
            try Self.writeFrame(shoot.appendingPathComponent(String(format: "frame%02d.jpg", i)),
                                brightness: 0.15 + Double(i) * 0.07, sky: (4...7).contains(i))
        }
        guard let path = ProcessInfo.processInfo.environment["KELVIN_UI_APP"] else {
            throw XCTSkip("KELVIN_UI_APP is not set — run through `make ui-test`")
        }
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchEnvironment["KELVIN_DEMO_IMAGE"] = shoot.appendingPathComponent("frame00.jpg").path
        // The check is ON for these tests whatever the machine's own setting says (argument domain).
        app.launchArguments += ["-shoot.checkBeforeApply", "YES", "-shoot.carryAdjustments", "YES"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let shoot { try? FileManager.default.removeItem(at: shoot) }
    }

    private var status: XCUIElement { app.staticTexts["status"] }

    private func waitForLooks() {
        XCTAssertTrue(app.descendants(matching: .any)["candidate.natural"].waitForExistence(timeout: 90),
                      "the photograph never offered its looks")
    }

    func testAPhotographOpensWithItsLooks() {
        waitForLooks()
        XCTAssertTrue(status.exists)
    }

    func testApplyShowsTheCheckAndCancelChangesNothing() {
        waitForLooks()
        app.descendants(matching: .any)["apply"].click()
        let cancel = app.buttons["check.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 30), "Apply on a 12-frame shoot shows the check first")
        cancel.click()
        XCTAssertFalse(app.buttons["check.cancel"].waitForExistence(timeout: 2))
        XCTAssertFalse((status.value as? String ?? status.label).contains("This shoot is in"),
                       "cancelling the check applied the look anyway")
    }

    func testApplyingFromTheCheckPutsTheLookOnTheShoot() {
        waitForLooks()
        app.descendants(matching: .any)["apply"].click()
        let apply = app.buttons["check.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 30))
        apply.click()
        let predicate = NSPredicate(format: "label CONTAINS 'This shoot is in' OR value CONTAINS 'This shoot is in'")
        wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: status)], timeout: 20)
    }

    /// A Fix that changes nothing must still say so — the bug this test is for was a Fix that did
    /// nothing and said nothing.
    func testEveryFixSaysWhatItDid() throws {
        waitForLooks()
        let fixes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fix.'"))
        guard fixes.count > 0 else { throw XCTSkip("no craft flag on the generated frame") }
        let before = status.label
        fixes.element(boundBy: 0).click()
        let changed = NSPredicate(format: "label != %@", before)
        wait(for: [XCTNSPredicateExpectation(predicate: changed, object: status)], timeout: 30)
    }

    // MARK: Fixture

    private static func writeFrame(_ url: URL, brightness: Double, sky: Bool) throws {
        let w = 1200, h = 800
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        let b = CGFloat(min(1, brightness))
        ctx.setFillColor(CGColor(red: b * 0.55, green: b * 0.6, blue: b * 0.45, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if sky {
            ctx.setFillColor(CGColor(red: 0.93, green: 0.95, blue: 0.99, alpha: 1))
            ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
        }
        ctx.setFillColor(CGColor(red: b * 0.9, green: b * 0.7, blue: b * 0.55, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w / 3, y: h / 6, width: w / 5, height: h / 2))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
