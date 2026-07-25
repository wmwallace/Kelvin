import Foundation
import CoreImage
import KelvinCore

// Headless entry point. This is a first-class target — it is how the eval harness will run
// (ARCHITECTURE.md), not a debug affordance. Milestone 1 ships one subcommand: `render`.
//
// Arg parsing is hand-rolled to keep M1 dependency-free and buildable offline. It is
// deliberately small; swift-argument-parser is the intended replacement once a second
// subcommand (`eval`) exists and the flag surface grows.

let tool = Branding.displayName.lowercased() + "-cli"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func printUsage() {
    print("""
    \(Branding.displayName) CLI

    Usage:
      \(tool) render --in <image> --recipe <recipe.json> --out <output>
      \(tool) engine --in <image> --perception <perception.json> --out <recipe.json>
      \(tool) candidates --in <image> --perception <perception.json> --out-dir <dir>
      \(tool) batch --in-dir <dir> --recipe <recipe.json> --out-dir <dir> [--format png|jpg]
      \(tool) corpus-init --root <dir> --references <a,b,c> [--source <dir>] [--perception <dir>]
      \(tool) corpus-degrade --in-dir <good-photos> --out-dir <corpus>
      \(tool) eval --corpus <dir> [--out <report.json>] [--engine-version <v>]

    render options:
      --in       Path to the source image (RAW, JPEG, or PNG). Required.
      --recipe   Path to a recipe JSON sidecar. Required.
      --out      Output path. Extension picks the format (.png or .jpg). Required.

    engine options:
      --in          Path to the source image (RAW, JPEG, or PNG). Required.
      --perception  Path to a hand-labelled perception JSON (Stage 1). Required.
      --out         Where to write the generated recipe JSON. Required.

    candidates options:
      --in          Path to the source image (RAW, JPEG, or PNG). Required.
      --perception  Path to a hand-labelled perception JSON (Stage 1). Required.
      --out-dir     Directory to write one <style>.json per candidate. Required.

    batch options:
      --in-dir      Directory of source images to propagate the recipe across. Required.
      --recipe      Path to a recipe JSON sidecar. Required.
      --out-dir     Directory to write rendered outputs (originals untouched). Required.
      --format      png (default) or jpg.

    corpus-init options:
      --root        Dataset root containing the source and expert folders. Required.
      --references  Comma-separated expert subfolders (e.g. target_a,target_b,target_c). Required.
      --source      Source-image subfolder. Default "source".
      --perception  Optional subfolder of per-image perception JSON (<id>.json).
      --camera      Optional subfolder of manufacturer JPEGs (<id>.jpg).
      --out         Where to write manifest.json. Default <root>/manifest.json.

    corpus-degrade options (commercial-clean: good photos → degraded sources + originals):
      --in-dir      Folder of good photographs you own (references). Required.
      --out-dir     Where to write reference/, source/, and manifest.json. Required.

    eval options:
      --corpus          Directory containing a manifest.json. Required.
      --out             Where to write report.json. Optional; table always prints.
      --engine-version  Label recorded in the report. Default 0.1.0.

    Other:
      -h, --help  Show this help.
    """)
}

/// Minimal `--flag value` extractor. Returns the value following `flag`, or nil.
func value(for flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())

guard let subcommand = arguments.first else {
    printUsage()
    exit(0)
}

if subcommand == "-h" || subcommand == "--help" {
    printUsage()
    exit(0)
}

