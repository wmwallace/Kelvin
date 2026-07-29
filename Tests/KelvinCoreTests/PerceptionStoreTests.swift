import XCTest
@testable import KelvinCore

/// The perception cache, which exists because perception is 96% of the cost of exporting a shoot.
///
/// A cache that serves a *stale* answer is worse than no cache at all: it is silent, it survives
/// quitting, and the wrong answer it hands back looks exactly like a right one. So the rules pinned
/// here are the invalidation rules — a different model, and a changed file — plus the promise that a
/// miss is only ever slow, never wrong.
final class PerceptionStoreTests: XCTestCase {

    private var photo: URL!

    override func setUpWithError() throws {
        photo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-perception-\(UUID().uuidString).jpg")
        try Data("original".utf8).write(to: photo)
    }

    override func tearDownWithError() throws {
        PerceptionStore.remove(for: photo)
        try? FileManager.default.removeItem(at: photo)
    }

    private func read(_ scene: Scene = .portrait, notes: String? = nil) -> Perception {
        Perception(scene: scene, subject: .absent, lighting: .unknown,
                   problems: [], intent: .natural, confidence: 0.9, notes: notes)
    }

    // MARK: The basic bargain

    func testAReadComesBackAsItWentIn() throws {
        let original = read(.landscape, notes: "A wide valley under flat cloud.")
        PerceptionStore.save(original, for: photo, modelId: "model-a")
        let back = try XCTUnwrap(PerceptionStore.load(for: photo, modelId: "model-a"))
        XCTAssertEqual(back, original)
    }

    func testAnUnreadPhotographIsAMiss() {
        XCTAssertNil(PerceptionStore.load(for: photo, modelId: "model-a"))
    }

    /// Two photographs must never share a cache entry — the same failure `EditStore` is keyed
    /// against, and here it would put one frame's scene reading onto another.
    func testDifferentPhotographsNeverShareAnEntry() {
        let a = URL(fileURLWithPath: "/shoot/a/_DSC0001.ARW")
        let b = URL(fileURLWithPath: "/shoot/b/_DSC0001.ARW")
        XCTAssertNotEqual(PerceptionStore.url(for: a), PerceptionStore.url(for: b))
        XCTAssertEqual(PerceptionStore.url(for: a),
                       PerceptionStore.url(for: URL(fileURLWithPath: "/shoot/a/./_DSC0001.ARW")),
                       "one photograph spelled two ways must find one entry")
    }

    /// **Reorganising a library must not empty the cache**, which is the failure that made this key
    /// what it is. The key was the full path, so renaming a shoot folder orphaned every read inside
    /// it: measured on a real library, 19 of 23 stored reads pointed at paths that no longer
    /// existed and a 126-frame shoot had 4 live entries. Nothing announced it — a cache that misses
    /// is indistinguishable from a cache that is cold, so the only symptom was that reading a scene
    /// became slow again, at roughly 8.7 seconds a frame.
    func testMovingAPhotographKeepsItsRead() throws {
        let original = read(.landscape, notes: "Sea stacks under a marine overcast.")
        PerceptionStore.save(original, for: photo, modelId: "model-a")

        let moved = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-moved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let destination = moved.appendingPathComponent(photo.lastPathComponent)
        try FileManager.default.moveItem(at: photo, to: destination)
        defer {
            PerceptionStore.remove(for: destination)
            try? FileManager.default.removeItem(at: moved)
            // `tearDown` removes `photo`, which no longer exists; put something back so it can.
            try? Data("original".utf8).write(to: photo)
        }

        XCTAssertEqual(PerceptionStore.load(for: destination, modelId: "model-a"), original,
                       "a photograph filed into a different folder lost a read it had already paid for")
    }

