import Foundation
import KelvinCore
import os

/// A named starting point for a mask: a kind plus the settings worth reusing. Picking one creates
/// an ordinary, fully-editable mask — a preset here is a head start, never a special object, so
/// everything the mask panel can do to a hand-made mask it can do to a preset one.
///
/// Two sources, one shape: the built-ins below, and the user's own saved ones
/// (`MaskPresetStore`). Built-ins are code because they are opinions the app ships; custom ones
/// are JSON in Application Support because they are the user's, and the user's data outlives
/// app updates.
struct MaskPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: UserMaskVM.Kind

    // Adjustments — the same six every mask carries.
    var exposure = 0.0, contrast = 0.0, saturation = 0.0
    var shadows = 0.0, highlights = 0.0, vibrance = 0.0
    var feather = 0.0, tightness = 0.0
    var invert = false

    // Geometry, for radial/linear presets.
    var cx = 0.5, cy = 0.5, radius = 0.35, angle = 0.0, softness = 0.35
    // Selection, for colour/luminance/skin presets.
    var selCenter = 0.0, selRange = 0.1, selSoftness = 0.1
    // The universal refinement, so "the highlights within the sky" can be a preset too.
    var refinement: UserMaskVM.Refinement = .none
    var refineCenter = 0.06, refineRange = 0.12, refineSoftness = 0.06

    var builtIn = false

    /// A fresh mask carrying this preset's settings, named after it.
    func instantiate() -> UserMaskVM {
        var m = UserMaskVM(kind: kind)
        m.exposure = exposure; m.contrast = contrast; m.saturation = saturation
        m.shadows = shadows; m.highlights = highlights; m.vibrance = vibrance
        m.feather = feather; m.tightness = tightness; m.invert = invert
        m.cx = cx; m.cy = cy; m.radius = radius; m.angle = angle; m.softness = softness
        m.selCenter = selCenter; m.selRange = selRange; m.selSoftness = selSoftness
        m.refinement = refinement
        m.refineCenter = refineCenter; m.refineRange = refineRange; m.refineSoftness = refineSoftness
        m.name = name
        return m
    }

    /// Capture a mask the user has tuned as a reusable preset. Brush strokes and per-person
    /// bindings are deliberately not capturable: stamps belong to one photograph's geometry, and
    /// an instance id belongs to one photograph's people.
    static func capturing(_ m: UserMaskVM, name: String) -> MaskPreset {
        MaskPreset(
            name: name, kind: m.kind,
            exposure: m.exposure, contrast: m.contrast, saturation: m.saturation,
            shadows: m.shadows, highlights: m.highlights, vibrance: m.vibrance,
            feather: m.feather, tightness: m.tightness, invert: m.invert,
            cx: m.cx, cy: m.cy, radius: m.radius, angle: m.angle, softness: m.softness,
            selCenter: m.selCenter, selRange: m.selRange, selSoftness: m.selSoftness,
            refinement: m.refinement,
            refineCenter: m.refineCenter, refineRange: m.refineRange, refineSoftness: m.refineSoftness)
    }

    /// The kinds a preset can be captured from. Brush needs its strokes, a per-person mask needs its
    /// person, and a wand needs the point it was seeded from — none of the three survives the trip
    /// to a different photograph.
    ///
    /// The wand is the least obvious of the three and the most tempting, because its settings look
    /// portable: a tolerance is just a number. But the seed is a coordinate on THIS frame, and the
    /// same coordinate on the next one lands on whatever happens to be there — so a "Darken the sea
    /// stack" preset would apply itself to a patch of sky and report success. A preset that is
    /// silently wrong is worse than one that is unavailable.
    static func isCapturable(_ kind: UserMaskVM.Kind) -> Bool {
        kind != .brush && kind != .instance && kind != .wand
    }

    // MARK: Built-ins

    /// Short on purpose, like the look library: a preset menu you have to scroll teaches nobody
    /// anything. Each of these is a starting point a photographer actually reaches for.
    static let builtIns: [MaskPreset] = [
        MaskPreset(name: "Stormy sky", kind: .sky,
                   exposure: -0.7, contrast: 25, saturation: -12, highlights: -35,
                   feather: 20, builtIn: true),
        MaskPreset(name: "Sunset pop", kind: .sky,
                   exposure: -0.15, highlights: -25, vibrance: 25,
                   feather: 20, builtIn: true),
        MaskPreset(name: "Soft haze", kind: .sky,
                   exposure: 0.25, contrast: -18, saturation: -10,
                   feather: 25, builtIn: true),
        MaskPreset(name: "Soften skin", kind: .skin,
                   exposure: 0.12, contrast: -14, highlights: -10,
                   selCenter: 0.06, selRange: 0.06, selSoftness: 0.05, builtIn: true),
        MaskPreset(name: "Subject pop", kind: .subject,
                   exposure: 0.3, contrast: 10, vibrance: 10, builtIn: true),
        MaskPreset(name: "Fade the background", kind: .background,
                   exposure: -0.5, saturation: -18, feather: 20, builtIn: true)
    ]
}

extension MaskPreset {
    /// Built-ins and the user's own, grouped for the preset menus — one group per region kind
    /// that has any presets, in a stable order, customs after built-ins within a group.
    static func grouped(withCustom custom: [MaskPreset])
        -> [(label: String, icon: String, presets: [MaskPreset])] {
        let all = builtIns + custom
        let order: [(UserMaskVM.Kind, String, String)] = [
            (.sky, "Sky", "cloud.sun"),
            (.skin, "Skin", "face.smiling"),
            (.subject, "Subject", "person.fill"),
            (.background, "Background", "photo")
        ]
        var groups: [(String, String, [MaskPreset])] = []
        for (kind, label, icon) in order {
            let presets = all.filter { $0.kind == kind }
            if !presets.isEmpty { groups.append((label, icon, presets)) }
        }
        // Custom presets of any other kind (radial, graduated, colour, luminance) share a menu:
        // they exist only if the user made them, and their names are the user's own words.
        let named = Set(order.map(\.0))
        let others = custom.filter { !named.contains($0.kind) }
        if !others.isEmpty { groups.append(("Yours", "star", others)) }
        return groups
    }
}

/// The custom half of the library: the user's saved presets, one JSON file in Kelvin's own
/// Application Support folder — beside the edits, never beside anyone's photographs.
enum MaskPresetStore {
    static var defaultURL: URL {
        EditStore.directory.deletingLastPathComponent().appendingPathComponent("mask-presets.json")
    }

    static func load(from url: URL = defaultURL) -> [MaskPreset] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([MaskPreset].self, from: data) else { return [] }
        return decoded
    }

    static func save(_ presets: [MaskPreset], to url: URL = defaultURL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(presets).write(to: url, options: .atomic)
        } catch {
            // Same policy as EditStore: a silent save failure is a lost preset, and the log is
            // the least it owes the user.
            Logger(subsystem: Branding.bundleIdentifier, category: "MaskPresetStore")
                .error("Failed to save mask presets: \(error.localizedDescription, privacy: .public)")
        }
    }
}