switch subcommand {
case "render":
    let rest = Array(arguments.dropFirst())

    guard let inPath = value(for: "--in", in: rest) else { fail("render requires --in") }
    guard let recipePath = value(for: "--recipe", in: rest) else { fail("render requires --recipe") }
    guard let outPath = value(for: "--out", in: rest) else { fail("render requires --out") }

    let inURL = URL(fileURLWithPath: inPath)
    let recipeURL = URL(fileURLWithPath: recipePath)
    let outURL = URL(fileURLWithPath: outPath)

    do {
        let image = try ImageDecoder.decode(url: inURL)
        let recipe = try RecipeIO.load(from: recipeURL)   // clamps on decode
        // Supply subject/sky bitmaps so any local masks the recipe references are applied; the
        // renderer ignores masks it has no bitmap for, so measuring unconditionally is safe.
        let measured = LocalMasks.measure(in: image)
        let rendered = Renderer.render(image, with: recipe, maskBitmaps: measured.bitmaps)
        try ImageWriter.write(rendered, to: outURL)
        print("Wrote \(outURL.path)")
    } catch {
        fail("\(error)")
    }

case "engine":
    let rest = Array(arguments.dropFirst())

    guard let inPath = value(for: "--in", in: rest) else { fail("engine requires --in") }
    guard let perceptionPath = value(for: "--perception", in: rest) else { fail("engine requires --perception") }
    guard let outPath = value(for: "--out", in: rest) else { fail("engine requires --out") }

    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let stats = try ImageStatistics.compute(image)
        let perception = try PerceptionIO.load(from: URL(fileURLWithPath: perceptionPath))
        let measured = LocalMasks.measure(in: image)
        let recipe = RecipeEngine.recipe(
            perception: perception,
            statistics: stats,
            subjectLuma: measured.subjectLuma,
            skyLuma: measured.skyLuma,
            iso: ExifReader.iso(url: URL(fileURLWithPath: inPath)),
            perceptionHash: PerceptionIO.hash(perception),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
        try RecipeIO.save(recipe, to: URL(fileURLWithPath: outPath))
        print("Wrote \(outPath) [\(recipe.label ?? "recipe")]")
    } catch {
        fail("\(error)")
    }

case "candidates":
    let rest = Array(arguments.dropFirst())

    guard let inPath = value(for: "--in", in: rest) else { fail("candidates requires --in") }
    guard let perceptionPath = value(for: "--perception", in: rest) else { fail("candidates requires --perception") }
    guard let outDirPath = value(for: "--out-dir", in: rest) else { fail("candidates requires --out-dir") }

    let outDir = URL(fileURLWithPath: outDirPath, isDirectory: true)

    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let stats = try ImageStatistics.compute(image)
        let perception = try PerceptionIO.load(from: URL(fileURLWithPath: perceptionPath))
        let measured = LocalMasks.measure(in: image)
        // One perception, one statistics pass → N recipes (parameter swaps, no re-perception).
        let recipes = RecipeEngine.candidates(
            perception: perception,
            statistics: stats,
            subjectLuma: measured.subjectLuma,
            skyLuma: measured.skyLuma,
            iso: ExifReader.iso(url: URL(fileURLWithPath: inPath)),
            perceptionHash: PerceptionIO.hash(perception),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // Optional: --render also writes a preview PNG per candidate (masks applied).
        let alsoRender = rest.contains("--render")
        for recipe in recipes {
            let base = recipe.id ?? recipe.label ?? "candidate"
            try RecipeIO.save(recipe, to: outDir.appendingPathComponent(base + ".json"))
            if alsoRender {
                let rendered = Renderer.render(image, with: recipe, maskBitmaps: measured.bitmaps)
                try ImageWriter.write(rendered, to: outDir.appendingPathComponent(base + ".png"), format: .png)
            }
        }
        // What the picker would actually show, after scoring and curation.
        let scoredItems = recipes.compactMap { recipe -> CandidateCurator.Scored? in
            let out = Renderer.render(image, with: recipe, maskBitmaps: measured.bitmaps)
            guard let score = AestheticEvaluator.score(rendered: out) else { return nil }
            return .init(recipe: recipe, score: score)
        }
        let curatedSet = CandidateCurator.select(from: scoredItems, count: 4)
        print("curated: " + curatedSet.map {
            String(format: "%@ %.2f", $0.recipe.label ?? "?", $0.score.overall)
        }.joined(separator: ", "))
        let dropped = recipes.compactMap { $0.label }
            .filter { l in !curatedSet.contains { $0.recipe.label == l } }
        if !dropped.isEmpty { print("dropped: " + dropped.joined(separator: ", ")) }

        let labels = recipes.map { $0.label ?? "?" }.joined(separator: ", ")
        let sky = measured.skyLuma.map { String(format: "sky luma %.2f", $0) } ?? "no sky"
        print("Wrote \(recipes.count) candidates to \(outDir.path) [\(labels)] (\(sky))")
    } catch {
        fail("\(error)")
    }

case "batch":
    let rest = Array(arguments.dropFirst())

    guard let inDirPath = value(for: "--in-dir", in: rest) else { fail("batch requires --in-dir") }
    guard let recipePath = value(for: "--recipe", in: rest) else { fail("batch requires --recipe") }
    guard let outDirPath = value(for: "--out-dir", in: rest) else { fail("batch requires --out-dir") }

    let format: ImageWriter.Format
    switch value(for: "--format", in: rest)?.lowercased() {
    case "jpg", "jpeg": format = .jpeg(quality: 0.92)
    case "png", nil: format = .png
    case let other?: fail("unknown --format '\(other)' (use png or jpg)")
    }

    do {
        let recipe = try RecipeIO.load(from: URL(fileURLWithPath: recipePath))
        let outcome = try BatchApply.run(
            inputDir: URL(fileURLWithPath: inDirPath, isDirectory: true),
            recipe: recipe,
            outputDir: URL(fileURLWithPath: outDirPath, isDirectory: true),
            format: format
        )
        print("Applied recipe to \(outcome.succeeded) image(s), \(outcome.failed) failed.")
        for failure in outcome.failures {
            FileHandle.standardError.write(Data("  skipped \(failure.source.lastPathComponent): \(failure.message)\n".utf8))
        }
    } catch {
        fail("\(error)")
    }

case "corpus-init":
    let rest = Array(arguments.dropFirst())

    guard let rootPath = value(for: "--root", in: rest) else { fail("corpus-init requires --root") }
    guard let refsArg = value(for: "--references", in: rest) else { fail("corpus-init requires --references") }
    let references = refsArg.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    guard !references.isEmpty else { fail("--references must list at least one folder") }

    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let options = CorpusBuilder.Options(
        sourceDir: value(for: "--source", in: rest) ?? "source",
        referenceDirs: references,
        perceptionDir: value(for: "--perception", in: rest),
        cameraJpegDir: value(for: "--camera", in: rest)
    )

    do {
        let outURL = value(for: "--out", in: rest).map { URL(fileURLWithPath: $0) }
        let manifest = try CorpusBuilder.write(root: root, options: options, to: outURL)
        let labelled = manifest.entries.filter { $0.perception != nil }.count
        print("Wrote manifest with \(manifest.entries.count) entries "
            + "(\(references.count) experts each, \(labelled) with perception labels) to "
            + (outURL?.path ?? root.appendingPathComponent("manifest.json").path))
    } catch {
        fail("\(error)")
    }

case "corpus-degrade":
    let rest = Array(arguments.dropFirst())

    guard let inDir = value(for: "--in-dir", in: rest) else { fail("corpus-degrade requires --in-dir") }
    guard let outDir = value(for: "--out-dir", in: rest) else { fail("corpus-degrade requires --out-dir") }

    do {
        let photos = try BatchApply.imageFiles(in: URL(fileURLWithPath: inDir, isDirectory: true))
        guard !photos.isEmpty else { fail("no images in \(inDir)") }
        let manifest = try DegradationCorpus.build(
            goodPhotos: photos,
            outputDir: URL(fileURLWithPath: outDir, isDirectory: true)
        )
        let photoCount = Set(manifest.entries.map { $0.id.components(separatedBy: "__").first ?? $0.id }).count
        print("Built degradation corpus: \(photoCount) photo(s) × \(DegradationCorpus.standard.count) "
            + "degradations = \(manifest.entries.count) entries in \(outDir)")
        print("Next: kelvin-perceive label --in-dir \(outDir)/source --out-dir \(outDir)/perception")
        print("Then: \(tool) eval --corpus \(outDir)")
    } catch {
        fail("\(error)")
    }

case "mask":
    // Debug/inspection: segment the subject and preview a local lift through the mask.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("mask requires --in") }
    guard let outDirPath = value(for: "--out-dir", in: rest) else { fail("mask requires --out-dir") }
    let outDir = URL(fileURLWithPath: outDirPath, isDirectory: true)
    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let personMask = SubjectMask.person(in: image)
        guard let mask = personMask ?? SubjectMask.foreground(in: image) else {
            fail("no subject found in \(inPath)")
        }
        print(personMask != nil ? "source: person segmentation" : "source: foreground instance (no person)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try ImageWriter.write(mask, to: outDir.appendingPathComponent("mask.png"), format: .png)
        if let luma = SubjectMask.maskedMeanLuma(image: image, mask: mask) {
            print(String(format: "subject mean luma: %.3f", luma))
        }
        let skin = FaceSkin.read(in: image)
        if let luma = skin.skinLuma {
            print(String(format: "faces: %d, skin luma: %.3f, hue: %.0f°, saturation: %.2f",
                         skin.faceCount, luma, skin.skinHueDegrees ?? -1, skin.skinSaturation ?? -1))
        } else { print("faces: \(skin.faceCount) (no skin metered)") }
        let subjectMask = Mask(id: "subject", type: "subject", source: "segmentation",
                               invert: false, feather: 15, opacity: 1.0,
                               adjustments: ["exposure_ev": 0.7, "shadows": 25])
        var recipe = Recipe.neutral
        recipe.masks = [subjectMask]
        let lifted = Renderer.render(image, with: recipe, maskBitmaps: ["subject": mask])
        try ImageWriter.write(lifted, to: outDir.appendingPathComponent("lifted.png"), format: .png)
        print("Wrote mask.png + lifted.png to \(outDir.path)")
    } catch {
        fail("\(error)")
    }

case "bench":
    // Where does interactive render time actually go? Measures the proxy render + read-back for
    // each stage, so optimisation targets are chosen from data rather than guesswork.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("bench requires --in") }
    do {
        let full = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let proxy = PerceptionProxy.downsample(full, maxEdge: 1200)
        let ctx = CIContext(options: [.cacheIntermediates: true])
        _ = ctx.createCGImage(proxy, from: proxy.extent)     // warm up

        func bench(_ label: String, _ recipe: Recipe, _ n: Int = 11) {
            var times: [Double] = []
            for _ in 0..<n {
                let start = Date()
                let out = Renderer.render(proxy, with: recipe, maskBitmaps: [:])
                _ = ctx.createCGImage(out, from: out.extent)
                times.append(Date().timeIntervalSince(start) * 1000)
            }
            times.sort()
            print(String(format: "  %-32@ median %6.1f ms", label as NSString, times[n / 2]))
        }

        var g = GlobalAdjustments.neutral
        g.exposureEV = 0.3; g.contrast = 12; g.vibrance = 8; g.shadows = 15; g.highlights = -20
        func recipe(_ mutate: (inout Recipe) -> Void = { _ in }) -> Recipe {
            var r = Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil, global: g,
                           curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
            mutate(&r); return r
        }
        print("Interactive render benchmark — proxy \(Int(proxy.extent.width))×\(Int(proxy.extent.height))")
        bench("globals only", recipe())
        bench("+ HSL cube (colour mixer)", recipe { $0.hsl = ["blue": HSLAdjustment(h: 5, s: 20, l: -10)] })
        bench("+ colour-selection mask", recipe {
            $0.masks = [Mask(id: "c", type: "color", source: "selection", invert: false, feather: 0,
                             opacity: 1, adjustments: ["exposure_ev": -1],
                             selection: MaskSelection(kind: .color, center: 0.33, range: 0.1, softness: 0.08))]
        })
        bench("+ straighten 4°", recipe { $0.geometry = Geometry(rotateDeg: 4, crop: nil, lensCorrection: false) })
        bench("+ clarity (halo-suppressed)", recipe { $0.global.clarity = 40 })
        for count in [25, 250, 1200] {
            let stamps = (0..<count).map { i in
                BrushStamp(x: 0.2 + Double(i) * 0.002, y: 0.5, radius: 0.06, hardness: 0.6)
            }
            let brush = recipe {
                $0.masks = [Mask(id: "b", type: "brush", source: "brush", invert: false, feather: 0,
                                 opacity: 1, adjustments: ["exposure_ev": -0.8], stamps: stamps)]
            }
            bench("+ brush \(count) stamps (composited)", brush, 5)
            // The app bakes the stroke once and reuses it; this is what a frame then costs.
            if let composited = Renderer.brushMask(stamps, extent: proxy.extent),
               let cg = ctx.createCGImage(composited, from: proxy.extent) {
                let flat = CIImage(cgImage: cg)
                var times: [Double] = []
                for _ in 0..<5 {
                    let start = Date()
                    let out = Renderer.render(proxy, with: brush, maskBitmaps: ["b": flat])
                    _ = ctx.createCGImage(out, from: out.extent)
                    times.append(Date().timeIntervalSince(start) * 1000)
                }
                times.sort()
                print(String(format: "  %-32@ median %6.1f ms",
                             "+ brush \(count) stamps (baked)" as NSString, times[2]))
            }
        }
    } catch { fail("\(error)") }

case "bench-load":
    // Where does the time between "I picked a photo" and "here are your candidates" actually go?
    //
    // `bench` above measures an interactive frame, which is the cost of DRAGGING a slider. This
    // measures the cost of OPENING a photo, which is the wait a user actually complains about, and
    // it is a different pipeline: decode, proxy, statistics, four independent Vision/Core Image
    // passes, then eight candidate renders each scored.
    //
    // Written because a performance proposal arrived with per-subsystem speedup figures and no
    // measurements. Every real performance problem this app has had was work happening in the wrong
    // PLACE (full RAW decodes during view layout; decode on the MainActor), not work being too
    // slow — so the useful question is which stages dominate and which are independent of each
    // other, not which could be rewritten in Metal.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inPath = value(for: "--in", in: rest) else { fail("bench-load requires --in") }
        let url = URL(fileURLWithPath: inPath)

        func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            let out = try body()
            print(String(format: "  %-30@ %7.1f ms", label as NSString,
                         Date().timeIntervalSince(start) * 1000))
            return out
        }

        print("Load-path profile — \(url.lastPathComponent)")
        let full = try time("decode") { try ImageDecoder.decode(url: url) }
        print(String(format: "    (%.0f×%.0f)", full.extent.width, full.extent.height))

        // `ImageDecoder.decode` returns a LAZY CIImage — it reads the header and builds a recipe
        // for producing pixels, it does not produce them. So the "decode" figure above is setup,
        // and whichever stage first asks for pixels pays for the real decode. Forcing it here
        // separates "the file is slow to decode" from "downsampling is slow", which are different
        // problems with different fixes.
        let ctx = CIContext(options: [.cacheIntermediates: true])
        _ = time("first pixels (real decode)") {
            ctx.createCGImage(full, from: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let proxy = time("proxy 1200px (materialised)") { () -> CIImage in
            let lazy = PerceptionProxy.downsample(full, maxEdge: 1200)
            guard let cg = ctx.createCGImage(lazy, from: lazy.extent) else { return lazy }
            return CIImage(cgImage: cg)
        }
        _ = time("proxy 768px (perception)") { () -> CIImage in
            let lazy = PerceptionProxy.downsample(full, maxEdge: 768)
            guard let cg = ctx.createCGImage(lazy, from: lazy.extent) else { return lazy }
            return CIImage(cgImage: cg)
        }

        // The alternative: ask ImageIO to decode STRAIGHT to the size we want. A JPEG can be
        // scaled during entropy decoding, so this never materialises the full frame at all —
        // where `downsample` renders every full-resolution pixel and then throws almost all of
        // them away. The filmstrip already loads thumbnails this way.
        _ = time("proxy via ImageIO subsampled") { () -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary)
        }

        if rest.contains("--sweep-width") {
            for w in [7000.0, 8000.0, 8192.0, 8193.0, 8500.0, 9000.0, full.extent.width]
            where w <= full.extent.width {
                let crop = full.cropped(to: CGRect(x: 0, y: 0, width: w, height: full.extent.height))
                _ = time("  width \(Int(w)) -> 1200px") { () -> CGImage? in
                    let p = PerceptionProxy.downsample(crop, maxEdge: 1200)
                    return ctx.createCGImage(p, from: p.extent)
                }
            }
        }

        // The focus thresholds were calibrated against the Lanczos-downsampled 1200 px proxy, and a
        // focus measure reads exactly the high-frequency content a different resampling filter
        // would change. So before letting the fast proxy anywhere near the focus scan, check the
        // two agree about the photograph.
        if let fast = PerceptionProxy.fromFile(url, maxEdge: 1200) {
            let a = FocusMeasure.read(proxy), b = FocusMeasure.read(fast)
            print(String(format: "  focus: lanczos acuity %.3f (soft %@)  imageio %.3f (soft %@)",
                         a.acuity, a.isSoft ? "yes" : "no", b.acuity, b.isSoft ? "yes" : "no"))
        }

        let stats = try time("statistics") { try ImageStatistics.compute(proxy) }

        // What the white-balance estimator sees, and what it does about it. Whole-frame mean chroma
        // is a grey-world assumption: it reads a photograph full of warm content — skin, wood,
        // autumn leaves — as an illuminant error, and the stronger the correction the more that
        // matters.
        if rest.contains("--wb") {
            let mag = (stats.chromaA * stats.chromaA + stats.chromaB * stats.chromaB).squareRoot()
            print(String(format: "  cast: a %+.1f  b %+.1f  magnitude %.1f",
                         stats.chromaA, stats.chromaB, mag))
            let neutralising = RecipeEngine.neutralisingWhiteBalance(for: stats)
            print(String(format: "  neutralising: %.0f K  tint %+.0f",
                         neutralising.temperatureK, neutralising.tint))
            let before = FaceSkin.read(in: proxy)
            for strength in [0.0, 0.4, 0.7, 1.0] {
                var g = GlobalAdjustments.neutral
                g.temperatureK = RecipeEngine.temperature(correctingChromaB: stats.chromaB,
                                                          strength: strength)
                g.tint = stats.chromaA * 1.8 * strength
                var r = Recipe.neutral; r.global = g
                let out = Renderer.render(proxy, with: r)
                let s = try ImageStatistics.compute(out)
                let skin = FaceSkin.read(in: out)
                let residual = (s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot()
                print(String(format: "    strength %.1f -> %.0f K  residual cast %5.1f  skin hue %5.1f°%@",
                             strength, g.temperatureK ?? 6500, residual,
                             skin.skinHueDegrees ?? -1,
                             (skin.skinHueDegrees.map { $0 < 6 || $0 > 32 } ?? false) ? "  OFF-NATURAL" : ""))
            }
            _ = before
        }
        // None of these four reads another's output, which is the whole point of measuring them
        // one at a time and then together.
        //
        // MEASURED IN SEPARATE PROCESSES (`--only seq` / `--only par`), because running both in
        // one run flatters whichever goes second: Vision loads its models on first use and Core
        // Image caches the proxy, so the second block is timed against a machine the first block
        // warmed up. Measured that way the concurrent block came out at 141 ms against a 1163 ms
        // sequential sum, an "8× win" that was mostly just being second.
        let only = value(for: "--only", in: rest)
        if only != "par" {
            _ = time("  masks (subject + sky)") { LocalMasks.measure(in: proxy) }
            _ = time("  subject instances") { SubjectInstances.detect(in: proxy) }
            _ = time("  dust scan") { DustDetector.detect(in: proxy) }
            _ = time("  focus measure") { FocusMeasure.read(proxy) }
            _ = time("  face skin") { FaceSkin.read(in: proxy) }
        }
        if only != "seq" {
        // The arrangement the app actually uses — NOT all four at once. All four crashes:
        // EXC_BAD_ACCESS in `objc_release` inside Vision's
        // `VNGenerateSemanticSegmentationCompoundRequest detectorTypeForSemanticSegmentationRequest`
        // when two person-segmentation requests resolve their detector concurrently. Reproduced
        // here at 2 crashes in 6 runs. `--only par-unsafe` still does it, because a race you can
        // reproduce on demand is worth being able to reproduce again.
        let unsafeAll = only == "par-unsafe"
        let visionSerial = { _ = LocalMasks.measure(in: proxy); _ = SubjectInstances.detect(in: proxy) }
        let jobs: [() -> Void] = unsafeAll
            ? [{ _ = LocalMasks.measure(in: proxy) }, { _ = SubjectInstances.detect(in: proxy) },
               { _ = DustDetector.detect(in: proxy) }, { _ = FocusMeasure.read(proxy) }]
            : [visionSerial, { _ = DustDetector.detect(in: proxy) }, { _ = FocusMeasure.read(proxy) }]
        let group = DispatchGroup()
        let lock = NSLock()
        var done = 0
        time(unsafeAll ? "  ALL FOUR concurrently (UNSAFE)" : "  concurrent (Vision serialised)") {
            for work in jobs {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    work()
                    lock.lock(); done += 1; lock.unlock()
                    group.leave()
                }
            }
            group.wait()
        }
        }

        let recipes = time("candidate recipes (engine)") {
            // The app's conservative fallback read — the perception content does not matter for a
            // timing measurement, only that the engine runs its full path.
            let perception = Perception(
                scene: .other,
                subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
                lighting: Perception.Lighting(condition: .indoorDaylight, direction: .diffuse,
                                              contrastRange: .normal),
                problems: [], intent: .natural, confidence: 0.3)
            return RecipeEngine.candidates(perception: perception, statistics: stats,
                                    subjectLuma: nil, skyLuma: nil, iso: ExifReader.iso(url: url))
        }
        print("    (\(recipes.count) candidates)")
        _ = time("render + score all candidates") { () -> Int in
            var kept = 0
            for r in recipes {
                let out = Renderer.render(proxy, with: r, maskBitmaps: [:])
                if AestheticEvaluator.score(rendered: out) != nil { kept += 1 }
            }
            return kept
        }
        _ = time("EXIF header read") { ExifReader.iso(url: url) }
    } catch { fail("\(error)") }

