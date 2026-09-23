import XCTest
import CoreImage
@testable import KelvinCore

/// Colour-cube tables are a pure function of a few recipe numbers, so the same numbers must get
/// the same table without paying 32³ conversions again — and the memo must stay bounded and safe
/// under the several `Offload` lanes that render at once.
final class CubeCacheTests: XCTestCase {

    /// The storage behind a `Data`, so a test can tell "the same table handed back" from "an equal
    /// table built again".
    private func address(_ data: Data?) -> UnsafeRawPointer? {
        data?.withUnsafeBytes { UnsafeRawPointer($0.baseAddress) }
    }

    func testTheSameSettingsReuseOneTable() throws {
        let hsl = ["orange": HSLAdjustment(h: 7, s: 13, l: -3)]
        let a = try XCTUnwrap(HSLCube.makeData(from: hsl))
        let b = try XCTUnwrap(HSLCube.makeData(from: hsl))
        XCTAssertEqual(address(a), address(b), "a repeated HSL setting must not rebuild its cube")

        let mix = BlackAndWhiteMix(bands: ["blue": -37, "orange": 11])
        XCTAssertEqual(address(MonochromeCube.makeData(mix)), address(MonochromeCube.makeData(mix)))

        let sel = MaskSelection(kind: .color, center: 0.31, range: 0.07, softness: 0.05)
        XCTAssertEqual(address(SelectionMask.makeData(sel)), address(SelectionMask.makeData(sel)))
    }

    /// Memoised or not, the pixels are the same: two renders of one recipe are byte-identical.
    func testMemoisedRendersAreIdentical() throws {
        var recipe = Recipe.neutral
        recipe.hsl = ["blue": HSLAdjustment(h: 10, s: -20, l: 5)]
        recipe.blackAndWhite = BlackAndWhiteMix(bands: ["red": 20])
        let image = TestSupport.makeGradientImage(width: 32, height: 32)
        XCTAssertEqual(try ImageWriter.rgba8Bytes(Renderer.render(image, with: recipe)),
                       try ImageWriter.rgba8Bytes(Renderer.render(image, with: recipe)))
    }

    func testTheCacheIsBoundedAndEvictsTheLeastRecentlyUsed() {
        let cache = CubeCache<Int>(capacity: 2)
        var builds = 0
        func get(_ k: Int) -> Data? { cache.data(for: k) { builds += 1; return Data([UInt8($0)]) } }

        _ = get(1); _ = get(2)
        _ = get(1)                        // 1 is now the most recent
        _ = get(3)                        // evicts 2, not 1
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(builds, 3)
        _ = get(1)
        XCTAssertEqual(builds, 3, "1 was used recently and must still be held")
        _ = get(2)
        XCTAssertEqual(builds, 4, "2 was the least recently used and must have been evicted")
    }

    func testANilBuildIsNotRemembered() {
        let cache = CubeCache<Int>(capacity: 4)
        XCTAssertNil(cache.data(for: 1) { _ in nil })
        XCTAssertEqual(cache.count, 0)
    }

    /// Several lanes render at once. Every caller must get the right table for its own key, and
    /// the cache must come out within its bound.
    func testConcurrentUseIsSafe() {
        let cache = CubeCache<Int>(capacity: 8)
        DispatchQueue.concurrentPerform(iterations: 2000) { i in
            let key = i % 24
            let data = cache.data(for: key) { Data([UInt8($0)]) }
            XCTAssertEqual(data, Data([UInt8(key)]))
        }
        XCTAssertLessThanOrEqual(cache.count, 8)
    }
}
