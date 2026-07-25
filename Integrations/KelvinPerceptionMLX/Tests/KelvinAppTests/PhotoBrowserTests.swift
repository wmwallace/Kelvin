import XCTest
import KelvinCore
import KelvinPerceptionMLX
@testable import KelvinApp

/// What the filmstrip lists when you open one photograph: the rest of the shoot sitting next to it.
///
/// The rule that matters is "what you can browse is what Kelvin can actually edit" — a strip that
/// offers a `.txt` or a `.mov` is offering a click that cannot work.
final class PhotoBrowserTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    @discardableResult
    private func touch(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    func testTheStripListsTheShootInFilenameOrder() throws {
        try touch("_DSC0010.ARW"); try touch("_DSC0002.ARW"); try touch("_DSC0001.ARW")
        let opened = dir.appendingPathComponent("_DSC0002.ARW")
        XCTAssertEqual(names(PhotoBrowser.siblings(of: opened)),
                       ["_DSC0001.ARW", "_DSC0002.ARW", "_DSC0010.ARW"],
                       "numeric-aware order — _DSC0010 sorts after _DSC0002, not between 0001 and 0002")
    }

    /// Non-photographs in the folder — a contact sheet PDF, a notes file, the Finder's own
    /// droppings — are not frames of the shoot and must not appear as ones.
    func testFilesKelvinCannotEditAreNotOfferedAsFrames() throws {
        let photo = try touch("_DSC0001.ARW")
        try touch("notes.txt"); try touch("contact-sheet.pdf"); try touch(".DS_Store")
        XCTAssertEqual(names(PhotoBrowser.siblings(of: photo)), ["_DSC0001.ARW"])
    }

    /// A photo whose folder Kelvin cannot read — or which is the only thing in it — still has to
    /// produce a strip containing itself. Returning nothing would leave the open photograph
    /// missing from its own filmstrip.
    func testThePhotoYouOpenedIsAlwaysInTheStrip() {
        let orphan = dir.appendingPathComponent("nowhere/_DSC0001.ARW")
        XCTAssertEqual(PhotoBrowser.siblings(of: orphan), [orphan])
    }
}

/// The one perception detail that lives outside KelvinCore: which model the provider actually runs.
///
/// `KELVIN_MODEL=<hf-repo-id>` swaps the VLM without a rebuild. The trap already sprung once — an
/// unset variable is nil, but `KELVIN_MODEL=` in a shell profile is the empty *string*, which sails
/// through a `??` and fails much later as `invalidRepositoryID("")`. That is a confusing way to
/// learn you have an empty export, and it fails after the app has already started loading.
final class PerceptionModelSelectionTests: XCTestCase {

    override func tearDown() {
        unsetenv("KELVIN_MODEL")
        super.tearDown()
    }

    func testWithNothingSetItRunsTheDefaultModel() {
        unsetenv("KELVIN_MODEL")
        XCTAssertEqual(MLXPerceptionProvider().activeModelID, MLXPerceptionProvider.defaultModelID)
    }

    func testTheEnvironmentOverrideSelectsAnotherModel() {
        setenv("KELVIN_MODEL", "mlx-community/some-other-vlm-4bit", 1)
        XCTAssertEqual(MLXPerceptionProvider().activeModelID, "mlx-community/some-other-vlm-4bit")
    }

    /// An empty export means "I have no opinion", not "load the repository named empty string".
    func testAnEmptyEnvironmentVariableFallsBackToTheDefault() {
        setenv("KELVIN_MODEL", "", 1)
        XCTAssertEqual(MLXPerceptionProvider().activeModelID, MLXPerceptionProvider.defaultModelID,
                       "an empty KELVIN_MODEL must not become invalidRepositoryID(\"\")")
    }

    /// Same for whitespace, which is what a copy-pasted line in a profile leaves behind.
    func testAWhitespaceOnlyEnvironmentVariableFallsBackToTheDefault() {
        setenv("KELVIN_MODEL", "   \n", 1)
        XCTAssertEqual(MLXPerceptionProvider().activeModelID, MLXPerceptionProvider.defaultModelID)
    }

    /// A repo id pasted with a stray newline still names a real model; trimming it is the
    /// difference between "it worked" and a download failure with no obvious cause.
    func testASurroundingWhitespaceIsTrimmedFromTheModelID() {
        setenv("KELVIN_MODEL", "  mlx-community/some-other-vlm-4bit  ", 1)
        XCTAssertEqual(MLXPerceptionProvider().activeModelID, "mlx-community/some-other-vlm-4bit")
    }

    /// An explicit argument beats the environment: a caller that names a model is comparing two on
    /// purpose, and a leftover export must not silently redirect the comparison.
    func testAnExplicitModelIDWinsOverTheEnvironment() {
        setenv("KELVIN_MODEL", "mlx-community/from-the-environment", 1)
        XCTAssertEqual(MLXPerceptionProvider(modelID: "mlx-community/explicit").activeModelID,
                       "mlx-community/explicit")
    }

    /// The default is a licence decision, not a tuning one: Kelvin needs commercially-clean
    /// weights, and the model it shipped with before was research-only. Pinning the id here means
    /// changing it is a deliberate act with a test to explain itself to.
    func testTheDefaultModelIsTheLicenceCleanOne() {
        XCTAssertEqual(MLXPerceptionProvider.defaultModelID, "mlx-community/Qwen3.5-2B-MLX-4bit",
                       "changing the default model means re-reading its licence — see the comment "
                       + "on MLXPerceptionProvider.defaultModelID, which was wrong once already")
    }
}