case "bench-focus":
    // The culling focus scan, sequential vs the arrangement the app now uses. FocusMeasure touches
    // no Vision, so unlike the per-photo measurement block this one is safe to parallelise.
    do {
        let rest = Array(arguments.dropFirst())
        guard let dir = value(for: "--in-dir", in: rest) else { fail("bench-focus requires --in-dir") }
        let files = try BatchApply.imageFiles(in: URL(fileURLWithPath: dir)).sorted { $0.path < $1.path }
        guard !files.isEmpty else { fail("no readable images in \(dir)") }
        func read(_ url: URL) -> FocusMeasure.Reading? {
            if let fast = PerceptionProxy.fromFile(url, maxEdge: 1200) { return FocusMeasure.read(fast) }
            guard let full = try? ImageDecoder.decode(url: url) else { return nil }
            let lazy = PerceptionProxy.downsample(full, maxEdge: 1200)
            let ctx = CIContext(options: [.cacheIntermediates: false])
            guard let cg = ctx.createCGImage(lazy, from: lazy.extent) else { return nil }
            return FocusMeasure.read(CIImage(cgImage: cg))
        }
        func slowRead(_ url: URL) -> FocusMeasure.Reading? {
            guard let full = try? ImageDecoder.decode(url: url) else { return nil }
            let lazy = PerceptionProxy.downsample(full, maxEdge: 1200)
            let ctx = CIContext(options: [.cacheIntermediates: false])
            guard let cg = ctx.createCGImage(lazy, from: lazy.extent) else { return nil }
            return FocusMeasure.read(CIImage(cgImage: cg))
        }
        print("Focus scan over \(files.count) photos")
        let mode = value(for: "--mode", in: rest) ?? "new"
        let start = Date()
        if mode == "old" {
            for f in files { _ = slowRead(f) }
        } else {
            let group = DispatchGroup()
            let sem = DispatchSemaphore(value: min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)))
            for f in files {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    sem.wait(); _ = read(f); sem.signal(); group.leave()
                }
            }
            group.wait()
        }
        print(String(format: "  %@: %.0f ms total, %.0f ms/photo", mode as NSString,
                     Date().timeIntervalSince(start) * 1000,
                     Date().timeIntervalSince(start) * 1000 / Double(files.count)))
    } catch { fail("\(error)") }

