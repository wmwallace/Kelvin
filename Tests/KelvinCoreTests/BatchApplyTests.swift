import XCTest
import CoreImage
@testable import KelvinCore

/// Milestone 8: batch apply. Propagating one recipe across a folder must be robust (one bad
/// file cannot sink the run), non-destructive (originals untouched), and faithful to the
/// no-op invariant per file.
final class BatchApplyTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func vividRecipe() -> Recipe {
        var g = GlobalAdjustments.neutral
        g.exposureEV = 0.3
        g.contrast = 20
        g.vibrance = 15
        return Recipe(schemaVersion: 1, id: nil, label: "test", provenance: nil,
                      global: g, curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
    }

    func testAppliesRecipeToEveryImageInFolder() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }

        for i in 0..<3 {
            try ImageWriter.write(TestSupport.makeGradientImage(width: 32, height: 32),
                                  to: inDir.appendingPathComponent("img\(i).png"), format: .png)
        }

        let outcome = try BatchApply.run(inputDir: inDir, recipe: vividRecipe(), outputDir: outDir)

        XCTAssertEqual(outcome.succeeded, 3)
        XCTAssertEqual(outcome.failed, 0)
        for url in outcome.written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNoThrow(try ImageDecoder.decode(url: url), "output must be a valid image")
        }
    }

    /// Non-negotiable #3, asserted over the whole source folder rather than one file: after a
    /// batch, every original must be byte-for-byte what it was, and the folder must contain
    /// exactly the files it contained before. The second half matters as much as the first —
    /// a batch that dropped its renders next to the originals would leave every original
    /// intact and still have polluted the card.
    func testOriginalsAreByteIdenticalAndFolderIsUnchanged() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }

        var before: [String: Data] = [:]
        for name in ["one.png", "two.png", "three.png"] {
            let url = inDir.appendingPathComponent(name)
            try ImageWriter.write(TestSupport.makeGradientImage(width: 32, height: 32), to: url, format: .png)
            before[name] = try Data(contentsOf: url)
        }

        _ = try BatchApply.run(inputDir: inDir, recipe: vividRecipe(), outputDir: outDir)

        let after = try FileManager.default.contentsOfDirectory(atPath: inDir.path).sorted()
        XCTAssertEqual(after, before.keys.sorted(), "batch must not add or remove files in the source folder")
        for (name, bytes) in before {
            XCTAssertEqual(try Data(contentsOf: inDir.appendingPathComponent(name)), bytes,
                           "batch must never write over the original \(name)")
        }
    }

    func testNeutralRecipeIsNoOpPerFile() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }

        let source = TestSupport.makeGradientImage(width: 48, height: 48)
        try ImageWriter.write(source, to: inDir.appendingPathComponent("a.png"), format: .png)

        let outcome = try BatchApply.run(inputDir: inDir, recipe: .neutral, outputDir: outDir)
        XCTAssertEqual(outcome.succeeded, 1)

        // A neutral recipe must render byte-identical output (the no-op invariant), file by file.
        let inBytes = try ImageWriter.rgba8Bytes(try ImageDecoder.decode(url: inDir.appendingPathComponent("a.png")))
        let outBytes = try ImageWriter.rgba8Bytes(try ImageDecoder.decode(url: outcome.written[0]))
        XCTAssertEqual(inBytes, outBytes)
    }

    func testNonImageFilesAreIgnored() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        try ImageWriter.write(TestSupport.makeGradientImage(width: 16, height: 16),
                              to: inDir.appendingPathComponent("photo.png"), format: .png)
        try Data("not an image".utf8).write(to: inDir.appendingPathComponent("notes.txt"))
        try Data("{}".utf8).write(to: inDir.appendingPathComponent("recipe.json"))

        let images = try BatchApply.imageFiles(in: inDir)
        XCTAssertEqual(images.map { $0.lastPathComponent }, ["photo.png"])
    }

    /// A bad frame in the MIDDLE of a shoot must not cost the frames after it. Batch runs in
    /// sorted order, so the broken file is named to land between two good ones: if the loop
    /// aborted, `3-after.png` would be missing and the count alone would not say which.
    func testBadFileMidBatchDoesNotAbortTheRest() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }

        for name in ["1-before.png", "3-after.png"] {
            try ImageWriter.write(TestSupport.makeGradientImage(width: 16, height: 16),
                                  to: inDir.appendingPathComponent(name), format: .png)
        }
        // A file with an image extension but garbage contents — a truncated card copy, say.
        try Data("nope".utf8).write(to: inDir.appendingPathComponent("2-broken.png"))
        // ...and one that cannot even be read, which fails at a different layer than a bad decode.
        let unreadable = inDir.appendingPathComponent("2-unreadable.png")
        try Data("nope".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: unreadable.path) }

        let outcome = try BatchApply.run(inputDir: inDir, recipe: vividRecipe(), outputDir: outDir)

        XCTAssertEqual(outcome.succeeded, 2, "both good files render, including the one after the failures")
        XCTAssertEqual(outcome.failed, 2, "bad files are collected, not thrown")
        XCTAssertEqual(outcome.items.count, 4, "every input is accounted for, one item each")
        XCTAssertEqual(outcome.failures.map { $0.source.lastPathComponent }.sorted(),
                       ["2-broken.png", "2-unreadable.png"])
        // The point of per-file results: the caller can name what still needs doing.
        XCTAssertTrue(outcome.written.contains { $0.lastPathComponent.hasPrefix("3-after") },
                      "the frame after the failures was written")
    }

    /// The app's adaptive batch re-perceives every frame, so it runs its own loop and assembles
    /// the outcome itself. That call site lives outside this package and cannot be type-checked
    /// here, so its shape is pinned down by a test instead: if the counts stop being derivable
    /// from a written/failures pair, the batch sheet silently starts lying about the run.
    func testOutcomeAssembledByACallerWithItsOwnRenderLoopStillCounts() throws {
        let a = URL(fileURLWithPath: "/tmp/out/a.jpg")
        let b = URL(fileURLWithPath: "/tmp/shoot/b.arw")

        let outcome = BatchApply.Outcome(
            written: [a], failures: [.init(source: b, message: "unsupported")])

        XCTAssertEqual(outcome.succeeded, 1)
        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(outcome.skippedCount, 0)
        XCTAssertEqual(outcome.written, [a])
        XCTAssertEqual(outcome.failures.first?.source, b)
        XCTAssertEqual(outcome.items.count, 2, "still one item per file, however it was assembled")
    }

    /// Every input appears exactly once in the result, tagged with what happened to it. A UI
    /// showing "37 applied" over a 40-photo folder has to be able to say what the other 3 were.
    func testOutcomeAccountsForEveryInputIndividually() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }

        let good = inDir.appendingPathComponent("a.png")
        try ImageWriter.write(TestSupport.makeGradientImage(width: 16, height: 16), to: good, format: .png)
        let bad = inDir.appendingPathComponent("b.png")
        try Data("nope".utf8).write(to: bad)
        // Pre-place the output "c" would collide with, under a skip policy.
        let already = inDir.appendingPathComponent("c.png")
        try ImageWriter.write(TestSupport.makeGradientImage(width: 16, height: 16), to: already, format: .png)
        let claimed = outDir.appendingPathComponent(
            ExportNaming.filename(for: already, perception: nil, look: nil, ext: "png"))
        try Data("existing export".utf8).write(to: claimed)

        let outcome = try BatchApply.run(
            inputDir: inDir, recipe: .neutral,
            destination: .init(directory: outDir, onCollision: .skip, format: .png))

        // Compared by name, not by URL: `imageFiles(in:)` returns whatever spelling the
        // filesystem hands back (`/private/var/…` for a temp dir), and a URL that points at the
        // same file is the property under test, not the string it was built from.
        XCTAssertEqual(outcome.items.map { $0.source.lastPathComponent }, ["a.png", "b.png", "c.png"],
                       "one item per input, in processing order")
        XCTAssertEqual(outcome.succeeded, 1)
        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(outcome.skippedCount, 1)
        XCTAssertEqual(outcome.skipped.map { $0.lastPathComponent }, [already.lastPathComponent])
    }

    /// Batch names files the same way the export panel does. If it did not, one shoot would come
    /// out under two naming conventions depending on which button the photographer pressed.
    func testOutputNamesMatchTheExportNamingConvention() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }

        let src = inDir.appendingPathComponent("_DSC6595.png")
        try ImageWriter.write(TestSupport.makeGradientImage(width: 16, height: 16), to: src, format: .png)

        var recipe = Recipe.neutral
        recipe.label = "Warm portrait"
        let outcome = try BatchApply.run(inputDir: inDir, recipe: recipe, outputDir: outDir)

        XCTAssertEqual(outcome.written.first?.lastPathComponent,
                       ExportNaming.filename(for: src, perception: nil, look: "Warm portrait", ext: "png"))
        // Traceability: whatever else the name says, the original stem is still in there.
        XCTAssertTrue(outcome.written.first?.lastPathComponent.contains("dsc6595") == true,
                      "the export must still map back to the frame on the card")
    }

    func testDeterministicOrder() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        for name in ["c.png", "a.png", "b.png"] {
            try ImageWriter.write(TestSupport.makeGradientImage(width: 16, height: 16),
                                  to: inDir.appendingPathComponent(name), format: .png)
        }
        XCTAssertEqual(try BatchApply.imageFiles(in: inDir).map { $0.lastPathComponent },
                       ["a.png", "b.png", "c.png"])
    }
}

