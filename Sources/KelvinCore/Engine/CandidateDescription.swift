import Foundation

/// What a candidate does, in words, relative to the faithful one.
///
/// The picker shows four looks by name — Natural, Soft, Vivid, Dramatic — and a name is a promise
/// about a style, not a description of this photograph. "Soft" on a flat overcast frame may change
/// almost nothing; on a contrasty noon frame it changes a great deal. Someone who is not a
/// photographer (the audience: "pro edits without being pros") and anyone using VoiceOver needs the
/// second thing, and the recipe already contains it.
///
/// **Computed from the recipe's own numbers, never asserted.** Every phrase below is a comparison
/// of two recipes the engine produced, so it cannot describe a look the candidate does not have —
/// the same rule the rest of the app follows about claims it cannot back with a measurement.
///
/// **It says where, not only what.** The engine's most deliberate work is local — the lift for a
/// backlit face, the graduated pull that is Dramatic's reason to exist — and a caption built from
/// the global half alone left all of it unsaid: on a landscape, Dramatic's sky was the one thing
/// that set it apart and the one thing its caption never mentioned. Mask adjustments are now
/// compared the same way, by mask id, and the region is named in plain words ("the sky", "the
/// people") because "masked −1.4 EV" is the professional's affordance, not this app's.
public enum CandidateDescription {

    /// The subject's name when the scene read offers nothing better.
    public static let defaultSubject = "the subject"

    /// What to call the subject mask's region in a caption, from the read's closed vocabulary.
    ///
    /// **`type` and `count`, never `label`.** `label` is free text ("dog", "sea stack") and display
    /// only by rule (`Perception.Subject.label`, D19/D27). Vision's animal recogniser writes "Dog"
    /// there and it would make a lovelier caption, but a caption is a claim the app makes in its
    /// own voice, read aloud by VoiceOver, and the closed vocabulary is the only subject field a
    /// claim may be built on. So an animal is "the animal", and a sea stack — which the engine
    /// lifts through Vision's salient-object mask — is "the subject", because `naturalFeature`
    /// does not say what the feature is. `count` only picks singular or plural; the phrases that
    /// use the noun are written so that no verb has to agree with it.
    public static func subjectNoun(for subject: Perception.Subject) -> String {
        guard subject.present else { return defaultSubject }
        let many = subject.count == .few || subject.count == .crowd
        switch subject.type {
        case .person: return many ? "the people" : "the person"
        case .animal: return many ? "the animals" : "the animal"
        case .object, .naturalFeature, .none: return defaultSubject
        }
    }

    /// Up to `limit` short phrases about the WHOLE picture, most significant first. Empty when the
    /// recipe is within the thresholds of `reference` on every global axis. Phrases about a part of
    /// the picture are `regionPhrases`; `sentence` merges the two.
    public static func phrases(for recipe: Recipe, relativeTo reference: Recipe,
                               limit: Int = 3) -> [String] {
        globalPhrases(recipe, relativeTo: reference).prefix(limit).map(\.text)
    }

    /// Up to `limit` phrases about a PART of the picture — the subject, the sky — most significant
    /// first, at most one per region.
    public static func regionPhrases(for recipe: Recipe, relativeTo reference: Recipe,
                                     subject: String = defaultSubject, limit: Int = 3) -> [String] {
        localPhrases(recipe, relativeTo: reference, subject: subject).prefix(limit).map(\.text)
    }

    /// One sentence for a caption or an accessibility label: the three strongest changes, global or
    /// local, with the global ones first ("Brighter, more contrast") and the local ones after a
    /// "with" ("…, with a deeper sky"). Grouped rather than interleaved in rank order because
    /// "Brighter, a deeper sky, more contrast" leaves a listener to work out which words are about
    /// which part of the picture.
    ///
    /// - Parameter subject: what to call the subject mask's region — `subjectNoun(for:)` of the
    ///   read the candidates were built from. Defaults to "the subject".
    public static func sentence(for recipe: Recipe, relativeTo reference: Recipe,
                                subject: String = defaultSubject) -> String {
        if recipe.id == reference.id { return faithfulSentence(recipe, subject: subject) }
        let ranked = (globalPhrases(recipe, relativeTo: reference)
                      + localPhrases(recipe, relativeTo: reference, subject: subject))
            .sorted { $0.weight > $1.weight }
            .prefix(3)
        let global = ranked.filter { !$0.local }.map(\.text)
        let local = ranked.filter(\.local).map(\.text)
        switch (global.isEmpty, local.isEmpty) {
        case (true, true): return "Close to Natural"
        case (false, true): return capitalised(global.joined(separator: ", "))
        case (true, false): return capitalised(joinedWithAnd(local))
        case (false, false):
            return capitalised(global.joined(separator: ", ") + ", with " + joinedWithAnd(local))
        }
    }