case "fuse":
    // Experimental: single-image exposure fusion (Mertens). Compare against the untouched frame.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("fuse requires --in") }
    guard let outPath = value(for: "--out", in: rest) else { fail("fuse requires --out") }
    let strength = Double(value(for: "--strength", in: rest) ?? "1.0") ?? 1.0
    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let fused = ExposureFusion.fuse(image, strength: strength)
        try ImageWriter.write(fused, to: URL(fileURLWithPath: outPath))
        if let before = try? ImageStatistics.compute(image),
           let after = try? ImageStatistics.compute(fused) {
            print(String(format: "shadows %.3f→%.3f  highlights %.3f→%.3f  median %.3f→%.3f",
                         before.shadowLevel, after.shadowLevel,
                         before.highlightLevel, after.highlightLevel,
                         before.medianLuma, after.medianLuma))
        }
        print("Wrote \(outPath)")
    } catch { fail("\(error)") }

case "info":
    // What the camera recorded — the same data the app's Capture panel shows.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("info requires --in") }
    let info = CaptureInfoReader.read(url: URL(fileURLWithPath: inPath))
    func row(_ label: String, _ value: String?) {
        guard let value else { return }
        print("  " + label.padding(toLength: 12, withPad: " ", startingAt: 0) + value)
    }
    row("Camera", info.camera)
    row("Lens", info.lens)
    row("Exposure", info.summaryText)
    row("Bias", info.exposureBiasText)
    row("Size", info.dimensionsText)
    row("Captured", info.captured.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) })
    row("Location", info.locationText)
    if info.camera == nil && info.summaryText == nil { print("  (no capture metadata in this file)") }