/// What Kelvin can *browse* must match what it can *decode*.
///
/// These were two hand-maintained lists, and they had drifted: the decoder routes Leica, Pentax,
/// Hasselblad, Phase One and several others through `CIRAWFilter`, but none of them appeared in
/// the browse list. A folder of those frames listed as empty — the filmstrip showed nothing and
/// batch skipped every file — so a format the app fully supports was unreachable through the UI.
final class BrowsableFormatsTests: XCTestCase {

    func testEveryDecodableRawFormatIsAlsoBrowsable() {
        let missing = ImageDecoder.rawExtensions.subtracting(BatchApply.imageExtensions)
        XCTAssertTrue(missing.isEmpty,
                      "decoder opens these but the browser hides them: \(missing.sorted())")
    }

    func testCommonNonRawFormatsAreBrowsable() {
        for ext in ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"] {
            XCTAssertTrue(BatchApply.imageExtensions.contains(ext), "\(ext) should be browsable")
        }
    }

    /// Case comes off the filesystem however the camera wrote it — `.ARW`, `.CR3`, `.JPG`.
    /// `imageFiles(in:)` lowercases before matching, so the set itself must be lowercase.
    func testExtensionSetIsLowercased() {
        for ext in BatchApply.imageExtensions {
            XCTAssertEqual(ext, ext.lowercased(), "\(ext) must be stored lowercased to match")
        }
    }
}

