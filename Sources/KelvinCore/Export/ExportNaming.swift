import Foundation

/// Names an exported file from what Kelvin already understood about the photo.
///
/// The perception layer has read the scene, the light and the subject before a single pixel is
/// rendered, and until now every bit of that was discarded at export — leaving a folder of
/// `kelvin-edit.jpg` and `_DSC6595.jpg`, which say nothing. The same judgment that drove the edit
/// can name the file, and then the filename is searchable: a photographer looking for that
/// backlit beach frame can type "golden-hour" into Finder and find it.
///
/// Three rules shape the format, all of them about not being clever at the user's expense:
///
///   1. **The original stem always survives VERBATIM, and comes first.** `_DSC6595` is how the file
///      maps back to the RAW on the card, and to every other copy of it. A naming scheme that
///      breaks that traceability is worse than no scheme.
///
///      This rule was stated here from the beginning and the code broke it anyway: `sanitize` was
///      applied to the stem as well as the tokens, so `_DSC6595` exported as `dsc6595` and
///      `IMG_1234` as `img-1234`. The case was gone, the underscore had become a hyphen, and
///      `ls _DSC6595*` found nothing. The stem arrived from a filesystem, so it was already a
///      legal filename — sanitising it could only ever destroy information. On Nikon bodies the
///      leading underscore is not even decoration; it marks Adobe RGB.
///   2. **Only describe what was actually judged.** Tokens come from the perception, never from
///      guesses, and anything the model was unsure of is left out rather than asserted.
///   3. **No duplication.** If the stem already says "sunset", the scheme doesn't say it twice.
public enum ExportNaming {

    /// How much of what Kelvin knows ends up in the filename.
    ///
    /// A choice rather than a fixed policy, because the right answer is a matter of how someone
    /// works and the wrong answer is permanent. Descriptive names are genuinely useful — a
    /// photographer hunting for that backlit beach frame can type "backlit" into Finder — but every
    /// token is a MODEL JUDGEMENT written somewhere very durable. `docs/DECISIONS.md` D-model-3
    /// records four models disagreeing about whether a 10:22 AM frame was golden hour; three were
    /// wrong. A wrong slider is undone with a drag, and a wrong filename goes to a client.
    public enum Scheme: String, CaseIterable, Sendable, Codable {
        /// `_DSC6595` — exactly what came in. Collisions are handled by `uniqueURL`.
        case original
        /// `_DSC6595-Edit` — Lightroom's convention, and the one most existing workflows expect.
        case edited
        /// `_DSC6595_natural` — the look, for when several versions of one frame are exported.
        case look
        /// `_DSC6595_beach_backlit_natural` — everything the scene read supports.
        case descriptive

        public var label: String {
            switch self {
            case .original:    return "Original name"
            case .edited:      return "Original + “-Edit”"
            case .look:        return "Original + look"
            case .descriptive: return "Describe the photo"
            }
        }

        /// What this scheme would produce for a representative frame, for a settings preview.
        /// Concrete beats abstract: nobody can picture "descriptive" until they see it.
        public var example: String {
            switch self {
            case .original:    return "_DSC6595.jpg"
            case .edited:      return "_DSC6595-Edit.jpg"
            case .look:        return "_DSC6595_natural.jpg"
            case .descriptive: return "_DSC6595_beach_backlit_natural.jpg"
            }
        }
    }

    /// Build a filename stem (no extension) for an export.
    /// - Parameters:
    ///   - original: the source photo, whose stem is preserved.
    ///   - perception: what the model read, or nil to fall back to just the stem + look.
    ///   - look: the style or preset applied ("Natural", "Red filter"), if any.
    ///   - label: the photographer's own word for this export — a place, a client, an event.
    ///     Applies to every scheme, because it is the one token here that is not a guess.
    public static func stem(for original: URL, perception: Perception?, look: String?,
                            scheme: Scheme = .descriptive, label: String? = nil) -> String {
        let base = preserved(original.deletingPathExtension().lastPathComponent)
        var parts = [base]
        // Dedup still works case-insensitively and across both separators, so a file already called
        // "sunset_landscape" or "Sunset-Landscape" does not get told what it is twice.
        var used = Set(base.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init))

        func add(_ token: String?) {
            guard let token, !token.isEmpty else { return }
            let clean = sanitize(token)
            // Don't repeat what the stem, or an earlier token, already says.
            let words = clean.split(separator: "-").map(String.init)
            guard !words.isEmpty, !words.allSatisfy({ used.contains($0) }) else { return }
            parts.append(clean)
            used.formUnion(words)
        }

        // THE PHOTOGRAPHER'S OWN WORD GOES FIRST OF THE TOKENS, and it applies to every scheme.
        //
        // Every other token here is a model judgement, hedged accordingly: rule 2 says only describe
        // what was actually judged, and the Scheme doc records four models disagreeing about golden
        // hour. This one is not a judgement — someone typed it — so it is never dropped, never
        // second-guessed, and it outranks the guesses in the name.
        //
        // AFTER the stem rather than before it, which is the one thing people will ask about. Rule 1
        // is that the original stem comes first and survives verbatim, because `ls _DSC6595*` is how
        // an export maps back to the RAW on the card. A prefix would read nicely in a sorted folder
        // and break exactly that.
        add(label.map(labelToken))

