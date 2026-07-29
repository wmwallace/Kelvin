import Foundation
import CryptoKit
import os

/// The recipe a photograph resolves to under a given style, kept between launches.
///
/// **Photo + style → recipe is a pure function**, which is the whole justification for this file.
/// Every input is deterministic: the perception (itself cached, and pinned to a model), the
/// histogram, the mask measurements, the ISO, and the engine's own rules. Same photograph, same
/// style, same engine, same answer — so it can be computed once and kept forever, and deleting it
/// costs nothing but the work again.
///
/// **What it saves.** `adaptedRecipe` is the export path's photo → recipe step, and on a cache hit
/// the whole of it is skipped, decode included: the caller decodes separately for the render. On
/// real 60 MP ARWs (`kelvin-perceive bench-export`, 6 frames) that is proxy 1.15s + statistics
/// 0.01s + proxy masks 0.21s + engine 0.00s + curate 0.50s = **1.87s of a 20.03s frame**, and
/// `curate` is the expensive half because resolving a style means rendering and scoring the WHOLE
/// candidate set, not just the one asked for (`CandidateCurator.resolve` — a style is dropped by the
/// quality floor, OR by near-duplication, OR by the four-slot cap, and the last two are unanswerable
/// without the rest of the pool).
///
/// **What invalidates it**, and every one of these is in the key rather than merely checked, so a
/// stale entry is unreachable rather than merely rejected:
///
///   • the photograph's bytes — name + size + mtime, the identity rule `PerceptionStore` uses
///   • the requested style
///   • `RecipeEngine.version`, bumped on any change that moves the numbers
///   • the perception model, because a different read is a different recipe
///   • **the engine's tunable environment** — see `RecipeEngine.tuningSignature`. This one is easy
///     to forget and it matters: `KELVIN_SKY_EV` and friends exist so the sky lever can be swept
///     without a rebuild, and a cache blind to them would serve the previous arm's recipes and
///     report that the parameter has no effect. That failure has already happened once in this
///     codebase for a different reason (a stale binary, recorded in docs/EVALUATION.md), and it
///     reads exactly like a finding.
///
/// Not written beside anyone's originals, for the reason recorded on `EditStore`: Kelvin does not
/// create files inside a photography library.
public struct CachedRecipe: Codable {
    public var version: Int = 1
    public var engineVersion: String
    public var modelId: String
    public var styleId: String
    /// The engine's overridable tuning at the moment this was resolved. In the key too; kept in the
    /// body so a cache directory can be read by a human wondering which arm wrote it.
    public var tuning: String
    public var recipe: Recipe
    public var resolvedAt: String
    /// Size and modification date, the same cheap staleness hint `PerceptionStore` uses.
    public var contentHint: String?
}

public enum ResolvedRecipeStore {

    private static let log = Logger(subsystem: Branding.bundleIdentifier, category: "ResolvedRecipeStore")

    /// Beside the perception cache, under the app's own Application Support folder. Resolved here
    /// rather than borrowed from the app because the headless tools want it too.
    public static let directory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let base = appSupport
            .appendingPathComponent(Branding.displayName)
            .appendingPathComponent("recipes")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Identity is the photograph's, plus everything that changes the answer.
    ///
    /// The photograph half deliberately reuses `PerceptionStore.contentHint` rather than restating
    /// it: two caches that disagree about what "the same photograph" means is exactly the class of
    /// bug the three review findings on PR #1 all turned out to be — one rule written down twice.
    private static func key(for photo: URL, styleId: String, modelId: String) -> String {
        let identity = PerceptionStore.contentHint(for: photo)
            .map { "\(photo.lastPathComponent)-\($0)" }
            ?? photo.standardizedFileURL.path
        let full = [identity, styleId, RecipeEngine.version, modelId,
                    RecipeEngine.tuningSignature].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(full.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    public static func url(for photo: URL, styleId: String, modelId: String) -> URL {
        directory
            .appendingPathComponent(key(for: photo, styleId: styleId, modelId: modelId))
            .appendingPathExtension("json")
    }

    /// The stored recipe for this photograph under this style, or nil if there is none or the file
    /// has changed since. A miss is only ever slow, never wrong.
    public static func load(for photo: URL, styleId: String, modelId: String) -> Recipe? {
        let location = url(for: photo, styleId: styleId, modelId: modelId)
        guard let data = try? Data(contentsOf: location),
              let cached = try? JSONDecoder().decode(CachedRecipe.self, from: data)
        else { return nil }
        // The key already encodes all of these, so a mismatch means a hash collision or a file
        // edited by hand. Cheap to check, and a wrong recipe is silent in a way a miss is not.
        guard cached.engineVersion == RecipeEngine.version,
              cached.modelId == modelId,
              cached.styleId == styleId,
              cached.tuning == RecipeEngine.tuningSignature
        else { return nil }
        if let hint = cached.contentHint,
           let now = PerceptionStore.contentHint(for: photo), hint != now { return nil }
        return cached.recipe
    }

    public static func save(_ recipe: Recipe, for photo: URL, styleId: String, modelId: String) {
        let entry = CachedRecipe(
            engineVersion: RecipeEngine.version,
            modelId: modelId,
            styleId: styleId,
            tuning: RecipeEngine.tuningSignature,
            recipe: recipe,
            resolvedAt: ISO8601DateFormatter().string(from: Date()),
            contentHint: PerceptionStore.contentHint(for: photo))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(entry)
                .write(to: url(for: photo, styleId: styleId, modelId: modelId), options: .atomic)
        } catch {
            // A cache that cannot write is slow, not broken. Never propagate.
            log.error("could not store resolved recipe: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func remove(for photo: URL, styleId: String, modelId: String) {
        try? FileManager.default
            .removeItem(at: url(for: photo, styleId: styleId, modelId: modelId))
    }
}
