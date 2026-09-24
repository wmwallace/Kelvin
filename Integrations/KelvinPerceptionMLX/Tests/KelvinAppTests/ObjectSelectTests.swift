import XCTest
import CoreImage
import KelvinCore
@testable import KelvinApp

/// "Object" — tap-to-segment (D32). The app's half is state, not pixels: where a tap lands, that ⌥
/// takes away, that each tap is one undo step, and that what reaches the renderer and the disk is the
/// taps and never a bitmap. `ObjectSegmentationTests` in the core covers the segmentation.
@MainActor
final class ObjectSelectTests: XCTestCase {

    private let container = CGSize(width: 400, height: 400)
    private var centre: CGPoint { CGPoint(x: 200, y: 200) }

    /// An object mask taking taps over a square proxy. `.preparing` so nothing here starts loading
    /// Apple's model: these tests are about the taps, and no test should download a model.
    private func armedState() -> (AppState, UUID) {
        let s = AppState()
        s.proxyCI = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 800))
        if s.objectSelection != .unsupported { s.objectSelection = .preparing }
        s.addUserMask(.object)
        return (s, s.userMasks.last?.id ?? UUID())
    }

    func testAddingAnObjectMaskArmsTheCanvas() {
        let (s, id) = armedState()
        XCTAssertEqual(s.tappingMaskId, id, "an object mask is nothing but taps — it must start listening")
        XCTAssertEqual(s.userMasks.last?.kind, .object)
    }

    func testAClickAddsAndAnOptionClickTakesAway() throws {
        let (s, _) = armedState()
        s.tapObject(at: centre, container: container)
        s.tapObject(at: CGPoint(x: 150, y: 150), container: container, exclude: true)
        let m = try XCTUnwrap(s.userMasks.last)
        XCTAssertEqual(m.objectInclude.count, 1)
        XCTAssertEqual(m.objectExclude.count, 1)
        XCTAssertEqual(m.objectInclude[0].x, 0.5, accuracy: 0.01)
        XCTAssertEqual(m.objectInclude[0].y, 0.5, accuracy: 0.01)
        XCTAssertLessThan(m.objectExclude[0].y, 0.5, "a tap above the centre must be stored top-left")
        XCTAssertEqual(s.tappingMaskId, m.id, "the tool must stay armed between taps")
    }

    /// There is nothing to take a piece off yet — refused, and said, rather than stored as a mask
    /// that can never select anything.
    func testAnOptionClickBeforeAnyTapIsRefused() throws {
        let (s, _) = armedState()
        s.tapObject(at: centre, container: container, exclude: true)
        XCTAssertEqual(try XCTUnwrap(s.userMasks.last).objectExclude.count, 0)
        XCTAssertTrue(s.statusMessage.contains("first"), "the refusal must say what to do")
    }

    func testEachTapIsItsOwnUndoStep() throws {
        let (s, _) = armedState()
        s.resetHistory()
        s.tapObject(at: centre, container: container)
        s.tapObject(at: CGPoint(x: 260, y: 220), container: container)
        XCTAssertEqual(try XCTUnwrap(s.userMasks.last).objectInclude.count, 2)
        s.undo()
        XCTAssertEqual(try XCTUnwrap(s.userMasks.last).objectInclude.count, 1,
                       "one undo should remove exactly one tap")
        s.redo()
        XCTAssertEqual(try XCTUnwrap(s.userMasks.last).objectInclude.count, 2)
    }

    func testClearingTheTapsLeavesTheMaskAndItsAdjustments() throws {
        let (s, id) = armedState()
        s.tapObject(at: centre, container: container)
        s.clearObjectTaps(id)
        let m = try XCTUnwrap(s.userMasks.last)
        XCTAssertTrue(m.objectInclude.isEmpty && m.objectExclude.isEmpty)
        XCTAssertNotEqual(m.exposure, 0, "clearing the selection must not reset what it does")
    }

    func testRemovingTheMaskDisarmsTheCanvas() {
        let (s, id) = armedState()
        s.removeUserMask(id)
        XCTAssertNil(s.tappingMaskId, "a canvas still taking taps for a deleted mask swallows every click")
    }

    /// What the renderer and the export are handed: the taps, in the recipe's own vocabulary.
    func testTheMaskCarriesItsTapsAndNoOtherSource() {
        var vm = UserMaskVM(kind: .object)
        vm.objectInclude = [.init(x: 0.53, y: 0.55)]
        vm.objectExclude = [.init(x: 0.32, y: 0.64)]
        let mask = vm.toMask()
        XCTAssertEqual(mask.segment, SegmentSeed(include: [.init(x: 0.53, y: 0.55)],
                                                 exclude: [.init(x: 0.32, y: 0.64)]))
        XCTAssertEqual(mask.id, vm.id.uuidString, "the canvas supplies the bitmap under this id")
        XCTAssertNil(mask.region)
        XCTAssertNil(mask.selection)
        XCTAssertNil(mask.shape)
        XCTAssertGreaterThan(mask.feather, 0)
    }

    func testTapsSurviveASaveAndReopen() throws {
        var vm = UserMaskVM(kind: .object)
        vm.objectInclude = [.init(x: 0.53, y: 0.55), .init(x: 0.76, y: 0.62)]
        vm.objectExclude = [.init(x: 0.32, y: 0.64)]
        vm.exposure = -0.4
        let back = try JSONDecoder().decode(UserMaskVM.self, from: JSONEncoder().encode(vm))
        XCTAssertEqual(back, vm, "the taps were lost between CodingKeys and init(from:)")
    }

    func testAMaskSavedBeforeObjectsExistedStillOpens() throws {
        let json = #"{"kind":"wand","cx":0.3,"cy":0.4}"#
        let vm = try JSONDecoder().decode(UserMaskVM.self, from: Data(json.utf8))
        XCTAssertEqual(vm.kind, .wand)
        XCTAssertTrue(vm.objectInclude.isEmpty && vm.objectExclude.isEmpty)
        XCTAssertNil(vm.toMask().segment)
    }

    /// On a Mac that cannot, the card says so — including for an edit made on one that could.
    func testAnUnsupportedMacSaysWhatItNeeds() {
        let s = AppState()
        s.objectSelection = .unsupported
        XCTAssertEqual(s.objectStatusLine?.contains("macOS 27"), true)
    }
}
