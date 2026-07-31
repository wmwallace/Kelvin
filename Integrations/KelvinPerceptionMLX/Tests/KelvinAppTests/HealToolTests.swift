import XCTest
import CoreImage
import KelvinCore
@testable import KelvinApp

/// The heal tool is a mode that takes over the canvas click, and the things that can go wrong with
/// it are all about state rather than pixels: a click that lands nothing, a spot that survives an
/// undo, a heal that does not count as an edit and so is never written to disk. `SpotHealTests` in
/// the core covers the patch-finding; this covers the app's half.
@MainActor
final class HealToolTests: XCTestCase {

    /// A flat grey proxy — enough for `SpotHeal` to find a source patch on.
    private func proxy(width: Int = 300, height: Int = 200) -> CIImage {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            px[i] = 150; px[i + 1] = 150; px[i + 2] = 150; px[i + 3] = 255
        }
        return CIImage(bitmapData: Data(px), bytesPerRow: width * 4,
                       size: CGSize(width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    private func armedState() -> AppState {
        let s = AppState()
        s.proxyCI = proxy()
        s.healToolActive = true
        return s
    }

    // MARK: Placing

    func testClickPlacesASpot() {
        let s = armedState()
        XCTAssertTrue(s.healAt(CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(s.healSpots.count, 1)
    }

    func testHealsAccumulate() {
        let s = armedState()
        s.healAt(CGPoint(x: 0.3, y: 0.3))
        s.healAt(CGPoint(x: 0.6, y: 0.6))
        XCTAssertEqual(s.healSpots.count, 2)
    }

    /// Without a decoded proxy there is nothing to sample, and the click must fail honestly rather
    /// than appending a spot with a meaningless source offset.
    func testClickWithNoPhotoDoesNothing() {
        let s = AppState()
        s.healToolActive = true
        XCTAssertFalse(s.healAt(CGPoint(x: 0.5, y: 0.5)))
        XCTAssertTrue(s.healSpots.isEmpty)
    }

    func testHealRadiusIsClamped() {
        let s = armedState()
        s.healRadius = 0.012
        for _ in 0..<100 { s.adjustHealRadius(by: 0.01) }
        XCTAssertLessThanOrEqual(s.healRadius, 0.08)
        for _ in 0..<200 { s.adjustHealRadius(by: -0.01) }
        XCTAssertGreaterThanOrEqual(s.healRadius, 0.003)
    }

    // MARK: Removing

    func testAltClickRemovesTheSpotUnderIt() {
        let s = armedState()
        s.healAt(CGPoint(x: 0.4, y: 0.4))
        XCTAssertEqual(s.healSpots.count, 1)
        XCTAssertTrue(s.removeHealSpot(near: CGPoint(x: 0.4, y: 0.4)))
        XCTAssertTrue(s.healSpots.isEmpty)
    }

    /// The rule that keeps ⌥-click from deleting something across the frame: a click on empty
    /// picture removes nothing at all.
    func testAltClickOnEmptyPictureRemovesNothing() {
        let s = armedState()
        s.healAt(CGPoint(x: 0.2, y: 0.2))
        XCTAssertFalse(s.removeHealSpot(near: CGPoint(x: 0.9, y: 0.9)))
        XCTAssertEqual(s.healSpots.count, 1)
    }

    func testClearAllRemovesEveryHeal() {
        let s = armedState()
        s.healAt(CGPoint(x: 0.3, y: 0.3))
        s.healAt(CGPoint(x: 0.7, y: 0.7))
        s.clearHealSpots()
        XCTAssertTrue(s.healSpots.isEmpty)
    }

    // MARK: Undo

    /// Each click is its own undo step. This is why heals commit immediately instead of going
    /// through the 0.45 s coalescing a slider drag wants — two clicks a moment apart are two
    /// decisions, and one ⌘Z must not take both.
    func testEachHealIsItsOwnUndoStep() {
        let s = armedState()
        s.resetHistory()
        s.healAt(CGPoint(x: 0.3, y: 0.3))
        s.healAt(CGPoint(x: 0.6, y: 0.6))
        XCTAssertEqual(s.healSpots.count, 2)
        XCTAssertTrue(s.canUndo)

        s.undo()
        XCTAssertEqual(s.healSpots.count, 1, "one undo should remove exactly one heal")
        s.undo()
        XCTAssertTrue(s.healSpots.isEmpty)
    }

    func testUndoneHealCanBeRedone() {
        let s = armedState()
        s.resetHistory()
        s.healAt(CGPoint(x: 0.5, y: 0.5))
        s.undo()
        XCTAssertTrue(s.healSpots.isEmpty)
        s.redo()
        XCTAssertEqual(s.healSpots.count, 1)
    }

    // MARK: It counts as an edit

    /// If a heal does not mark the photo as touched, the filmstrip's edited dot is wrong and — far
    /// worse — the edit is never persisted, so the work vanishes on relaunch.
    func testAHealMakesThePhotoTouched() {
        let s = armedState()
        XCTAssertFalse(s.isTouched)
        s.healAt(CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(s.isTouched)
    }

    // MARK: The mode gate

    /// The canvas entry point must refuse when the tool is not armed, or a normal click on the
    /// photograph would start patching it.
    func testCanvasClickIsIgnoredWhenToolIsOff() {
        let s = armedState()
        s.healToolActive = false
        s.healAt(CGPoint(x: 100, y: 100), container: CGSize(width: 400, height: 300))
        XCTAssertTrue(s.healSpots.isEmpty)
    }
}