case "horizon":
    // Debug: print the detected leveling angle.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("horizon requires --in") }
    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        if let deg = HorizonDetector.levelingAngle(in: image) {
            print(String(format: "horizon leveling angle: %+.2f°", deg))
        } else { print("no horizon detected") }
    } catch { fail("\(error)") }

case "sky":
    // Debug/inspection: segment the sky and preview a local defog/recover through the mask.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("sky requires --in") }
    guard let outDirPath = value(for: "--out-dir", in: rest) else { fail("sky requires --out-dir") }
    let outDir = URL(fileURLWithPath: outDirPath, isDirectory: true)
    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        guard let mask = SkyMask.detect(in: image) else { fail("no sky found in \(inPath)") }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try ImageWriter.write(mask, to: outDir.appendingPathComponent("sky-mask.png"), format: .png)
        if let luma = SubjectMask.maskedMeanLuma(image: image, mask: mask) {
            print(String(format: "sky mean luma: %.3f", luma))
        }
        let skyEdit = Mask(id: "sky", type: "sky", source: "segmentation", invert: false,
                           feather: 45, opacity: 1.0,
                           adjustments: ["highlights": -40, "contrast": 14, "saturation": 12])
        var recipe = Recipe.neutral
        recipe.masks = [skyEdit]
        let edited = Renderer.render(image, with: recipe, maskBitmaps: ["sky": mask])
        try ImageWriter.write(edited, to: outDir.appendingPathComponent("sky-edit.png"), format: .png)
        print("Wrote sky-mask.png + sky-edit.png to \(outDir.path)")
    } catch {
        fail("\(error)")
    }

