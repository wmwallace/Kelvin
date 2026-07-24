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
///   1. **The original stem always survives, and comes first.** `_DSC6595` is how the file maps
///      back to the RAW on the card, and to every other copy of it. A naming scheme that breaks
///      that traceability is worse than no scheme.
///   2. **Only describe what was actually judged.** Tokens come from the perception, never from
///      guesses, and anything the model was unsure of is left out rather than asserted.
///   3. **No duplication.** If the stem already says "sunset", the scheme doesn't say it twice.
public enum ExportNaming {

    /// Build a filename stem (no extension) for an export.
    /// - Parameters:
    ///   - original: the source photo, whose stem is preserved.
    ///   - perception: what the model read, or nil to fall back to just the stem + look.
    ///   - look: the style or preset applied ("Natural", "Red filter"), if any.
    public static func stem(for original: URL, perception: Perception?, look: String?) -> String {
        let base = sanitize(original.deletingPathExtension().lastPathComponent)
        var parts = [base]
        var used = Set(base.lowercased().split(separator: "-").map(String.init))

        func add(_ token: String?) {
            guard let token, !token.isEmpty else { return }
            let clean = sanitize(token)
            // Don't repeat what the stem, or an earlier token, already says.
            let words = clean.split(separator: "-").map(String.init)
            guard !words.isEmpty, !words.allSatisfy({ used.contains($0) }) else { return }
            parts.append(clean)
            used.formUnion(words)
        }

        if let p = perception {
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
        for original: URL, perception: Perception?, look: String?, ext: String = "jpg"
    ) -> String {
        stem(for: original, perception: perception, look: look) + "." + ext
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
        return first
    }

    // MARK: - Vocabulary

    /// Lighting conditions worth putting in a filename. `indoor-daylight` is the model's fallback
    /// value, so it carries no information and is deliberately omitted — a token that appears on
    /// everything is noise.
    static func descriptor(for condition: Condition) -> String? {
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
}
