import XCTest
@testable import KelvinCore

final class PreferenceStoreTests: XCTestCase {

    func testRecordAndLoadPicks() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("kelvin-pref-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let logURL = tempDir.appendingPathComponent("preferences.jsonl")
        let store = PreferenceStore(logFileURL: logURL)

        let pick1 = PreferencePick(
            imageId: "sha256:abc12345",
            perceptionHash: "hash123",
            shown: ["natural", "vivid", "soft", "dramatic"],
            chosen: "vivid",
            subsequentManualEdits: ["exposure_ev": 0.1, "vibrance": -2]
        )
        let pick2 = PreferencePick(
            imageId: "sha256:def67890",
            perceptionHash: "hash456",
            shown: ["natural", "vivid", "soft", "dramatic"],
            chosen: "soft"
        )

        try await store.record(pick: pick1)
        try await store.record(pick: pick2)

        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].schemaVersion, 1)
        XCTAssertEqual(loaded[0].imageId, "sha256:abc12345")
        XCTAssertEqual(loaded[0].chosen, "vivid")
        XCTAssertEqual(loaded[0].shown, ["natural", "vivid", "soft", "dramatic"])
        XCTAssertEqual(loaded[0].subsequentManualEdits?["exposure_ev"], 0.1)
        XCTAssertEqual(loaded[1].chosen, "soft")
        XCTAssertEqual(loaded[1].perceptionHash, "hash456")
    }
}
