import Foundation
import CoreImage
import Vision

/// Every distinct thing in the frame worth editing on its own — *this* person, *that* dog, the
/// hillside — rather than one merged "subject".
///
/// `SubjectMask.subject(in:)` deliberately fuses everything Vision finds into a single mask, on the
/// reasoning that "a pair of birds is one subject as far as an edit goes". That is wrong as soon as
/// the two things want different treatment, which is most of the time: two people at different
/// distances from the light, a dark dog against a bright hill, one face in shade and one in sun.
/// Merging them means the only available edit is the average of what each needs.
///
/// So this returns them separately, each labelled, so the app can offer them as a list and the
/// photographer can pick one. Ordering is stable and meaningful — people first, then animals, then
/// anything else, each group largest-first — because the list is a UI and its order is a claim
/// about what matters in the picture.
public enum SubjectInstances {

    /// What kind of thing an instance is. Drives both the label and the ordering; the engine can
    /// also treat a person differently from a rock (skin tone protection, for one).
    public enum Kind: String, Sendable, Equatable {
        case person, animal, object

        /// Singular noun used to build the display label.
        var noun: String {
            switch self {
            case .person: return "Person"
            case .animal: return "Animal"
            case .object: return "Subject"
            }
        }
    }

    public struct Instance: Sendable {
        /// Stable within one detection pass — used as the recipe mask `id` and the bitmap key.
        public let id: String
        /// What the user sees: "Person 1", "Dog", "Subject 2".
        public let label: String
        public let kind: Kind
        /// Grayscale mask, white = this instance, at the source image's extent.
        public let mask: CIImage
        /// Fraction of the frame it covers — drives ordering and the list's size indicator.
        public let coverage: Double
        /// Normalised bounding box (Vision convention, bottom-left origin), for hit-testing a
        /// click on the photo and for placing a label.
        public let boundingBox: CGRect
    }

    /// A mask covering essentially the whole frame is not a subject, it is the picture. Vision
    /// returns exactly that on a featureless image — hand it a flat grey field and it proposes the
    /// entire frame as an instance — and a "Subject 1: 99%" row selecting everything is worse than
    /// an empty list, because it looks like a local edit and behaves like a global one.
    static let maximumCoverage = 0.92

