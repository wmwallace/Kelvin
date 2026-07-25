import XCTest
@testable import KelvinCore

/// Ordering the filmstrip. The strip used to sort by filename only, which is a proxy for capture
/// order that breaks the moment two cameras, two cards, or a renamed file are involved.
final class PhotoOrderTests: XCTestCase {

    private let dir = URL(fileURLWithPath: "/shoot", isDirectory: true)
    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// Fixed reference point so the tests read as times, not arithmetic.
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func names(_ urls: [URL]) -> [String] { urls.map { $0.lastPathComponent } }

    // MARK: Capture time

    func testCaptureTimeOrdersByTimeNotFilename() {
        // The case that started this: two cameras in one folder. Names interleave wrongly; the
        // frames were actually taken alternately.
        let a1 = url("_DSC0001.ARW"), a2 = url("_DSC0002.ARW")
        let b1 = url("IMG_9000.CR3"), b2 = url("IMG_9001.CR3")
        let dates = [a1: at(0), b1: at(10), a2: at(20), b2: at(30)]

        let sorted = PhotoOrder.sorted([b2, a2, b1, a1], by: .captureTime, captureDates: dates)
        XCTAssertEqual(names(sorted), ["_DSC0001.ARW", "IMG_9000.CR3", "_DSC0002.ARW", "IMG_9001.CR3"])
    }

    func testCaptureTimeFallsBackToFilenameOrderWhenNoDatesAreKnown() {
        // The state the strip is in for the first moment after a folder opens: dates not read yet.
        // It must show something sensible rather than an arbitrary filesystem order.
        let urls = [url("_DSC10.ARW"), url("_DSC9.ARW"), url("_DSC2.ARW")]
        let sorted = PhotoOrder.sorted(urls, by: .captureTime, captureDates: [:])
        XCTAssertEqual(names(sorted), ["_DSC2.ARW", "_DSC9.ARW", "_DSC10.ARW"])
    }

    // MARK: Missing capture dates

    func testUndatedFilesSortLast() {
        let scan = url("scan-001.tif"), shot = url("_DSC0001.ARW"), export = url("export.jpg")
        let sorted = PhotoOrder.sorted([scan, shot, export], by: .captureTime,
                                       captureDates: [shot: at(0)])
        XCTAssertEqual(names(sorted), ["_DSC0001.ARW", "export.jpg", "scan-001.tif"],
                       "dated frames first; undated hold filename order behind them")
    }

    func testUndatedFilesStayLastWhenReversed() {
        // Reversing asks for "newest first". It must not answer with a pile of files that have no
        // date at all.
        let scan = url("scan.tif"), early = url("a.ARW"), late = url("b.ARW")
        let sorted = PhotoOrder.sorted([scan, early, late], by: .captureTime, reversed: true,
                                       captureDates: [early: at(0), late: at(100)])
        XCTAssertEqual(names(sorted), ["b.ARW", "a.ARW", "scan.tif"])
    }

    func testAllUndatedIsFilenameOrderInBothDirections() {
        let urls = [url("c.png"), url("a.png"), url("b.png")]
        XCTAssertEqual(names(PhotoOrder.sorted(urls, by: .captureTime)), ["a.png", "b.png", "c.png"])
        // Undated files have no timeline to reverse, so reverse leaves them alone rather than
        // inventing one.
        XCTAssertEqual(names(PhotoOrder.sorted(urls, by: .captureTime, reversed: true)),
                       ["a.png", "b.png", "c.png"])
    }

    // MARK: Reverse

