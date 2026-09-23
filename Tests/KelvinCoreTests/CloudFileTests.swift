import XCTest
@testable import KelvinCore

/// The dataless case itself needs an iCloud-synced folder and a file macOS has evicted, which a test
/// cannot arrange; it was measured by hand (see `CloudFile`). What a test CAN pin is the other side:
/// an ordinary file is never mistaken for an evicted one, and `materialise` leaves it alone —
/// because a false positive here would skip every read-ahead in every shoot.
final class CloudFileTests: XCTestCase {
    func testALocalFileIsNotEvicted() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudfile-\(UUID().uuidString).bin")
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(CloudFile.isEvicted(url))
        XCTAssertNoThrow(try CloudFile.materialise(url))
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
    }

    func testAMissingFileIsNotEvicted() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).ARW")
        XCTAssertFalse(CloudFile.isEvicted(url))
        // Not evicted, so nothing to download: the decode that follows reports the missing file
        // in its own words, rather than this claiming an iCloud problem that is not there.
        XCTAssertNoThrow(try CloudFile.materialise(url))
    }

    func testTheFailureSaysWhatHappenedInWords() {
        let message = CloudFile.DownloadFailed(name: "_DSC0459.ARW").localizedDescription
        XCTAssertTrue(message.contains("_DSC0459.ARW"))
        XCTAssertTrue(message.contains("iCloud"))
    }
}