    /// The other half of that bargain: surviving a move must not come at the price of two different
    /// photographs sharing an entry. Same name, different bytes — the case that actually occurs,
    /// since `_DSC0001.ARW` repeats across bodies and cards.
    func testTwoRealFilesSharingANameDoNotShareAnEntry() throws {
        let otherDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-twin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let twin = otherDir.appendingPathComponent(photo.lastPathComponent)
        try Data("a different photograph entirely, of a different length".utf8).write(to: twin)
        defer { try? FileManager.default.removeItem(at: otherDir) }

        PerceptionStore.save(read(.portrait), for: photo, modelId: "model-a")
        XCTAssertNil(PerceptionStore.load(for: twin, modelId: "model-a"),
                     "a namesake in another folder was served the first photograph's read")
    }

    // MARK: Invalidation — the part that has to be right

    /// **A different model is a different answer.** Without this, `KELVIN_MODEL=…` — which exists
    /// precisely so two models can be compared on real photographs — would be served the previous
    /// model's cached reads and quietly compare a model against itself.
    func testAReadFromAnotherModelIsNotServed() {
        PerceptionStore.save(read(.portrait), for: photo, modelId: "qwen-2b")
        XCTAssertNil(PerceptionStore.load(for: photo, modelId: "qwen-7b"),
                     "one model was served another model's answer")
        XCTAssertNotNil(PerceptionStore.load(for: photo, modelId: "qwen-2b"))
    }

    /// A file replaced under us is a different photograph wearing the same name — a re-export, a
    /// re-download, a card reused. The cached read describes pixels that are gone.
    func testAChangedFileInvalidatesItsRead() throws {
        PerceptionStore.save(read(.portrait), for: photo, modelId: "model-a")
        XCTAssertNotNil(PerceptionStore.load(for: photo, modelId: "model-a"))

        // Rewrite with different content and a later modification date.
        try Data("replaced with something considerably longer".utf8).write(to: photo)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: photo.path)
        XCTAssertNil(PerceptionStore.load(for: photo, modelId: "model-a"),
                     "a replaced file was described by the old file's read")
    }

    /// The hint is size and modification date, not a content hash — hashing a folder of 60 MP RAWs
    /// is the exact cost this cache exists to avoid. Worth pinning so nobody "improves" it into a
    /// hash later without noticing what that costs on every lookup.
    func testTheContentHintReadsNoPixels() throws {
        let hint = try XCTUnwrap(PerceptionStore.contentHint(for: photo))
        XCTAssertTrue(hint.contains("-"), "expected size-modified, got \(hint)")
        // Same file, unchanged: same hint, and cheap enough to call in a loop.
        XCTAssertEqual(hint, PerceptionStore.contentHint(for: photo))
    }

    func testAMissingFileHasNoHint() {
        let gone = URL(fileURLWithPath: "/nowhere/\(UUID().uuidString).ARW")
        XCTAssertNil(PerceptionStore.contentHint(for: gone))
    }

    // MARK: Counting a shoot

    /// Drives the read-ahead progress over hundreds of frames, so it must not open anything.
    func testReadAmongFindsOnlyWhatHasBeenStored() throws {
        let other = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-perception-\(UUID().uuidString).jpg")
        try Data("other".utf8).write(to: other)
        defer { PerceptionStore.remove(for: other); try? FileManager.default.removeItem(at: other) }

        PerceptionStore.save(read(), for: photo, modelId: "model-a")
        XCTAssertEqual(PerceptionStore.read(among: [photo, other]), [photo])
    }

    // MARK: Forgetting

    func testRemovingAReadMakesItAMissAgain() {
        PerceptionStore.save(read(), for: photo, modelId: "model-a")
        PerceptionStore.remove(for: photo)
        XCTAssertNil(PerceptionStore.load(for: photo, modelId: "model-a"))
    }

    /// The free-text sentence rides along with the rest. It is the app's only explanation of itself,
    /// and a cached read that dropped it would leave re-opened photographs silently unexplained.
    func testTheModelsOwnSentenceSurvivesTheRoundTrip() throws {
        let sentence = "Backlit portrait against a bright window, subject in shadow."
        PerceptionStore.save(read(.portrait, notes: sentence), for: photo, modelId: "model-a")
        let back = try XCTUnwrap(PerceptionStore.load(for: photo, modelId: "model-a"))
        XCTAssertEqual(back.notes, sentence)
    }
}
