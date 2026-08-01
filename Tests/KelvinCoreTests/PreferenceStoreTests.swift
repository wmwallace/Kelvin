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

    /// The append in `record` is not atomic, so a crash mid-write leaves a truncated line.
    /// This log is the product's training signal and is append-forever: one bad line must
    /// cost one pick, never the whole history.
    func testACorruptLineCostsOnePickNotTheHistory() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("kelvin-pref-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let logURL = tempDir.appendingPathComponent("preferences.jsonl")
        let store = PreferenceStore(logFileURL: logURL)

        try await store.record(pick: PreferencePick(imageId: "sha256:aaa", shown: ["a", "b"], chosen: "a"))
        // A power loss mid-append: half a JSON object, no trailing newline.
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"schema_version\": 1, \"image_id\": \"sha256:trunc".utf8))
        try handle.close()

        // The next launch appends past the damage, then reads everything back.
        // (The truncated line absorbs the next line's start — both are lost, and that
        // is the accepted cost; the line after survives.)
        try await store.record(pick: PreferencePick(imageId: "sha256:bbb", shown: ["a", "b"], chosen: "b"))
        try await store.record(pick: PreferencePick(imageId: "sha256:ccc", shown: ["a", "b"], chosen: "a"))

        let report = try await store.loadAllReport()
        XCTAssertEqual(report.picks.map(\.imageId), ["sha256:aaa", "sha256:ccc"])
        XCTAssertEqual(report.skippedLines, 1)
        let survivors = try await store.loadAll()
        XCTAssertEqual(survivors.count, 2, "loadAll must not throw on damage")
    }
}