        switch scheme {
        case .original:
            // Still "the original name" — plus the word the photographer chose to add to it, which
            // is the whole point of having asked.
            return parts.joined(separator: "_")
        case .edited:
            // Lightroom's convention, and the one most photographers already have a workflow around.
            return parts.joined(separator: "_") + "-Edit"
        case .look, .descriptive:
            break
        }

        if scheme == .descriptive, let p = perception {
            // Scene first — it's the coarsest, most useful filter when scanning a folder.
            if p.scene != .other { add(p.scene.rawValue) }
            // Then the light, which is what actually distinguishes frames within a shoot.
            add(descriptor(for: p.lighting.condition))
            // Then the subject, but only when it adds something the scene didn't.
            if p.subject.present, p.subject.type != .none, p.subject.type != .object {
                add(p.subject.type.rawValue)
            }
        }
        add(look)

        // Keep it a filename, not an essay. Trimming from the end preserves the stem and the
        // coarsest descriptors, dropping the most incidental token first.
        var name = parts.joined(separator: "_")
        while name.count > 96, parts.count > 1 {
            parts.removeLast()
            name = parts.joined(separator: "_")
        }
        return name
    }

    /// A full filename, extension included.
    public static func filename(
        for original: URL, perception: Perception?, look: String?, ext: String = "jpg",
        scheme: Scheme = .descriptive, label: String? = nil
    ) -> String {
        stem(for: original, perception: perception, look: look, scheme: scheme, label: label)
            + "." + ext
    }

    /// A destination that doesn't overwrite anything, by appending `-2`, `-3`, … if needed.
    /// Batch exports land many files in one folder, and silently clobbering one is unforgivable.
    public static func uniqueURL(
        in directory: URL, stem: String, ext: String,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let first = directory.appendingPathComponent(stem).appendingPathExtension(ext)
        guard exists(first) else { return first }
        for n in 2...999 {
            let candidate = directory
                .appendingPathComponent("\(stem)-\(n)")
                .appendingPathExtension(ext)
            if !exists(candidate) { return candidate }
        }
        // A thousand collisions on one stem. Whatever is happening, returning an existing URL
        // would overwrite; a unique suffix keeps the no-clobber promise at the cost of an ugly name.
        return directory
            .appendingPathComponent("\(stem)-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    // MARK: - Vocabulary

    /// Lighting conditions worth putting in a filename. `indoor-daylight` is the model's fallback
    /// value, so it carries no information and is deliberately omitted — a token that appears on
    /// everything is noise.
    /// Public because it is the one place a lighting condition is turned into words a person reads,
    /// and the app's scene summary needs the same vocabulary the filenames use — two spellings of
    /// "golden hour" in one product is how a photographer starts wondering if they mean different
    /// things.
    public static func descriptor(for condition: Condition) -> String? {
        switch condition {
        case .goldenHour:    return "golden-hour"
        case .blueHour:      return "blue-hour"
        case .backlit:       return "backlit"
        case .harshSun:      return "harsh-sun"
        case .overcast:      return "overcast"
        case .nightAmbient:  return "night"
        case .openShade:     return "shade"
        case .flash:         return "flash"
        case .indoorTungsten: return "tungsten"
        case .indoorMixed, .indoorDaylight: return nil
        }
    }

    /// The original stem, unchanged — with only the two things a filesystem genuinely cannot take
    /// removed.
    ///
    /// Deliberately NOT `sanitize`. This string was already a filename a moment ago, so anything it
    /// contains is by definition legal; rewriting it can only lose the case and the separators that
    /// make it match its RAW. A path separator cannot appear in a path component, and a leading dot
    /// would hide the export, so those two are the whole job.
    static func preserved(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let trimmed = cleaned.drop(while: { $0 == "." })
        return trimmed.isEmpty ? "export" : String(trimmed)
    }

    /// Lowercase, hyphenated, and safe on every filesystem — no separators, no spaces, no
    /// punctuation that a shell or a sync client would object to.
    static func sanitize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-"); lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// What a photographer's typed label becomes in a filename.
    ///
    /// Public because the export panel shows it back before anything is written: the sanitiser
    /// lowercases and hyphenates, so "Lake Como, Day 2" lands as `lake-como-day-2`, and nobody
    /// should discover that after four hundred files exist. Capped so one pasted paragraph cannot
    /// crowd out the stem that makes an export traceable.
    public static func labelToken(_ raw: String) -> String {
        let clean = sanitize(raw)
        guard clean.count > 40 else { return clean }
        // Cut on a word boundary rather than mid-word, so a truncated label still reads.
        let cut = String(clean.prefix(40))
        guard let lastDash = cut.lastIndex(of: "-"), lastDash > cut.startIndex else { return cut }
        return String(cut[cut.startIndex..<lastDash])
    }
}