    /// Natural's caption. It is the reference, so the only thing left to compare it with is the
    /// photograph itself — and its GLOBAL half against the photograph is the whole correction, which
    /// is what "True to the scene" already means and is not worth listing.
    ///
    /// Its local half is different. A backlit face lifted out of the shadows, or a white sky pulled
    /// back until its clouds show, is something a person comparing Natural with their original will
    /// SEE and might not expect of a look that promises fidelity, so the one strongest local move
    /// is named: "True to the scene, with the people lifted out of the shadows". One, never a list:
    /// the caption's job is to keep the promise, and three qualifications would read as breaking it.
    ///
    /// Every other look carries the same subject lift (it is corrective and shared, not styled), so
    /// Natural is the only caption where it can ever be said — and the only one where it should be.
    ///
    /// The quiet local moves stay quiet on the thresholds alone, with no special case: the sky's
    /// memory-colour lift is +12 saturation on nearly every outdoor frame, which is 6.6 through the
    /// sky mask's reach (see `Region.reach`) and under the colour threshold of 8. So Natural does not
    /// announce "richer colour in the sky" on every landscape, and would if it became a real move.
    static func faithfulSentence(_ recipe: Recipe, subject: String) -> String {
        guard let local = localPhrases(recipe, relativeTo: .neutral, subject: subject).first
        else { return "True to the scene" }
        return "True to the scene, with " + local.text
    }

    // MARK: - Phrases

    /// A phrase and how far past its threshold the change behind it is — so the strongest change
    /// is said first rather than whichever the code happens to test first, and so global and local
    /// phrases rank on one scale.
    struct Phrase {
        let weight: Double
        let text: String
        let local: Bool
    }

    static func globalPhrases(_ recipe: Recipe, relativeTo reference: Recipe) -> [Phrase] {
        if recipe.blackAndWhite != nil && reference.blackAndWhite == nil {
            // Outranks everything: nothing else a mono look does to the whole frame is news next to
            // losing the colour. Local phrases may still follow it ("…, with a deeper sky").
            return [Phrase(weight: .infinity, text: "Black and white", local: false)]
        }
        let a = recipe.global, b = reference.global
        var found: [Phrase] = []
        func consider(_ delta: Double, threshold: Double, up: String, down: String) {
            guard abs(delta) >= threshold else { return }
            found.append(Phrase(weight: abs(delta) / threshold, text: delta > 0 ? up : down,
                                local: false))
        }
        consider(a.exposureEV - b.exposureEV, threshold: 0.15, up: "brighter", down: "darker")
        // Warmth in mireds, the unit in which equal steps look equal. Lower temperature on this
        // engine's axis renders warmer (Warm is −420 K), so warmer is a RISE in mireds.
        let mired = 1_000_000 / (a.temperatureK ?? asShotK) - 1_000_000 / (b.temperatureK ?? asShotK)
        consider(mired, threshold: 5, up: "warmer", down: "cooler")
        consider(a.contrast - b.contrast, threshold: 8, up: "more contrast", down: "softer contrast")
        consider((a.vibrance + a.saturation) - (b.vibrance + b.saturation), threshold: 8,
                 up: "richer colour", down: "quieter colour")
        consider(a.shadows - b.shadows, threshold: 10, up: "lifted shadows", down: "deeper shadows")
        consider(a.blacks - b.blacks, threshold: 10, up: "faded blacks", down: "deeper blacks")
        return found.sorted { $0.weight > $1.weight }
    }

    /// The parts of a picture a caption can name, keyed off `Mask.type`. Anything else — a
    /// hand-drawn radial, a colour range, an inverted or refined mask — has no plain-words name that
    /// would be true, so it goes undescribed rather than misdescribed. The engine emits only these.
    enum Region: Equatable {
        case subject, sky

        init?(_ mask: Mask) {
            // A refined subject mask is the skin, not the person; an inverted one is everything
            // else. Neither is what the noun would say.
            guard !mask.invert, mask.refine == nil else { return nil }
            switch mask.type {
            case "subject": self = .subject
            case "sky": self = .sky
            default: return nil
            }
        }

        /// How much of a masked parameter reaches the region a viewer is looking at, so a local
        /// threshold means what the global threshold it is copied from means.
        ///
        /// **The subject: all of it.** The subject mask is a segmentation at full alpha inside the
        /// silhouette (feather 6, one source-mask pixel — see `RecipeEngine.subjectMask`), and the
        /// phrase is about the subject, not about the frame's average.
        ///
        /// **The sky: much less, and measured.** The sky mask's mean alpha is 0.55 on real coastal
        /// frames, so masked contrast and colour land at about half strength. Exposure lands weaker
        /// still: 1.4 EV in the mask measured 0.41 of a stop in the sky (`SkyLever.evPerDepth`),
        /// 0.29, because the contrast the same mask carries partly offsets it. Without this, Vivid's
        /// token 0.28 EV pull — 0.08 of a stop that nobody can see — would be announced as "a deeper
        /// sky". With it the looks that claim a sky are Dramatic (1.4 → 0.41 of a stop), Rich
        /// (0.84 → 0.24) and Airy (−0.7, opening it), while Cool's 0.49 (0.14) falls just short of
        /// the 0.15 global exposure needs. Both constants come from one overcast coastal shoot,
        /// the same thin base `SkyLever` warns about; re-measure them with it.
        func reach(_ key: String) -> Double {
            switch self {
            case .subject: return 1
            case .sky: return key == "exposure_ev" ? 0.29 : 0.55
            }
        }
    }

