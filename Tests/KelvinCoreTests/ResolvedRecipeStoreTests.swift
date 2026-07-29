import XCTest
@testable import KelvinCore

/// The resolved-recipe cache, which exists because photo + style → recipe is deterministic and
/// costs 1.87s of a 20.03s export frame to work out.
///
/// The rules pinned here are the invalidation rules. A cache that serves a *stale* recipe is the
/// worst outcome available: it is silent, it survives quitting, and — because the whole point of
/// the engine's environment overrides is to sweep the sky lever — it would make a parameter change
/// look like it had no effect. That reading has been produced once already in this codebase by a
/// stale binary, and it very nearly went into the handoff as a finding.
final class ResolvedRecipeStoreTests: XCTestCase {

    private var photo: URL!
    private let model = "model-a"

    override func setUpWithError() throws {
        photo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-recipe-\(UUID().uuidString).jpg")
        try Data("original".utf8).write(to: photo)
    }

    override func tearDownWithError() throws {
        for style in ["dramatic", "natural"] {
            ResolvedRecipeStore.remove(for: photo, styleId: style, modelId: model)
        }
        try? FileManager.default.removeItem(at: photo)
    }

    private func recipe(label: String) -> Recipe {
        var r = Recipe.neutral
        r.label = label
        r.id = label.lowercased()
        return r
    }

    // MARK: The basic bargain

    func testARecipeComesBackAsItWentIn() throws {
        let original = recipe(label: "Dramatic")
        ResolvedRecipeStore.save(original, for: photo, styleId: "dramatic", modelId: model)
        let back = try XCTUnwrap(
            ResolvedRecipeStore.load(for: photo, styleId: "dramatic", modelId: model))
        XCTAssertEqual(back, original)
    }

    func testAnUnresolvedPhotographIsAMiss() {
        XCTAssertNil(ResolvedRecipeStore.load(for: photo, styleId: "dramatic", modelId: model))
    }

    /// Two styles are two different answers about the same photograph, and the export names the
    /// file after the recipe's own label — so sharing an entry would put one look's name on
    /// another look's pixels.
    func testTwoStylesDoNotShareAnEntry() throws {
        ResolvedRecipeStore.save(recipe(label: "Dramatic"), for: photo,
                                 styleId: "dramatic", modelId: model)
        XCTAssertNil(ResolvedRecipeStore.load(for: photo, styleId: "natural", modelId: model),
                     "one style was served another style's recipe")
    }

    func testARecipeFromAnotherModelIsNotServed() {
        ResolvedRecipeStore.save(recipe(label: "Dramatic"), for: photo,
                                 styleId: "dramatic", modelId: "qwen-2b")
        XCTAssertNil(ResolvedRecipeStore.load(for: photo, styleId: "dramatic", modelId: "qwen-7b"),
                     "a recipe built on one model's reading was served for another")
        ResolvedRecipeStore.remove(for: photo, styleId: "dramatic", modelId: "qwen-2b")
    }

    // MARK: Invalidation — the part that has to be right

    /// **A sweep must never be served the previous arm's recipes.** `KELVIN_SKY_EV` and friends
    /// exist so the sky lever can be re-measured without a rebuild; a cache blind to them would
    /// hand back the old arm's answers and print two identical tables, which reads exactly like
    /// "the parameter has no effect".
    ///
    /// The overrides resolve once per process, so this cannot be driven by setting an environment
    /// variable mid-test. Instead it writes an entry whose recorded tuning is not the current one —
    /// which is precisely the on-disk state a sweep produces — and asserts it is not served.
    func testAnEntryFromDifferentEngineTuningIsNotServed() throws {
        let location = ResolvedRecipeStore.url(for: photo, styleId: "dramatic", modelId: model)
        let stale = CachedRecipe(
            engineVersion: RecipeEngine.version,
            modelId: model,
            styleId: "dramatic",
            tuning: RecipeEngine.tuningSignature + ";skyEV:from-another-sweep",
            recipe: recipe(label: "Dramatic"),
            resolvedAt: "2026-07-28T00:00:00Z",
            contentHint: PerceptionStore.contentHint(for: photo))
        let encoder = JSONEncoder()
        try encoder.encode(stale).write(to: location, options: .atomic)

        XCTAssertNil(ResolvedRecipeStore.load(for: photo, styleId: "dramatic", modelId: model),
                     "a recipe resolved under different engine tuning was served to this one")
    }

    /// The signature has to actually mention the levers, or the check above passes while guarding
    /// nothing. Cheap, and it fails the moment someone adds an override and forgets this list.
    func testTheTuningSignatureCoversTheSkyLeverAndTheMaskConstants() {
        let signature = RecipeEngine.tuningSignature
        for expected in ["skyEV", "skyClamp", "skyBite", "skyFeather", "maskFloor", "maskRamp"] {
            XCTAssertTrue(signature.contains(expected),
                          "\(expected) is missing from the tuning signature, so changing it would be cached over")
        }
        XCTAssertTrue(signature.contains("\(RecipeEngine.SkyLever.evPerDepth)"),
                      "the signature must carry the lever's VALUE, not just its name")
    }

    func testAChangedFileInvalidatesItsRecipe() throws {
        ResolvedRecipeStore.save(recipe(label: "Dramatic"), for: photo,
                                 styleId: "dramatic", modelId: model)
        XCTAssertNotNil(ResolvedRecipeStore.load(for: photo, styleId: "dramatic", modelId: model))

        try Data("replaced with something considerably longer".utf8).write(to: photo)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: photo.path)
        XCTAssertNil(ResolvedRecipeStore.load(for: photo, styleId: "dramatic", modelId: model),
                     "a replaced file kept the old file's recipe")
    }

    /// The same reorganisation-survives rule as the perception cache, and for the same reason —
    /// these two caches must agree about what "the same photograph" means.
    func testMovingAPhotographKeepsItsRecipe() throws {
        let original = recipe(label: "Dramatic")
        ResolvedRecipeStore.save(original, for: photo, styleId: "dramatic", modelId: model)

        let moved = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-recipe-moved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let destination = moved.appendingPathComponent(photo.lastPathComponent)
        try FileManager.default.moveItem(at: photo, to: destination)
        defer {
            ResolvedRecipeStore.remove(for: destination, styleId: "dramatic", modelId: model)
            try? FileManager.default.removeItem(at: moved)
            try? Data("original".utf8).write(to: photo)
        }

        XCTAssertEqual(
            ResolvedRecipeStore.load(for: destination, styleId: "dramatic", modelId: model),
            original,
            "a photograph filed into a different folder lost a recipe it had already paid for")
    }
}