    /// Find every separable subject in the frame. Empty when Vision finds nothing salient — which
    /// is a real answer (a flat landscape has no subject) and not a failure.
    ///
    /// - Parameter limit: how many to return. The list is a UI; twenty rows of rubble helps nobody.
    public static func detect(in image: CIImage, limit: Int = 8) -> [Instance] {
        guard #available(macOS 14.0, *) else { return [] }
        let ext = image.extent
        guard !ext.isInfinite, ext.width > 0, ext.height > 0 else { return [] }

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        var found: [Instance] = []

        // PEOPLE FIRST, individually. The generic foreground segmentation groups touching subjects
        // into one instance — two people sitting together on a porch swing came back as a single
        // mask covering half the frame, which is precisely the thing that makes per-subject editing
        // useless. Vision has a dedicated request that separates people, so use it for them and
        // keep the generic one for everything else.
        // Gate on the SEMANTIC person segmentation first. The instance request will invent a
        // person where there is none — handed a flat grey field it confidently returns one
        // covering 57% of the frame. `SubjectMask.person` already knows how to answer this
        // honestly (Vision returns an all-black mask, not nil, when nobody is there), so ask it
        // whether there is a person at all before asking how many.
        let anyPerson = SubjectMask.person(in: image) != nil
        let people = VNGeneratePersonInstanceMaskRequest()
        if anyPerson, (try? handler.perform([people])) != nil, let result = people.results?.first {
            for index in result.allInstances {
                guard let buffer = try? result.generateScaledMaskForImage(
                        forInstances: IndexSet(integer: index), from: handler) else { continue }
                let mask = align(CIImage(cvPixelBuffer: buffer), to: image)
                let cover = SubjectMask.coverage(of: mask)
                guard cover >= SubjectMask.minimumCoverage, cover <= maximumCoverage else { continue }
                found.append(Instance(id: "person\(index)", label: Kind.person.noun, kind: .person,
                                      mask: mask, coverage: cover,
                                      boundingBox: normalisedBounds(of: mask, in: ext)))
            }
        }

        // Then everything that isn't a person: pets, and whatever else stands out.
        let foreground = VNGenerateForegroundInstanceMaskRequest()
        let animals = animalBoxes(in: image, handler: handler)
        if (try? handler.perform([foreground])) != nil, let result = foreground.results?.first {
            for index in result.allInstances {
                guard let buffer = try? result.generateScaledMaskForImage(
                        forInstances: IndexSet(integer: index), from: handler) else { continue }
                let mask = align(CIImage(cvPixelBuffer: buffer), to: image)
                let cover = SubjectMask.coverage(of: mask)
                guard cover >= SubjectMask.minimumCoverage, cover <= maximumCoverage else { continue }

                // Skip anything already covered by a person instance — the generic pass sees the
                // same people, merged, and adding that back would put a bogus "everyone at once"
                // row in the list beside the individual ones.
                //
                // Tested BOTH directions, because the merged mask is a superset: on a four-person
                // group shot the merged blob is 60% of the frame while each person is ~10–20%, so
                // "how much of the blob is this person" is small for every one of them and the
                // duplicate slipped through. The telling question is the other one — does this new
                // mask swallow an instance we already have?
                if found.contains(where: {
                    overlapOfMasks(mask, $0.mask) > 0.5 || overlapOfMasks($0.mask, mask) > 0.7
                }) { continue }

                let box = normalisedBounds(of: mask, in: ext)
                if let animal = animals.first(where: { overlap($0.box, box) > 0.35 }) {
                    found.append(Instance(id: "instance\(index)", label: animal.label, kind: .animal,
                                          mask: mask, coverage: cover, boundingBox: box))
                } else {
                    // NAME whatever it is. The segmentation is class-agnostic — it will happily cut
                    // out a jellyfish, a frog, or the one rock the photograph is actually about —
                    // but it cannot say what it found, and a list of rows all reading "Subject" is
                    // barely better than not separating them. So classify the crop.
                    found.append(Instance(id: "instance\(index)",
                                          label: name(of: mask, in: image, box: box) ?? Kind.object.noun,
                                          kind: .object, mask: mask, coverage: cover, boundingBox: box))
                }
            }
        }

        // People first, then animals, then everything else; within a group, biggest first. A
        // photographer scanning this list is looking for the subject, and the subject is usually
        // the person, and usually large.
        let rank: [Kind: Int] = [.person: 0, .animal: 1, .object: 2]
        found.sort {
            (rank[$0.kind] ?? 9, -$0.coverage) < (rank[$1.kind] ?? 9, -$1.coverage)
        }
        return numbered(Array(found.prefix(limit)))
    }