case "heal":
    // Auto-detect dust/spots and render the healed result (non-generative, non-destructive).
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("heal requires --in") }
    guard let outPath = value(for: "--out", in: rest) else { fail("heal requires --out") }
    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let spots = DustDetector.detect(in: image)
        print("Detected \(spots.count) spot(s)")
        var recipe = Recipe.neutral
        recipe.heal = spots
        try ImageWriter.write(Renderer.render(image, with: recipe), to: URL(fileURLWithPath: outPath))
        print("Wrote healed image to \(outPath)")
    } catch {
        fail("\(error)")
    }

case "eval":
    let rest = Array(arguments.dropFirst())

    guard let corpusPath = value(for: "--corpus", in: rest) else { fail("eval requires --corpus") }
    let corpusURL = URL(fileURLWithPath: corpusPath)
    let engineVersion = value(for: "--engine-version", in: rest) ?? "0.1.0"

    do {
        let corpus = try Corpus.load(root: corpusURL)
        let report = try Evaluator.run(corpus: corpus, engineVersion: engineVersion)

        print(report.renderTable())

        if let outPath = value(for: "--out", in: rest) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: URL(fileURLWithPath: outPath))
            print("Wrote \(outPath)")
        }

        // Surface the no-op invariant as a non-zero exit so CI can gate on it.
        if !report.noOpFidelityOK {
            fail("no-op fidelity failed: a neutral recipe altered pixels")
        }
    } catch {
        fail("\(error)")
    }

default:
    fail("unknown subcommand '\(subcommand)'. Try `\(tool) --help`.")
}