/// Where a batch writes.
///
/// This is the only part of the batch path that can destroy work: everything else is additive,
/// and its worst failure is an ugly photograph. So the destination rules get tested against the
/// specific ways a photographer loses files — a second run over the same folder, a destination
/// typed as the source folder, a folder reached through a symlink — rather than against the
/// happy path alone.
///
/// The clobber these guard against was real and was measured before it was fixed: running
/// `kelvin-cli batch --in-dir X --out-dir X --format png` over a folder of PNGs rewrote every
/// original in place, because the output path was built from the source stem with no check that
/// it differed from the source. Non-negotiable #3 held everywhere except the one command that
/// existed to process a whole shoot.
final class BatchDestinationTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-dest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePhoto(_ url: URL) throws {
        try ImageWriter.write(TestSupport.makeGradientImage(width: 16, height: 16), to: url, format: .png)
    }

    // MARK: The destination must not be the source

    func testDestinationEqualToSourceIsRefusedAndNothingIsWritten() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.png")
        try writePhoto(src)
        let before = try Data(contentsOf: src)

        XCTAssertThrowsError(try BatchApply.run(inputDir: dir, recipe: .neutral, outputDir: dir)) { error in
            XCTAssertEqual(error as? BatchApply.Destination.Problem, .sameAsSource(dir))
        }

        XCTAssertEqual(try Data(contentsOf: src), before, "the original survives the refusal")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.png"],
                       "a refused destination writes nothing at all — not even a partial batch")
    }

    /// The same folder, spelled differently. A guard that compares paths as strings passes this
    /// one straight through and overwrites the originals, so the guard asks the filesystem for
    /// identity instead. Measured: `fileResourceIdentifier` on a symlink describes the LINK, so
    /// the first version of this test failed and the guard had to resolve symlinks first.
    func testDestinationReachedThroughASymlinkIsRefused() throws {
        let root = try makeTempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let shoot = root.appendingPathComponent("shoot")
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        try writePhoto(shoot.appendingPathComponent("a.png"))

        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shoot)

        XCTAssertThrowsError(try BatchApply.run(inputDir: shoot, recipe: .neutral, outputDir: alias)) { error in
            XCTAssertEqual(error as? BatchApply.Destination.Problem, .sameAsSource(alias))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: shoot.path), ["a.png"])
    }

    /// A trailing slash, a `.`, a `..` — all the same folder, and all still refused. Written
    /// because path guards usually pass the obvious case and fail the typed one.
    func testDestinationSpelledAwkwardlyIsStillRefused() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writePhoto(dir.appendingPathComponent("a.png"))

        for spelling in [dir.path + "/", dir.path + "/.", dir.path + "/../" + dir.lastPathComponent] {
            let dest = URL(fileURLWithPath: spelling, isDirectory: true)
            XCTAssertThrowsError(try BatchApply.run(inputDir: dir, recipe: .neutral, outputDir: dest),
                                 "\(spelling) is the source folder and must be refused")
        }
    }

    /// The guard must not be so eager that it blocks the workflow it exists to serve: an
    /// `Edited/` subfolder inside the shoot is the most natural place to put the copies, and it
    /// is safe because `imageFiles(in:)` does not recurse.
    func testDestinationInsideTheSourceFolderIsAllowed() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writePhoto(dir.appendingPathComponent("a.png"))

        let outcome = try BatchApply.run(inputDir: dir, recipe: .neutral,
                                         outputDir: dir.appendingPathComponent("Edited"))
        XCTAssertEqual(outcome.succeeded, 1)
        XCTAssertEqual(try BatchApply.imageFiles(in: dir).map { $0.lastPathComponent }, ["a.png"],
                       "the copies land in the subfolder, not beside the originals")
    }

    func testDestinationThatIsAFileIsRefused() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writePhoto(dir.appendingPathComponent("a.png"))
        let notAFolder = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notAFolder)

        XCTAssertThrowsError(try BatchApply.run(inputs: [dir.appendingPathComponent("a.png")],
                                                recipe: .neutral, outputDir: notAFolder)) { error in
            XCTAssertEqual(error as? BatchApply.Destination.Problem, .notADirectory(notAFolder))
        }
        XCTAssertEqual(try Data(contentsOf: notAFolder), Data("hello".utf8),
                       "and the file that was in the way is left alone")
    }

    // MARK: Creating the destination

    /// "Choose where to write edits" includes folders that do not exist yet — a photographer
    /// typing `2026-07-24/selects` into a save panel means it, and failing there wastes the run.
    func testMissingDestinationIsCreatedIncludingIntermediateFolders() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let root = try makeTempDir(); defer { try? FileManager.default.removeItem(at: root) }
        try writePhoto(inDir.appendingPathComponent("a.png"))

        let nested = root.appendingPathComponent("2026-07-24").appendingPathComponent("selects")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))

        let outcome = try BatchApply.run(inputDir: inDir, recipe: .neutral, outputDir: nested)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(outcome.succeeded, 1)
        XCTAssertEqual(outcome.written.first?.deletingLastPathComponent().standardizedFileURL,
                       nested.standardizedFileURL)
    }

    // MARK: Collisions

    /// The default. Two runs into the same folder must leave two sets of files: the user changed
    /// something between them, and neither the old nor the new render is ours to delete.
    func testDefaultPolicyKeepsBothTheOldExportAndTheNewOne() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }
        try writePhoto(inDir.appendingPathComponent("a.png"))

        var vivid = Recipe.neutral
        vivid.global.exposureEV = 1.2

        let first = try BatchApply.run(inputDir: inDir, recipe: .neutral, outputDir: outDir)
        let firstBytes = try Data(contentsOf: XCTUnwrap(first.written.first))
        let second = try BatchApply.run(inputDir: inDir, recipe: vivid, outputDir: outDir)

        XCTAssertEqual(second.succeeded, 1)
        XCTAssertNotEqual(second.written.first, first.written.first,
                          "the second run must not claim the first run's filename")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(first.written.first)), firstBytes,
                       "the first export is byte-identical afterwards")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outDir.path).count, 2)
    }

    /// `skip` keeps what is already there and says so. This is the resume-an-interrupted-batch
    /// policy: cheap, and it never re-renders what already landed.
    func testSkipPolicyLeavesTheExistingFileAndReportsIt() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }
        let src = inDir.appendingPathComponent("a.png")
        try writePhoto(src)

        let existing = outDir.appendingPathComponent(
            ExportNaming.filename(for: src, perception: nil, look: nil, ext: "png"))
        try Data("an earlier export".utf8).write(to: existing)

        let outcome = try BatchApply.run(
            inputDir: inDir, recipe: .neutral,
            destination: .init(directory: outDir, onCollision: .skip, format: .png))

        XCTAssertEqual(outcome.succeeded, 0)
        XCTAssertEqual(outcome.skipped.map { $0.lastPathComponent }, [src.lastPathComponent])
        XCTAssertEqual(outcome.items.first?.result, .skipped(existing: existing),
                       "the report names the file that was in the way, so a UI can point at it")
        XCTAssertEqual(try Data(contentsOf: existing), Data("an earlier export".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outDir.path).count, 1,
                       "skip writes nothing, not even under another name")
    }

    /// `overwrite` exists, but only reachable by asking for it. It is the one policy that
    /// destroys a file, so the test asserts it does exactly that and nothing more.
    func testOverwritePolicyReplacesInPlaceWhenExplicitlyRequested() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }
        let src = inDir.appendingPathComponent("a.png")
        try writePhoto(src)

        let target = outDir.appendingPathComponent(
            ExportNaming.filename(for: src, perception: nil, look: nil, ext: "png"))
        try Data("an earlier export".utf8).write(to: target)

        let outcome = try BatchApply.run(
            inputDir: inDir, recipe: .neutral,
            destination: .init(directory: outDir, onCollision: .overwrite, format: .png))

        XCTAssertEqual(outcome.written, [target], "it reuses the name rather than suffixing")
        XCTAssertNoThrow(try ImageDecoder.decode(url: target), "and the replacement is a real image")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outDir.path).count, 1)
    }

    /// Two different originals whose names sanitise to the same stem — `IMG_001.png` and
    /// `img-001.png` land on `img-001` — must not fight over one output. This is the collision
    /// that happens WITHIN a single run, where a re-run policy would not save anyone.
    func testTwoSourcesThatSanitiseToTheSameNameBothSurvive() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }
        try writePhoto(inDir.appendingPathComponent("IMG_001.png"))
        try writePhoto(inDir.appendingPathComponent("img-001.png"))

        let outcome = try BatchApply.run(inputDir: inDir, recipe: .neutral, outputDir: outDir)

        XCTAssertEqual(outcome.succeeded, 2)
        XCTAssertEqual(Set(outcome.written).count, 2, "two inputs, two distinct outputs")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outDir.path).count, 2)
    }

    // MARK: Format

    /// The extension has to say what is actually inside the file.
    func testFormatDecidesTheExtension() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }
        try writePhoto(inDir.appendingPathComponent("a.png"))

        let outcome = try BatchApply.run(
            inputDir: inDir, recipe: .neutral,
            destination: .init(directory: outDir, format: .jpeg(quality: 0.9)))

        XCTAssertEqual(outcome.written.first?.pathExtension, "jpg")
        let head = try Data(contentsOf: XCTUnwrap(outcome.written.first)).prefix(2)
        XCTAssertEqual(Array(head), [0xFF, 0xD8], "a .jpg must actually be a JPEG")
    }
}