    func testReverseFlipsCaptureOrder() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        let dates = [a: at(0), b: at(10), c: at(20)]
        XCTAssertEqual(names(PhotoOrder.sorted([a, b, c], by: .captureTime, reversed: true, captureDates: dates)),
                       ["c.ARW", "b.ARW", "a.ARW"])
    }

    func testReverseFlipsFilenameOrder() {
        let urls = [url("_DSC9.ARW"), url("_DSC10.ARW"), url("_DSC2.ARW")]
        XCTAssertEqual(names(PhotoOrder.sorted(urls, by: .filename, reversed: true)),
                       ["_DSC10.ARW", "_DSC9.ARW", "_DSC2.ARW"])
    }

    // MARK: Filename

    func testFilenameSortIsNaturalOrder() {
        // The whole reason the old sort used `localizedStandardCompare`: a plain string compare
        // puts _DSC10 before _DSC9, and a shoot then reads out of order at every power of ten.
        let urls = [url("_DSC10.ARW"), url("_DSC2.ARW"), url("_DSC9.ARW"), url("_DSC100.ARW")]
        XCTAssertEqual(names(PhotoOrder.sorted(urls, by: .filename)),
                       ["_DSC2.ARW", "_DSC9.ARW", "_DSC10.ARW", "_DSC100.ARW"])
    }

    // MARK: Determinism

    func testEqualCaptureTimesOrderDeterministicallyByFilename() {
        // A burst: EXIF resolves to one second, so a dozen frames share a timestamp.
        let frames = (1...6).map { url("_DSC\($0).ARW") }
        var dates: [URL: Date] = [:]
        for f in frames { dates[f] = at(42) }

        // Whatever order the filesystem hands them over in, the strip shows the same thing.
        // `Array.sorted(by:)` is not documented as stable, so this can only hold if the comparator
        // is a total order — which is why filename is a tie-break rather than a hope.
        let expected = names(PhotoOrder.sorted(frames, by: .captureTime, captureDates: dates))
        XCTAssertEqual(expected, ["_DSC1.ARW", "_DSC2.ARW", "_DSC3.ARW",
                                  "_DSC4.ARW", "_DSC5.ARW", "_DSC6.ARW"])
        for _ in 0..<20 {
            let shuffled = PhotoOrder.sorted(frames.shuffled(), by: .captureTime, captureDates: dates)
            XCTAssertEqual(names(shuffled), expected)
        }
    }

    func testEqualCaptureTimesKeepTheirOrderWhenReversed() {
        // Reversing a shoot reverses the shoot, not the inside of a burst — those frames are one
        // moment and shuffling them would be noise.
        let a = url("_DSC1.ARW"), b = url("_DSC2.ARW"), later = url("_DSC3.ARW")
        let dates = [a: at(0), b: at(0), later: at(60)]
        XCTAssertEqual(names(PhotoOrder.sorted([a, b, later], by: .captureTime, reversed: true, captureDates: dates)),
                       ["_DSC3.ARW", "_DSC1.ARW", "_DSC2.ARW"])
    }

    func testEqualFilenamesInDifferentFoldersAreOrderedByPath() {
        // Not reachable from one folder today, but the comparator must be total for `sorted(by:)`
        // to be deterministic at all.
        let a = URL(fileURLWithPath: "/a/IMG_1.jpg"), b = URL(fileURLWithPath: "/b/IMG_1.jpg")
        XCTAssertEqual(PhotoOrder.compareFilenames(a, b), .orderedAscending)
        XCTAssertEqual(PhotoOrder.compareFilenames(b, a), .orderedDescending)
        XCTAssertEqual(PhotoOrder.compareFilenames(a, a), .orderedSame)
    }

    func testEmptyAndSingleInputs() {
        XCTAssertTrue(PhotoOrder.sorted([], by: .captureTime).isEmpty)
        let one = [url("only.jpg")]
        XCTAssertEqual(PhotoOrder.sorted(one, by: .captureTime, reversed: true), one)
    }

    // MARK: Reading dates off disk

    func testCaptureDatesReadsWhatIsThereAndOmitsWhatIsNot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A generated PNG carries no DateTimeOriginal — the same shape as a scan or a screenshot.
        let png = dir.appendingPathComponent("plain.png")
        try ImageWriter.write(TestSupport.makeGradientImage(width: 16, height: 16), to: png, format: .png)

        let dates = PhotoOrder.captureDates(for: [png, dir.appendingPathComponent("missing.jpg")])
        XCTAssertNil(dates[png], "no EXIF date means absent, not epoch zero")
        XCTAssertTrue(dates.isEmpty, "an unreadable file must be skipped, never crash the read")
    }
}