    /// Mask adjustments compared by mask id — the engine's ids are stable, and a mask only one side
    /// carries compares against no edit, the rule `CandidateCurator.maskDistance` follows. At most
    /// one phrase per region, its strongest: three phrases about one sky would crowd the rest of the
    /// picture out of a three-phrase caption, and a caption is for choosing between looks, not for
    /// auditing one.
    static func localPhrases(_ recipe: Recipe, relativeTo reference: Recipe,
                             subject: String) -> [Phrase] {
        func byID(_ masks: [Mask]?) -> [String: Mask] {
            var t: [String: Mask] = [:]
            for m in masks ?? [] { t[m.id] = m }
            return t
        }
        let mine = byID(recipe.masks), theirs = byID(reference.masks)
        // Colour inside part of a black-and-white picture is not something anyone will see.
        let colourVisible = recipe.blackAndWhite == nil
        var found: [Phrase] = []
        // Sorted so equal weights come out in the same order on every run.
        for id in Set(mine.keys).union(theirs.keys).sorted() {
            let a = mine[id], b = theirs[id]
            // Both sides, where present, must be the same nameable region.
            let regions = [a, b].compactMap { $0 }.map(Region.init)
            guard let first = regions.first, let region = first,
                  regions.allSatisfy({ $0 == region }) else { continue }
            // What reaches the picture: the parameter, through the mask's opacity and its reach.
            func delta(_ key: String) -> Double {
                func effective(_ m: Mask?) -> Double {
                    guard let m else { return 0 }
                    return (m.adjustments[key] ?? 0) * m.opacity
                }
                return (effective(a) - effective(b)) * region.reach(key)
            }
            if let phrase = strongest(region, delta: delta, subject: subject,
                                      colourVisible: colourVisible) {
                found.append(phrase)
            }
        }
        return found.sorted { $0.weight > $1.weight }
    }

    /// The one phrase a region gets. The thresholds are the global ones for the same quantity, so a
    /// local phrase is claimed on the same evidence as a global one: 0.15 EV, 10 for a tonal band,
    /// 8 for contrast and for colour.
    ///
    /// Exposure, shadows and highlights are ONE move to a viewer — the engine's subject lift raises
    /// exposure and shadows together (0.7× and 45× the lift) — so they compete as one "light"
    /// phrase, carried by whichever of the three is furthest past its threshold, rather than
    /// producing "the people brighter" and "the people lifted out of the shadows" side by side.
    static func strongest(_ region: Region, delta: (String) -> Double, subject s: String,
                          colourVisible: Bool) -> Phrase? {
        var best: Phrase?
        func consider(_ weight: Double, _ text: String) {
            guard weight >= 1, weight > (best?.weight ?? 0) else { return }
            best = Phrase(weight: weight, text: text, local: true)
        }
        let ev = delta("exposure_ev") / 0.15
        let shadows = delta("shadows") / 10
        let highlights = delta("highlights") / 10
        let light = [(key: "exposure_ev", w: ev), ("shadows", shadows), ("highlights", highlights)]
            .max { abs($0.w) < abs($1.w) }
        let contrast = delta("contrast") / 8
        let colour = colourVisible ? (delta("saturation") + delta("vibrance")) / 8 : 0

        switch region {
        case .subject:
            if let light {
                let up = light.w > 0
                // "Lifted out of the shadows" when the shadow half of an upward move is itself big
                // enough to claim — which is what the lift is weighted towards, kinder to skin.
                let text = up ? (shadows >= 1 ? "\(s) lifted out of the shadows" : "\(s) brighter")
                    : light.key == "shadows" ? "deeper shadows on \(s)"
                    : light.key == "highlights" ? "gentler highlights on \(s)" : "\(s) darker"
                consider(abs(light.w), text)
            }
            consider(abs(contrast), contrast > 0 ? "more contrast on \(s)" : "softer contrast on \(s)")
            consider(abs(colour), colour > 0 ? "richer colour on \(s)" : "quieter colour on \(s)")
        case .sky:
            if let light {
                // Pulling a white sky's highlights down is what brings its clouds back — the
                // engine's corrective blown-sky move — and that, not "darker", is what a viewer sees.
                let text = light.w > 0 ? "a lighter sky"
                    : light.key == "highlights" ? "more detail in the sky" : "a deeper sky"
                consider(abs(light.w), text)
            }
            consider(abs(contrast), contrast > 0 ? "more contrast in the sky" : "a softer sky")
            consider(abs(colour), colour > 0 ? "richer colour in the sky" : "quieter colour in the sky")
        }
        return best
    }

    // MARK: - English

    /// "a", "a and b", "a, b and c" — no Oxford comma, the house style.
    static func joinedWithAnd(_ parts: [String]) -> String {
        guard let last = parts.last else { return "" }
        guard parts.count > 1 else { return last }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }

    static func capitalised(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }

    /// The temperature a recipe with no explicit white balance renders at — see `LookPreset`.
    static let asShotK = 6500.0
}