    /// "Person", "Person" → "Person 1", "Person 2"; a lone one keeps the bare noun, because
    /// "Person 1" when there is only one person reads like a bug.
    static func numbered(_ items: [Instance]) -> [Instance] {
        var counts: [String: Int] = [:]
        for item in items { counts[item.label, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return items.map { item in
            guard (counts[item.label] ?? 0) > 1 else { return item }
            seen[item.label, default: 0] += 1
            return Instance(id: item.id, label: "\(item.label) \(seen[item.label]!)",
                            kind: item.kind, mask: item.mask, coverage: item.coverage,
                            boundingBox: item.boundingBox)
        }
    }

    // MARK: - Classification helpers

    /// What the thing in this mask actually is — "Jellyfish", "Frog", "Rock" — by classifying the
    /// crop it occupies. Uses Vision's on-device classifier, so it stays inside KelvinCore with no
    /// model dependency and no network.
    ///
    /// Returns nil rather than guessing. A confidently wrong label ("Banana" on your hero rock) is
    /// worse than the honest fallback of "Subject", because the label is what the photographer
    /// clicks on to find the thing they mean.
    private static func name(of mask: CIImage, in image: CIImage, box: CGRect) -> String? {
        let ext = image.extent
        // Crop to the instance, with a little margin — classifiers do better with some context
        // than with a shape shaved to its outline.
        let margin = 0.06
        let rect = CGRect(x: ext.origin.x + max(0, box.minX - margin) * ext.width,
                          y: ext.origin.y + max(0, box.minY - margin) * ext.height,
                          width: min(1, box.width + margin * 2) * ext.width,
                          height: min(1, box.height + margin * 2) * ext.height)
        let crop = image.cropped(to: rect)
        guard !crop.extent.isEmpty, crop.extent.width > 16, crop.extent.height > 16 else { return nil }

        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(ciImage: crop, options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results else { return nil }

        // Precision over recall: this names a UI row, so a wrong name is costlier than none.
        let candidates = results
            .filter { $0.hasMinimumPrecision(0.7, forRecall: 0.1) }
            .filter { !generic.contains($0.identifier) }
        guard let top = candidates.max(by: { $0.confidence < $1.confidence }),
              top.confidence > 0.25 else { return nil }
        // Identifiers are lowercase, sometimes compound ("sea_turtle").
        let words = top.identifier.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Labels that are true but useless on a mask row — they describe the picture, not the thing.
    private static let generic: Set<String> = [
        "outdoor", "indoor", "nature", "landscape", "sky", "plant", "material", "structure",
        "abstract", "art", "light", "shape", "pattern", "texture", "surface", "background",
        "macro", "close_up", "photography", "still_life", "reflection", "shadow", "colour", "color"
    ]

    private struct AnimalBox { let label: String; let box: CGRect }

    /// Cats and dogs are what Vision recognises by name; anything else animal-shaped falls through
    /// to the generic subject path rather than being mislabelled.
    private static func animalBoxes(in image: CIImage, handler: VNImageRequestHandler) -> [AnimalBox] {
        let request = VNRecognizeAnimalsRequest()
        guard (try? handler.perform([request])) != nil,
              let results = request.results else { return [] }
        return results.compactMap { observation in
            guard let top = observation.labels.first, top.confidence > 0.6 else { return nil }
            // Vision's identifiers are lowercase ("dog", "cat"); title-case for display.
            return AnimalBox(label: top.identifier.prefix(1).uppercased() + top.identifier.dropFirst(),
                             box: observation.boundingBox)
        }
    }

    /// Fraction of `a` that `b` covers — asymmetric on purpose: we ask "is this instance mostly
    /// inside that animal's box", not "are the two the same size".
    private static func overlap(_ b: CGRect, _ a: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, a.width > 0, a.height > 0 else { return 0 }
        return Double((i.width * i.height) / (a.width * a.height))
    }

    /// How much of `subject` is also lit in `reference`. Used to decide whether an instance is a
    /// person, by testing it against the person segmentation.
    private static func overlapOfMasks(_ subject: CIImage, _ reference: CIImage) -> Double {
        guard let a = try? ImageWriter.rgba8Sampled(subject, width: 64, height: 64),
              let b = try? ImageWriter.rgba8Sampled(reference, width: 64, height: 64) else { return 0 }
        var both = 0, subjectOnly = 0
        a.withUnsafeBytes { ap in
            b.withUnsafeBytes { bp in
                let s = ap.bindMemory(to: UInt8.self)
                let r = bp.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: a.count, by: 4) where s[i] > 96 {
                    subjectOnly += 1
                    if r[i] > 96 { both += 1 }
                }
            }
        }
        return subjectOnly > 0 ? Double(both) / Double(subjectOnly) : 0
    }

    /// Tight normalised bounds of the lit area, for hit-testing and labelling.
    private static func normalisedBounds(of mask: CIImage, in extent: CGRect) -> CGRect {
        let n = 64
        guard let data = try? ImageWriter.rgba8Sampled(mask, width: n, height: n) else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        var minX = n, minY = n, maxX = -1, maxY = -1
        data.withUnsafeBytes { dp in
            let px = dp.bindMemory(to: UInt8.self)
            for row in 0..<n {
                for col in 0..<n where px[(row * n + col) * 4] > 96 {
                    minX = min(minX, col); maxX = max(maxX, col)
                    minY = min(minY, row); maxY = max(maxY, row)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        // `rgba8Sampled` rasterises top-down; Vision's normalised space is bottom-up, so flip Y.
        let d = Double(n)
        return CGRect(x: Double(minX) / d, y: 1 - Double(maxY + 1) / d,
                      width: Double(maxX - minX + 1) / d, height: Double(maxY - minY + 1) / d)
    }

    private static func align(_ mask: CIImage, to image: CIImage) -> CIImage {
        let sx = image.extent.width / mask.extent.width
        let sy = image.extent.height / mask.extent.height
        return mask
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: image.extent.origin.x,
                                               y: image.extent.origin.y))
    }
}
